#!/bin/bash
# Gentoo 中文社区 Live ISO —— 自动构建 + 部署
#
# 在 tmpfs 里全内存构建（省 SSD），用满 CPU，完成后把 ISO 上传到下载站
# mirror.gentoozh.org，并在下载站保留最近 KEEP 个版本、删除更旧的。
#
# 由 systemd timer 每两周触发一次；需 root 运行（build.sh 要求 root）。

set -uo pipefail

# ── 路径与参数 ───────────────────────────────────────────────
PERSIST="/opt/live-iso-builder"      # 持久目录：脚本 + 仓库 + 日志
SRC="${PERSIST}/Live-ISO"            # 上游构建仓库（持久，git pull 更新）
TMPROOT="/mnt/isobuild"              # tmpfs 挂载点（构建全程在内存）
WORK="${TMPROOT}/Live-ISO"           # 本次构建的工作副本
LOG_DIR="${PERSIST}/logs"
LOCK="/run/live-iso-build.lock"
TMPFS_SIZE="88G"                     # 物理 RAM 94G，留 ~6G 给系统/page cache

# 持久缓存（落 SSD，跨构建复用）：编译过程仍在 tmpfs（零 SSD 写），只有
# 成品二进制包与源码 tarball 落这两个 SSD 目录。build.sh 解包后 bind 进 chroot。
#   binpkg：第二次起只编有更新的包（几小时 → 几十分钟），~2-4GB
#   distfiles：源码 tarball 不重复下载，~GB 级
PKGCACHE="${PERSIST}/cache/binpkgs"    # 宿主 SSD 上的持久 binpkg 目录
DISTCACHE="${PERSIST}/cache/distfiles" # 宿主 SSD 上的持久 distfiles 目录

# 下载站部署目标 + 通知等敏感/环境配置从 config.env 读取（不入库;见 config.env.example）
CONFIG_ENV="${PERSIST}/config.env"
[ -f "${CONFIG_ENV}" ] || { echo "缺 ${CONFIG_ENV}（从 config.env.example 复制并填写）"; exit 1; }
. "${CONFIG_ENV}"
: "${M_HOST:?config.env 缺 M_HOST}"; : "${M_PORT:?缺 M_PORT}"; : "${M_USER:?缺 M_USER}"
: "${M_KEY:?缺 M_KEY}"; : "${M_ISODIR:?缺 M_ISODIR}"; : "${KEEP:=3}"

# CPU 忙时延后：开跑前若整机 CPU 占用 ≥ BUSY_PCT，睡 DEFER_MIN 分钟再查，
# 最多延后 MAX_DEFERS 次（达上限仍忙则照常开跑，不无限等）。
BUSY_PCT=40                          # CPU 使用率阈值（%）
DEFER_MIN=30                         # 每次延后分钟数
MAX_DEFERS=12                        # 上限 12 次 = 最多延后 6 小时

CORES="$(nproc)"                     # 76

SSH="ssh -p ${M_PORT} -i ${M_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20"
SCP="scp -P ${M_PORT} -i ${M_KEY} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

mkdir -p "${LOG_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/build-${STAMP}.log"

log()  { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG}"; }
# 失败/成功推送到 Telegram。token/chat_id 从 config.env 的 TG_TOKEN/TG_CHAT 读,未配则静默跳过。
# token 是密钥 → config.env 权限 600、不进任何 git 仓库。
# 发 FAILED 时落一个 selfnotified 哨兵:systemd 的 OnFailure 通知 unit 见到它就不再补发,杜绝双吼;
# wrapper 自己发不出(被 SIGKILL/OOM 等)时哨兵不在 → OnFailure 兜底发一条,既不静默也不重复。
notify() {
    [ "${1:-}" = FAILED ] && { : > /run/live-iso-build.selfnotified 2>/dev/null || true; }
    [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
    curl -fsS -m 20 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" --data-urlencode "text=[$1] gig-os 构建:$2" >/dev/null 2>&1 || true
}
fmt_dur() { local d=$(( $(date +%s) - ${BUILD_START:-$(date +%s)} )); printf '%d时%d分' $((d/3600)) $(((d%3600)/60)); }
# DONE:仅在走到正常终点(notify OK 之后)才置 1。NOTIFIED:fail 或上传失败分支已显式发过
# FAILED 即置 1,供 EXIT 的 on_exit 去重,避免异常退出时重复吼。均为进程内哨兵,每 run 从 0 起。
DONE=0; NOTIFIED=0
fail() { log "[错误] 失败：$*"; notify FAILED "失败:$*(日志 ${LOG##*/});用时 $(fmt_dur)、$(date '+%F %T')"; NOTIFIED=1; cleanup_mounts; exit 1; }

# ── 防并发 ───────────────────────────────────────────────────
exec 9>"${LOCK}"
if ! flock -n 9; then
    echo "已有构建在跑（${LOCK} 被占），退出。"
    exit 0
fi

BUILD_START=$(date +%s)
rm -f /run/live-iso-build.selfnotified 2>/dev/null || true   # 本锅起,清上锅遗留的自通知哨兵
# notify START 拆两段:这里先发"已触发"(根治"clone 卡死则既无 START 也无 FAILED"的盲窗),
# 1b 节拿到 commit 后再补发带 commit 的一条,便于与产物端到端对账。
notify START "已触发,准备拉取源码 $(date '+%F %T')"

# ── 收尾：卸载 build.sh 在 squashfs 里建的 bind/tmpfs，再拆 tmpfs ─
cleanup_mounts() {
    [ "${PRESERVE:-0}" = 1 ] && { log "[警告] PRESERVE=1:保留 tmpfs ${TMPROOT} 待查(手动 sudo umount -R ${TMPROOT})"; return 0; }
    log "清理挂载…"
    # build.sh 自身的 trap 通常已卸 squashfs 内部挂载；这里兜底，逆序卸 WORK 下所有 mount
    awk -v p="${WORK}" '$2 ~ "^"p {print $2}' /proc/mounts | sort -r | while read -r mp; do
        umount -l "${mp}" 2>/dev/null || true
    done
    # 拆 tmpfs 本身（先确保没有子挂载）
    if mountpoint -q "${TMPROOT}"; then
        awk -v p="${TMPROOT}" '$2 ~ "^"p"/" {print $2}' /proc/mounts | sort -r | while read -r mp; do
            umount -l "${mp}" 2>/dev/null || true
        done
        umount -l "${TMPROOT}" 2>/dev/null || true
    fi
}

# 兜底:任何【未到正常终点、且未经 fail/上传失败分支显式通知】的非零退出(运行期语法错、
# set -u 撞未定义变量、被 SIGTERM/超时 kill、中途 exit)都在此补发一条 FAILED,杜绝静默白跑。
# 只在 rc!=0 时吼:flock 抢锁失败走 exit 0(正常),且那时本 trap 尚未安装,不会误报。
on_exit() {
    local rc=$?
    if [ "${DONE}" != 1 ] && [ "${NOTIFIED}" != 1 ] && [ "${rc}" != 0 ]; then
        log "[错误] 构建未到终点即退出(rc=${rc};可能语法错/被kill/未定义变量),补发 FAILED"
        notify FAILED "异常中止(rc=${rc},非正常退出);用时 $(fmt_dur)、$(date '+%F %T');日志 ${LOG##*/}"
    fi
    cleanup_mounts
}
# 信号杀(systemd 超时 SIGTERM / 手动 Ctrl-C / 关终端 SIGHUP)时显式退非零,否则 EXIT 陷阱里
# 的 $? 读成 0 → on_exit 误判成功、漏发 FAILED(实测无此三行时 SIGTERM 下 on_exit 读 rc=0 静默)。
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
trap 'on_exit' EXIT

# ── 编译前预检(几秒内查清硬性前置;失败即 || fail = 发 FAILED + cleanup + exit,绝不烧几小时)──
# 选点在 clone 完成之后、挂 tmpfs/跑 build.sh 之前——此时 abort 零成本。全只读探测。
preflight_mirror() {
    log "预检:镜像站 SSH 可达 + 磁盘余量…"
    # 瞬时抖动重试 3 次(区分'真不可达'与'抽风'),避免可成功的构建被一秒探测误拒(false-abort 也是白跑)
    local n=0
    until ${SSH} "${M_USER}@${M_HOST}" true 2>/dev/null; do
        n=$((n+1)); [ "${n}" -ge 3 ] && { log "[错误] 镜像站 ${M_HOST}:${M_PORT} 连续 3 次 SSH 连不上"; return 1; }
        log "  镜像站 SSH 第 ${n} 次失败,10s 后重试…"; sleep 10
    done
    # 远端取目标分区可用 KB + 现有最大 ISO 字节(无则 0,退回 6G 保守底值,宁紧勿松)
    local avail_kb biggest_b
    avail_kb=$(${SSH} "${M_USER}@${M_HOST}" "df -Pk '${M_ISODIR}' 2>/dev/null | awk 'NR==2{print \$4}'" 2>/dev/null)
    biggest_b=$(${SSH} "${M_USER}@${M_HOST}" "ls -1 '${M_ISODIR}'/gig-os-*.iso 2>/dev/null | xargs -r stat -c%s 2>/dev/null | sort -n | tail -1" 2>/dev/null)
    local cnt_now
    cnt_now=$(${SSH} "${M_USER}@${M_HOST}" "ls -1 '${M_ISODIR}'/gig-os-*.iso 2>/dev/null | wc -l" 2>/dev/null)
    { [ -n "${avail_kb}" ] && [ "${avail_kb}" -gt 0 ] 2>/dev/null; } || { log "[错误] 取镜像站 df 失败或返回非数字(avail_kb=[${avail_kb:-空}])"; return 1; }
    [ "${biggest_b:-0}" -gt 0 ] 2>/dev/null || biggest_b=$((6*1024*1024*1024))
    [ "${cnt_now:-0}" -ge 0 ] 2>/dev/null || cnt_now=0
    # 现有 cnt 份已在盘上(算 used、不算 free);新盘落地只多吃【1 份】的空闲,清理到 KEEP 在
    # 上线成功后才跑。故只需空闲 ≥ 1 份 + 2G 安全余量——别拿 (cnt+1)×单盘 去比【空闲】(那会把
    # 已在盘上的旧盘又算一遍,在小盘 20G 上随 ISO 累积而误拒本可成功的构建)。
    local reserve_kb=$(( 2*1024*1024 ))
    local need_kb=$(( biggest_b/1024 + reserve_kb ))
    log "  镜像站可用 $((avail_kb/1024/1024))G,需 ≥ $((need_kb/1024/1024))G(1 新盘约 $((biggest_b/1024/1024/1024))G + 2G 余量;现有 ${cnt_now} 份已占用不计)"
    [ "${avail_kb}" -ge "${need_kb}" ] || { log "[错误] 镜像站盘余量不足:有 $((avail_kb/1024/1024))G < 需 $((need_kb/1024/1024))G(放不下 1 新盘+2G 余量)"; return 1; }
    return 0
}
# git 仓库可达性探测,3 次退避重试(瞬时 TLS/DNS/5xx 抖动不该毙整锅;与 build.sh clone overlay 同口径)
git_reachable() {
    local n=0
    until git ls-remote --exit-code "$@" >/dev/null 2>&1; do
        n=$((n+1)); [ "${n}" -ge 3 ] && return 1
        sleep 10
    done
    return 0
}
preflight_overlays() {
    log "预检:gig overlay(含 calamares-r8)+ settings-gig fork 可达…"
    # 装机刚需的两个 fork:缺任一会装出'旧坏盘'(无 calamares-r8 / 装机清理为空=后门)
    git_reachable -h https://github.com/Gentoo-zh/gig.git \
        || { log "[错误] Gentoo-zh/gig overlay 连续 3 次不可达(calamares ebuild 来源)"; return 1; }
    # 用 ls-remote 列 overlay 内所有 ref 不可行;改用 GitHub API 列 calamares 目录,确认有任一 calamares-3.3.14-r*.ebuild
    # (不写死 r8:合法 revbump 到 r9 也放行,避免每次升级都 false-abort)。API 失败仅 WARN 不 abort(别因 API 限流白拒)。
    local eblist
    eblist=$(curl -fsS -m 20 "https://api.github.com/repos/Gentoo-zh/gig/contents/app-admin/calamares" 2>/dev/null | grep -oE 'calamares-3\.3\.14-r[0-9]+\.ebuild' | head -1)
    if [ -n "${eblist}" ]; then
        log "  [OK] gig overlay 含 ${eblist}"
    else
        log "  [警告] 未能经 API 确认 calamares-3.3.14-r* ebuild(API 限流/改版?),不阻断;@world 与 verify-iso 仍把关版本"
    fi
    git_reachable https://github.com/Gentoo-zh/calamares-settings-gig.git \
        || { log "[错误] Gentoo-zh/calamares-settings-gig fork 连续 3 次不可达(装机清理/nvidia自动配来源)"; return 1; }
    log "  [OK] settings-gig fork 可达"
    # gentoo-zh / guru 是第三方 overlay(提供 flclash 等非装机刚需包):不可达【不阻断】(仅记一笔),
    # 避免第三方站抖动误杀整锅;build.sh 注入块也是 || WARN 续行,@world 缺它们只少装非关键包。
    for ov in "gentoo-zh|https://github.com/microcai/gentoo-zh.git" "guru|https://github.com/gentoo-mirror/guru.git"; do
        git_reachable "${ov##*|}" || log "[警告] ${ov%%|*} overlay 暂不可达(非装机刚需,继续;可能少装 flclash 等)"
    done
    return 0
}
preflight_ram() {
    log "预检:可用内存能否装下 ${TMPFS_SIZE} tmpfs…"
    local want_g avail_g
    want_g="$(printf '%s' "${TMPFS_SIZE}" | tr -dc '0-9')"
    avail_g=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 / 1024 ))
    # TMPFS_SIZE 是 tmpfs 的【上限】非预留:tmpfs 按需占用、page cache 可回收,要求开跑前先有满
    # 容量空闲既不可能(整机 94G 的 MemAvailable 永远 < 94)也无必要。按真实工作集(squashfs 树+
    # 编译,约 tmpfs 上限的 7 成)估需求,避免阈值不可达 → 每锅编译前自我误杀(那才是真白跑)。
    local need_g=$(( want_g * 7 / 10 ))
    log "  MemAvailable ${avail_g}G,需工作集约 ${need_g}G(tmpfs 上限 ${want_g}G 为按需占用)"
    [ "${avail_g}" -ge "${need_g}" ] || { log "[错误] 可用内存不足:有 ${avail_g}G < 需 ${need_g}G(按真实工作集估)"; return 1; }
    return 0
}
preflight() {
    log "===== 预检(编译前,失败即 abort,不烧几小时)====="
    preflight_mirror   || fail "预检失败:镜像站不可达/盘余量不足"
    preflight_overlays || fail "预检失败:calamares overlay / settings-gig fork 缺失"
    preflight_ram      || fail "预检失败:可用内存不足以挂 ${TMPFS_SIZE} tmpfs"
    log "[OK] 预检全过,进入构建"
}

# ── 端到端核对:镜像站对外【实际服务】的就是本锅(文件名 + SHA 双锚);build 与 reupload 共用思路 ──
# 入参 $1=ISO_NAME $2=本锅 SHA(64hex)。0=站上=本锅;非0=不符/取不到。带有限重试抗 CDN 缓存/跨境抖动。
verify_published() {
    local name="$1" sha="$2" rsha page n=0
    # PUBLISHED_VERIFIED 供 OK 文案如实区分"已核对/未核对":未配 M_URLBASE 时 WARN 但不 fail
    # (那只是没启用可选功能,让整锅失败是又一个 false-abort),只是 OK 文案不能谎称"已核对"。
    PUBLISHED_VERIFIED=skip
    [ -n "${M_URLBASE:-}" ] || { log "[警告] 未配 M_URLBASE,跳过对外核对(强烈建议配上)"; notify WARN "未配 M_URLBASE,本锅【未做】对外核对:${name}(无法确认站上=本锅,请补 config.env)"; return 0; }
    while :; do
        rsha="$(curl -fsS -m 30 -H 'Cache-Control: no-cache' "${M_URLBASE}/${name}.sha256" 2>>"${LOG}" | awk '{print $1}')"
        page="$(curl -fsS -m 30 -H 'Cache-Control: no-cache' "${M_PAGEURL:-${M_URLBASE%/*}/}" 2>>"${LOG}")"
        if [ "${rsha}" = "${sha}" ] && printf '%s' "${page}" | grep -qF "${name}" && printf '%s' "${page}" | grep -qiF "${sha}"; then
            PUBLISHED_VERIFIED=ok
            log "[OK] 对外核对通过:站上 sha256 与落地页(文件名+SHA)均=本锅 ${name}"; return 0
        fi
        n=$((n+1)); [ "${n}" -ge 3 ] && break
        log "  对外核对未通过(站上 sha=${rsha:-空}),可能 CDN 缓存/抖动,8s 后重试…"; sleep 8
    done
    log "[错误] 对外核对失败:站上 sha256=${rsha:-空} 本锅=${sha};落地页含本锅文件名=$(printf '%s' "${page}" | grep -qF "${name}" && echo 是 || echo 否),含本锅 SHA=$(printf '%s' "${page}" | grep -qiF "${sha}" && echo 是 || echo 否)"
    return 1
}

# ── 整机 CPU 使用率（%，整数）：采两次 /proc/stat，间隔 1s ────
cpu_busy_pct() {
    read -r _ a b c d e f g _ < /proc/stat
    local idle1=$((d+e)) tot1=$((a+b+c+d+e+f+g))
    sleep 1
    read -r _ a b c d e f g _ < /proc/stat
    local idle2=$((d+e)) tot2=$((a+b+c+d+e+f+g))
    local dt=$((tot2-tot1)) di=$((idle2-idle1))
    (( dt <= 0 )) && { echo 0; return; }
    echo $(( (100*(dt-di) + dt/2) / dt ))
}

# ── CPU 忙则延后；达上限仍忙则照常开跑 ───────────────────────
wait_for_idle_cpu() {
    local n=0 pct
    while (( n < MAX_DEFERS )); do
        pct="$(cpu_busy_pct)"
        if (( pct < BUSY_PCT )); then
            log "CPU 使用率 ${pct}% < ${BUSY_PCT}%，开始构建。"
            return 0
        fi
        n=$((n+1))
        log "CPU 使用率 ${pct}% ≥ ${BUSY_PCT}%（机器忙），延后 ${DEFER_MIN} 分钟（第 ${n}/${MAX_DEFERS} 次）…"
        sleep $(( DEFER_MIN * 60 ))
    done
    pct="$(cpu_busy_pct)"
    log "已延后达上限 ${MAX_DEFERS} 次（CPU 仍 ${pct}%），照常开始构建。"
    return 0
}

# ── 必须 root ────────────────────────────────────────────────
(( EUID == 0 )) || fail "需以 root 运行"

log "===== Live ISO 自动构建开始（${STAMP}）====="
log "构建机：$(hostname) / ${CORES} 核 / RAM $(free -g | awk '/Mem:/{print $2}')G"

# ── CPU 忙时延后（避开机器正被占用的时段）────────────────────
wait_for_idle_cpu

# ── 1. 更新构建仓库（中文社区 fork 的 KDE 分支，持久副本，含 submodule）──
# 用 Gentoo-zh/Live-ISO 的 KDE 分支（含出厂清理/中文/rime/显卡/语言等改进），
# 不是上游 Gig-OS。若现有副本 remote 指向旧上游则删掉重 clone，确保用对仓库。
REPO_URL="https://github.com/Gentoo-zh/Live-ISO.git"
REPO_BRANCH="KDE"
log "更新构建仓库 ${SRC}（${REPO_URL} @ ${REPO_BRANCH}）…"
if [ -d "${SRC}/.git" ]; then
    cur_remote="$(git -C "${SRC}" remote get-url origin 2>/dev/null || echo '')"
    if [ "${cur_remote}" != "${REPO_URL}" ]; then
        log "现有副本 remote=${cur_remote} 非目标 fork，删除重新 clone…"
        rm -rf "${SRC}"
    fi
fi
# 网络 git 操作一律加 timeout:跨境 TLS 卡死时无超时会无限挂(既不 START 也不 FAILED 的盲窗)。
if [ -d "${SRC}/.git" ]; then
    timeout 300 git -C "${SRC}" fetch origin "${REPO_BRANCH}" 2>&1 | tee -a "${LOG}" || log "fetch 失败/超时（用现有副本继续）"
    git -C "${SRC}" checkout "${REPO_BRANCH}" 2>&1 | tee -a "${LOG}" || true
    git -C "${SRC}" reset --hard "origin/${REPO_BRANCH}" 2>&1 | tee -a "${LOG}" || log "reset 失败（用现有副本继续）"
    timeout 300 git -C "${SRC}" submodule update --init --recursive 2>&1 | tee -a "${LOG}" || log "submodule 更新失败/超时（用现有副本继续）"
else
    timeout 600 git clone --recurse-submodules --branch "${REPO_BRANCH}" "${REPO_URL}" "${SRC}" 2>&1 | tee -a "${LOG}" || fail "clone 失败/超时"
fi

# ── 1b. 钉死本锅身份(commit)+ 发带 commit 的 START 通知 + 源码新鲜度 WARN ──
GIT_COMMIT="$(git -C "${SRC}" rev-parse HEAD 2>/dev/null || echo unknown)"
SRC_HEAD="$(git -C "${SRC}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
SRC_DATE="$(git -C "${SRC}" log -1 --format=%cd --date=format:%Y-%m-%d 2>/dev/null || echo '?')"
log "本锅源码:${REPO_BRANCH}@${SRC_HEAD}(提交日 ${SRC_DATE})"
notify START "开始构建 ${REPO_BRANCH}@${SRC_HEAD}(提交日 ${SRC_DATE})$(date '+%F %T')"
# 源码新鲜度:本地 HEAD 若与 origin 远端不一致(fetch/reset 曾失败、降级用了旧副本),不硬中止
# (避免瞬时网络抖动白拒整锅),但吼一声 WARN——"编译了没更新"也包括【源码层面】没更新。
REMOTE_HEAD="$(git -C "${SRC}" rev-parse "origin/${REPO_BRANCH}" 2>/dev/null || echo '')"
if [ -n "${REMOTE_HEAD}" ] && [ "${REMOTE_HEAD}" != "${GIT_COMMIT}" ]; then
    log "[警告] 本锅源码非 origin/${REPO_BRANCH} 最新(本地 ${GIT_COMMIT:0:12} != 远端 ${REMOTE_HEAD:0:12}),疑似 fetch 降级用了旧副本"
    notify WARN "源码非最新:本锅 ${SRC_HEAD} != origin/${REPO_BRANCH} ${REMOTE_HEAD:0:12}(fetch 可能失败,用了旧副本)"
fi

# ── 1c. 编译前预检:几秒查清硬性前置,失败即 abort+notify,绝不烧几小时 ──
preflight

# ── 2. 建 tmpfs 工作区，拷贝构建副本 ─────────────────────────
cleanup_mounts                      # 防上次残留
mkdir -p "${TMPROOT}"
log "挂载 ${TMPFS_SIZE} tmpfs 到 ${TMPROOT}（全内存构建）…"
mount -t tmpfs -o size="${TMPFS_SIZE}",mode=755 tmpfs "${TMPROOT}" || fail "tmpfs 挂载失败"
log "拷贝构建副本到内存…"
cp -a "${SRC}" "${WORK}" || fail "拷贝失败"

# ── 3. 注入构建参数（只改内存副本，不动上游仓库）────────────
log "写入 config（CORES=${CORES}，关内层 tmpfs，满核 + load 限流）…"
# 镜像源：构建机在香港 5Gbps，直连官方 distfiles.gentoo.org 实测 ~100MB/s、
# stage3 永远最新、不挡 wget，故用官方源（无需迁就大陆镜像，避开 ustc 反爬）。
# 注意：官方源 stage3 路径是 /releases/...（无 /gentoo 前缀），而 build.sh 默认
# 把 DIST 拼成 ${MIRROR}/gentoo/releases，故此处显式写死 DIST 绕开前缀；
# GENTOO_MIRRORS（distfiles 源码）官方根同样无 /gentoo 前缀，由 mirror 文件覆盖。
cat > "${WORK}/config" <<CFG
ARCH=amd64
MICROARCH=amd64
SUFFIX=desktop-systemd
MIRROR="https://distfiles.gentoo.org"
DIST="https://distfiles.gentoo.org/releases/\${ARCH}/autobuilds"
GITMIRROR="https://github.com/gentoo-mirror/gentoo.git"
CORES="${CORES}"
TMPFS=""
MAKEOPTS="-j${CORES} -l${CORES}"
CFG

# build.sh 的 refreshconfig() 把 GENTOO_MIRRORS 写成 "${MIRROR}/gentoo"，这对大陆
# 镜像成立、但官方源根目录无 /gentoo 前缀（会 404）。这里 patch 内存副本里的
# build.sh，去掉那个 /gentoo（只改一次性内存副本，不动上游 git 仓库）。
sed -i 's#GENTOO_MIRRORS=\\""${MIRROR}"/gentoo\\"#GENTOO_MIRRORS=\\""${MIRROR}"\\"#' "${WORK}/build.sh"
if grep -q '${MIRROR}"/gentoo' "${WORK}/build.sh"; then
    log "[警告] refreshconfig 的 /gentoo 前缀未 patch 成功，distfiles 源码下载可能 404"
else
    log "已 patch build.sh：GENTOO_MIRRORS 去掉 /gentoo 前缀（适配官方源根路径）"
fi

# emerge 包级并行 load 节流 + binpkg 缓存（仅构建时用）：
#   --load-average：--jobs 是上限，load≥CORES 暂停放新包（防满核内存雪崩）
#   FEATURES=buildpkg：每个包编完自动打成二进制包存进 PKGDIR（=/var/cache/binpkgs）
#   --usepkg：emerge 优先用已缓存的二进制包，只有版本变了的才重编
#   FEATURES=-merge-sync：关掉 merge 后的 syncfs。portage 3.0.79 自升级时
#     _post_merge_sync 会引用新版才有的 portage.dbapi._SyncfsProcess 模块，
#     而运行中的旧 portage 没有它 → ModuleNotFoundError 导致 portage 安装失败、
#     @world 中断（实测 2026-06-01 构建栽在这）。merge-sync 仅为防断电丢数据,
#     对 tmpfs 全内存构建无意义,关掉零损失且绕过该 bug。
# [警告] 安全：这些是【构建机专用】调优，绝不能进 ISO（否则用户机器 emerge 会
#   超订/塞满磁盘/OOM）。下面的 99-sanitize hook 会在 mksquashfs 前删除它，
#   exclude.txt 再兜底排除——双层防泄漏。
cat > "${WORK}/include-squashfs/etc/portage/make.conf/zz-buildhost" <<LA
# [构建机专用，出厂前由 99-sanitize hook 删除，不应出现在 ISO 里]
# MAKEOPTS 在此覆盖 common 的 -j32：make.conf 目录按字母序加载,zz-* 最后生效,
# 不靠 build.sh refreshconfig 的 sed(实测它没把 common 的 -j32 改成 -j76 → 大包只用
# 32 核)。99-sanitize 删本文件 + 把 common 的 MAKEOPTS 还原成安全字面量 -j4(开机
# gigos-cpuflags.service 再按用户真机核数写 make.conf.d/cpuflags 覆盖之)。
MAKEOPTS="-j${CORES} -l${CORES}"
EMERGE_DEFAULT_OPTS="--load-average=${CORES} --quiet-build=y --usepkg --buildpkg"
FEATURES="\${FEATURES} buildpkg -merge-sync"
# 构建期关掉配置保护:否则 chroot 里 /etc/portage 受 CONFIG_PROTECT 保护,@world 的
# autounmask-continue 写的 package.use/zz-autounmask 会变成 ._cfg 待处理文件、当次不生效
# → autounmask 续跑仍缺那条 → bail 成 "use --autounmask-write" 失败(本周 idna 坑的真因之一)。
# "-*" 让构建期所有配置写入直接落地,autounmask 才能真正自愈滚动树 USE/关键字漂移。
# 仅构建机用:99-sanitize 删 zz-buildhost,用户系统保留正常的 CONFIG_PROTECT。
CONFIG_PROTECT="-*"
LA

# 准备宿主 SSD 上的持久缓存目录（binpkg + distfiles）
mkdir -p "${PKGCACHE}" "${DISTCACHE}"

# 【关键】清掉持久缓存里所有 9999/live ebuild 的 binpkg。live 包(calamares-settings-gig-9999、
# flclash-9999 等)版本号恒为 9999,git 源更新了 portage 也不会重打——--usepkg 会复用【陈旧】binpkg,
# 装进旧版(实测 210153 事故:csg 用了旧 binpkg,装机清理契约缺失,被 99-sanitize 断言拦下白跑近 2h)。
# 每锅删掉它们,强制从 git 重编最新源(dd3743b 等);非 live 包的 binpkg 缓存照常复用,不影响增量加速。
PURGED=$(find "${PKGCACHE}" -type f -name '*-9999*' 2>/dev/null | wc -l)
find "${PKGCACHE}" -type f -name '*-9999*' -delete 2>/dev/null || true
# 删 binpkg 文件后【必须重建 Packages 索引】:否则索引仍列着已删的 9999 包,portage --usepkg 会把它
# 调度成 "binary scheduled for merge",取文件时报 "Tried to use non-existent binary" 而失败
# (实测 224929 栽这:删了文件没重建索引)。emaint 按现存文件重建,悬空条目即清,其余缓存不动。
PKGDIR="${PKGCACHE}" emaint binhost --fix >/dev/null 2>&1 || true
log "已清 live/9999 binpkg 缓存 ${PURGED} 个并重建索引(强制 csg 等从 git 重编,杜绝陈旧 binpkg/悬空索引)"

# patch build.sh：在 mounttmpfs 之后，把宿主 binpkg / distfiles 缓存 bind 进
# chroot（此时 stage3 已解包、squashfs 目录已存在）；cleanmount 里加对应卸载。
python3 - "${WORK}/build.sh" "${PKGCACHE}" "${DISTCACHE}" <<'PY'
import sys, re
path, pkgcache, distcache = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()

# (a) 在主流程的 "mounttmpfs" 独立调用行后，插入两条 bind-mount
bind_block = (
    "mounttmpfs\n"
    "\n"
    "# [autobuild] 持久缓存 bind 进 chroot（宿主 SSD ←→ chroot）\n"
    'mkdir -p "${WORKDIR}/squashfs/var/cache/binpkgs" "${WORKDIR}/squashfs/var/cache/distfiles"\n'
    'if ( ! findmnt "${WORKDIR}/squashfs/var/cache/binpkgs" >/dev/null );then\n'
    f'    mount --bind "{pkgcache}" "${{WORKDIR}}/squashfs/var/cache/binpkgs"\n'
    "fi\n"
    'if ( ! findmnt "${WORKDIR}/squashfs/var/cache/distfiles" >/dev/null );then\n'
    f'    mount --bind "{distcache}" "${{WORKDIR}}/squashfs/var/cache/distfiles"\n'
    "fi\n"
)
s, n = re.subn(r'(?m)^mounttmpfs\n', bind_block, s, count=1)
assert n == 1, f"未找到 mounttmpfs 调用行（替换 {n} 次）"

# (b) 在 cleanmount() 里补两条卸载（放在已有两条 umount 之后）
anchor = '    umount -l "${WORKDIR}/squashfs/mnt/gen-iso" || true\n'
add = ('    umount -l "${WORKDIR}/squashfs/var/cache/binpkgs" || true\n'
       '    umount -l "${WORKDIR}/squashfs/var/cache/distfiles" || true\n')
assert anchor in s, "未找到 cleanmount 的 umount 锚点"
s = s.replace(anchor, anchor + add, 1)

open(path, "w", encoding="utf-8").write(s)
print("OK")
PY
if [ $? -eq 0 ] && grep -q '持久缓存 bind 进 chroot' "${WORK}/build.sh"; then
    log "已 patch build.sh：bind 缓存（binpkg+distfiles → chroot /var/cache/）"
    log "binpkg 缓存：$(du -sh "${PKGCACHE}" 2>/dev/null | cut -f1)；distfiles 缓存：$(du -sh "${DISTCACHE}" 2>/dev/null | cut -f1)"
else
    log "[警告] 缓存 bind patch 失败，本次将无缓存全量编译（不影响产物正确性）"
fi

# patch build.sh（两处,实测 2026-06-02 修)：
# A) overlay clone 移到【第一次 rsync 注入后】最早期(不依赖后面脆弱的 syncrepo,
#    上次放第二次 syncrepo 后没生效);emerge --sync 不为不存在 location 创建 git
#    overlay,故显式 clone,否则 calamares-settings-gig/flclash 装不上、@world 漏装。
# B) 给 portage 升级 与 @world 的 emerge 直接前缀 FEATURES="-merge-sync":portage
#    3.0.79 自升级时 _post_merge_sync 引用新版才有的 _SyncfsProcess 模块崩溃
#    (ModuleNotFoundError),靠 zz-buildhost(rsync 注入)的 -merge-sync 时机不稳,
#    直接在命令前缀注入最可靠(env FEATURES 会与 make.conf 合并,-merge-sync 移除继承的)。
python3 - "${WORK}/build.sh" <<'PY'
import sys
path = sys.argv[1]
s = open(path, encoding="utf-8").read()

# A) overlay clone 插到第一次 rsync(含 --exclude 那条)之后
anchor = 'rsync -rl --copy-unsafe-links "${WORKDIR}"/include-squashfs/* "${WORKDIR}/squashfs/" --exclude etc/portage/package.use/ --exclude etc/portage/make.conf/use || exit 1'
ovblock = '''

# [autobuild] 显式 clone 社区 overlay(emerge --sync 不为不存在 location 创建)
mkdir -p "${WORKDIR}/squashfs/var/db/repos"
for ov in "gig|https://github.com/Gentoo-zh/gig.git" \\
          "gentoo-zh|https://github.com/microcai/gentoo-zh.git" \\
          "guru|https://github.com/gentoo-mirror/guru.git";do
    oname="${ov%%|*}"; ourl="${ov##*|}"
    odst="${WORKDIR}/squashfs/var/db/repos/${oname}"
    if [ -d "${odst}/.git" ];then git -C "${odst}" pull --ff-only || true
    else for n in 1 2 3;do git clone --depth=1 "${ourl}" "${odst}" && break; [ "${n}" = 3 ] && echo "WARN: clone overlay ${oname} failed";done; fi
done

# [autobuild] 让 app-admin/calamares-settings-gig 用【我们的】fork(含:装机后清自动登录、
# 清 live 专用 gigos-live-lang 服务、按 live 选择自动配 nvidia)。gig overlay 的 9999 ebuild
# 是 git-r3,默认拉 Gig-OS 上游(shellprocess 注释掉=这些清理都不生效)。改 EGIT_REPO_URI
# 指向 Gentoo-zh fork(默认 main 分支含我们的 settings.conf/shellprocess*.conf)。
CSGEB="${WORKDIR}/squashfs/var/db/repos/gig/app-admin/calamares-settings-gig/calamares-settings-gig-9999.ebuild"
if [ -f "${CSGEB}" ];then
    sed -i "s#https://github.com/Gig-OS/calamares-settings-gig.git#https://github.com/Gentoo-zh/calamares-settings-gig.git#" "${CSGEB}"
    echo "[autobuild] calamares-settings-gig ebuild 已指向 Gentoo-zh fork"
else
    echo "[autobuild] WARN: 未找到 calamares-settings-gig ebuild,装机清理/nvidia自动配可能不生效"
fi'''
assert anchor in s, "未找到第一次 rsync 锚点"
s = s.replace(anchor, anchor + ovblock, 1)

# B) portage 升级 + @world 前缀 FEATURES="-merge-sync"
b1 = 'crun emerge -vu1q --jobs "${CORES}" portage'
assert b1 in s, "未找到 portage 升级行"
s = s.replace(b1, 'crun FEATURES=\\"-merge-sync\\" emerge -vu1q --jobs "${CORES}" portage', 1)
# C+B+E) 用含 || exit 1 的【完整】@world 行做锚点,一次性替换为:
#   1) cp package.use(上游第二次 rsync 'include-squashfs/*' 无斜杠 + 增量算法漏了它,
#      实测 chroot 里 package.use 空 → calamares 依赖的 boost/libpwquality [python]
#      USE 没配 → 装不上。cp -a 强制覆盖,不靠 rsync 增量。)
#   2) @world 加 FEATURES="-merge-sync" 前缀(规避 portage 3.0.79→3.14 自升级后
#      _post_merge_sync 引用新版 _SyncfsProcess 的 ModuleNotFoundError),保留 || exit 1
#   3) @world 后显式补装 overlay 新包。锚点含 || exit 1 确保补装插在其【之后】,
#      不破坏 @world 自身的 || exit 1(旧版误用不含 || exit 1 的锚点导致
#      '|| true || exit 1' 把 @world 的 || exit 1 吞掉)。
b2full = 'crun emerge -uvDNq --jobs "${CORES}" --keep-going @world || exit 1'
assert b2full in s, "未找到完整 @world 行(含 || exit 1)"
b2full_new = ('# [autobuild] 强制注入 package.use + package.mask(rsync 增量可能漏,@world 解析需要)\n'
              'mkdir -p "${WORKDIR}/squashfs/etc/portage/package.use" "${WORKDIR}/squashfs/etc/portage/package.mask"\n'
              'cp -af "${WORKDIR}"/include-squashfs/etc/portage/package.use/. "${WORKDIR}/squashfs/etc/portage/package.use/" 2>/dev/null || true\n'
              'cp -af "${WORKDIR}"/include-squashfs/etc/portage/package.mask/. "${WORKDIR}/squashfs/etc/portage/package.mask/" 2>/dev/null || true\n'
              'crun FEATURES=\\"-merge-sync\\" emerge -uvDNq --jobs "${CORES}" --keep-going --autounmask-continue --autounmask-keep-masks=y @world || exit 1\n'
              '# [autobuild] 显式补装 @world 漏掉的 overlay 新包(图形安装器/代理)。\n'
              '# 根因:calamares 拉 sphinx→需 docutils<0.23,与 @world 的 docutils-0.23\n'
              '# 冲突,@world 解析器回溯把 calamares 丢了;而【显式】emerge 作为参数不可丢,\n'
              '# 改为跳过 docutils 重建并装上 calamares(实测 chroot emerge -p 验证)。\n'
              '# 【分两条】装:calamares 是装机刚需(关键),flclash 仅代理工具;分开装,\n'
              '# 即便 flclash 因依赖问题失败也绝不连累 calamares。--usepkg=n 强制编译,\n'
              '# || true 不让失败中断整个构建。\n'
              'crun FEATURES=\\"-merge-sync\\" emerge -uvq --usepkg=n --keep-going app-admin/calamares-settings-gig || true\n'
              'crun FEATURES=\\"-merge-sync\\" emerge -uvq --usepkg=n --keep-going net-proxy/flclash || true')
s = s.replace(b2full, b2full_new, 1)

# D) 删第一次 rsync 的 --exclude etc/portage/package.use/(根治 package.use 没注入)。
#    上游第一次 rsync 排除 package.use(等系统就绪),指望第二次 rsync 补,但第二次
#    'include-squashfs/*'(无斜杠)的增量对已存在空目录漏了 package.use → chroot 里
#    它一直空 → calamares 的 boost/libpwquality [python] USE 没配 → 装不上。直接让
#    第一次 rsync 就注入 package.use(那时还没 emerge,提前有这些 USE 无害)。
d_old = '--exclude etc/portage/package.use/ --exclude etc/portage/make.conf/use'
d_new = '--exclude etc/portage/make.conf/use'
assert d_old in s, "未找到第一次 rsync 的 exclude package.use"
s = s.replace(d_old, d_new, 1)

# F) depclean + eclean-kernel 改非致命(|| true)。它们是【清理】步骤,不是装包。
#    @world 成功 = 系统已装好;滚动 ~arch 树的 subslot 严格性(如 depclean 抱怨
#    pillow-12.2.0 需 libavif:0/16.3=)会让 emerge -c 解析失败退非零,旧的 || exit 1
#    就把几小时的整锅构建作废(实测 2026-06-02 第9锅栽在这)。清理失败最多留几个
#    孤儿包(略大),verify-iso 仍把关完整性。@live-rebuild 保持 || exit 1(真重建)。
f1_old = 'crun emerge -c || exit 1'
assert f1_old in s, "未找到 depclean 行"
s = s.replace(f1_old, 'crun emerge -c || true', 1)
f2_old = 'crun eclean-kernel --no-bootloader-update --no-mount -n 1 || exit 1'
assert f2_old in s, "未找到 eclean-kernel 行"
s = s.replace(f2_old, 'crun eclean-kernel --no-bootloader-update --no-mount -n 1 || true', 1)
# eclean-pkg 在 chroot 里永远 not found(chroot 无 gentoolkit),是无害噪音(|| true 兜着)
# 但它想做的"清持久 binpkg 缓存旧版本"也从没真做。直接替成 no-op 去掉噪音;持久缓存
# (宿主 SSD,当前 257G 余量充足)清理交宿主侧按需,不为它往 ISO 塞 gentoolkit。
f3_old = 'crun eclean-pkg || true'
assert f3_old in s, "未找到 eclean-pkg 行"
s = s.replace(f3_old, ': # [autobuild] 已移除 chroot eclean-pkg(无 gentoolkit 必 not found 噪音;缓存清理交宿主)', 1)

open(path, "w", encoding="utf-8").write(s)
print("OK")
PY
if [ $? -eq 0 ] && grep -q 'clone 社区 overlay' "${WORK}/build.sh" && grep -q 'FEATURES=.*merge-sync.* emerge.*portage' "${WORK}/build.sh"; then
    log "已 patch build.sh：overlay clone 前置 + portage/@world 注入 -merge-sync"
else
    log "[警告] overlay/merge-sync patch 失败，可能 @world 漏装 overlay 包或 portage 崩"
fi

# ── 3b. 出厂安全：防构建调优泄漏进 ISO（关键安全步骤）──────────
# 上游 build.sh 把构建机的 MAKEOPTS（refreshconfig 改成 -jCORES）和我们注入的
# zz-buildhost（--usepkg/--buildpkg/load=CORES）都写进了【要发给用户的系统树】，
# 若不清理，用户机器（可能 2-4 核 / 4-8G）emerge 会超订、塞满磁盘、甚至 OOM。
# 用一个 99-sanitize hook（hooks 在 mksquashfs 前 source 执行）做出厂清理：
#   ① 删掉 zz-buildhost（构建调优）
#   ② MAKEOPTS 还原为对用户安全的自适应值（按用户自己的 CPU 核数）
#   ③ GENTOO_MIRRORS 留官方源（对用户全球可用）
#   ④ 删任何残留的 binpkg/distfiles（bind 卸载后挂载点应空，兜底）
cat > "${WORK}/hooks/99-sanitize-for-release.sh" <<'HOOK'
#!/bin/bash
# [autobuild] 出厂安全清理：移除构建机专用调优，使 ISO 对普通用户安全
MC="${WORKDIR}/squashfs/etc/portage/make.conf"

# ① 删构建调优文件（--usepkg/--buildpkg/load=76/FEATURES=buildpkg）
rm -f "${MC}/zz-buildhost" "${MC}/zz-loadavg"

# ② MAKEOPTS 还原为安全兜底字面量 -j4。
#    切勿写 $(nproc):portage 的 make.conf 解析器【不支持】命令替换,会令用户每次 emerge
#    都报 "common, line N: $: bad substitution" 且 MAKEOPTS 失效。真正的按 CPU 自适应改由
#    开机的 gigos-cpuflags.service 写进 make.conf.d/cpuflags(字母序在 common 之后覆盖此值);
#    这里 -j4 仅为首启动前/服务未跑时的安全兜底(小内存机也不致 OOM)。
if [ -f "${MC}/common" ]; then
    sed -i 's/^MAKEOPTS=.*/MAKEOPTS="-j4"/' "${MC}/common"
fi

# ②b 清掉 @world 的 autounmask-continue 在构建期自动写的 zz-autounmask(USE pin 等),
#     不让这些构建期解析产物进 ISO 污染用户的 portage 配置。
PRT="$(dirname "${MC}")"
rm -f "${PRT}/package.use/zz-autounmask" "${PRT}/package.accept_keywords/zz-autounmask" \
      "${PRT}/package.mask/zz-autounmask" "${PRT}/package.license/zz-autounmask" 2>/dev/null || true

# ③ 确保没有遗留 buildpkg 类 FEATURES / usepkg 类 EMERGE_DEFAULT_OPTS
grep -rlE 'buildpkg|--usepkg|--buildpkg|load-average=' "${MC}/" 2>/dev/null \
  | while read -r f; do
        sed -i -E 's/(--usepkg|--buildpkg|--load-average=[0-9]+)//g; s/[[:space:]]+buildpkg//g' "$f"
    done

# ④ 清空 ISO 内的 binpkg/distfiles（不让缓存进 squashfs 撑大体积）
#    【关键】hook 在 mksquashfs 前跑,而 bind 挂载到 cleanmount(EXIT)才卸 —— 此刻
#    bind 仍 active!必须【先 umount -l 解绑】,否则 find -delete 会穿透 bind 把宿主
#    持久缓存(/opt/live-iso-builder/cache/*)整盘删光,导致每周构建都全量重编译。
#    解绑后挂载点露出底层空目录,find 删的是空目录(无害);缓存安然无恙。
for d in binpkgs distfiles; do
    umount -l "${WORKDIR}/squashfs/var/cache/${d}" 2>/dev/null || true
    find "${WORKDIR}/squashfs/var/cache/${d}" -mindepth 1 -delete 2>/dev/null || true
done

# 安全断言:装机后清 live 残留(autologin / SSH 密码登录 / 桌面调试按钮 / polkit 免密)全靠
# calamares-settings-gig 的 shellprocess。打包前强校验契约确已接通——否则一旦 csg 指向 fork 失败
# 或装到旧版(本次 181752 事故:csg 时序错过 dd3743b,装了无清理的旧 csg),会出"装好系统残留 live
# 后门"的盘。任一缺失即【中止构建】(hook 被 source,exit 1 即终止 build.sh → wrapper fail → 发 FAILED)。
CSGSP="${WORKDIR}/squashfs/etc/calamares/modules/shellprocess.conf"
CSGSET="${WORKDIR}/squashfs/etc/calamares/settings.conf"
for pat in "kde_settings.conf" "49-calamares-nopasswd.rules" "00-gigos-passwordlogin.conf" "gigos-nosleep.desktop" "gigos-sudo-nopasswd.desktop"; do
    grep -q "${pat}" "${CSGSP}" 2>/dev/null || { echo "[99-sanitize] 致命:calamares 装机清理缺 ${pat} → 装好系统残留 live 后门,中止"; exit 1; }
done
grep -qE '^[[:space:]]*-[[:space:]]*shellprocess([[:space:]]|$)' "${CSGSET}" 2>/dev/null || { echo "[99-sanitize] 致命:settings.conf 未启用 - shellprocess 装机清理步骤 → 中止"; exit 1; }
echo "[99-sanitize] 安全断言通过:装机清理契约已接(autologin / SSH 密码登录 / polkit 残留会被 calamares 删除)"

echo "[99-sanitize] 出厂清理完成：MAKEOPTS 已自适应化，构建调优已移除"
HOOK
chmod +x "${WORK}/hooks/99-sanitize-for-release.sh"
log "已写入出厂清理 hook（mksquashfs 前移除构建调优，防泄漏进 ISO）"

# exclude.txt 兜底：即使 hook 没删干净，mksquashfs 也排除这些文件
for line in 'etc/portage/make.conf/zz-buildhost' 'etc/portage/make.conf/zz-loadavg'; do
    grep -qxF "${line}" "${WORK}/exclude.txt" 2>/dev/null || echo "${line}" >> "${WORK}/exclude.txt"
done
log "已补 exclude.txt：双层兜底排除构建调优文件"

# ── 4. 跑构建 ────────────────────────────────────────────────
log "开始构建（日志：${LOG}；预计数小时）…"
cd "${WORK}" || fail "cd 失败"
if bash ./build.sh >>"${LOG}" 2>&1; then
    log "[OK] build.sh 完成"
else
    fail "build.sh 退出非零，详见 ${LOG}"
fi

# ── 5. 定位产物 ──────────────────────────────────────────────
ISO="$(ls -1t "${WORK}"/gig-os-*.iso 2>/dev/null | head -n1)"
[ -n "${ISO}" ] && [ -f "${ISO}" ] || fail "未找到产物 ISO"
ISO_NAME="$(basename "${ISO}")"
ISO_SIZE="$(du -h "${ISO}" | cut -f1)"
log "产物：${ISO_NAME}（${ISO_SIZE}）"

# ── 5b. 完整性验证门控（关键项缺失→拒绝上线,不让残缺 ISO 发到下载站）──
#   挂 squashfs 实检 calamares 安装器/rime/字体/locale/双驱动等;
#   exit 0=全过 1=仅警告(放行) 2=关键缺失(拦截)。
if [ -x /opt/live-iso-builder/verify-iso.sh ]; then
    log "完整性验证（挂 squashfs 实检 calamares/rime/字体/locale…）"
    /opt/live-iso-builder/verify-iso.sh "${ISO}" 2>&1 | tee -a "${LOG}"
    VRC="${PIPESTATUS[0]}"
    if [ "${VRC}" -ge 2 ]; then
        PRESERVE=1; fail "[错误] 完整性验证发现【关键项】缺失（rc=${VRC}），拒绝上线（tmpfs 已保留待查：${WORK}）"
    elif [ "${VRC}" -eq 1 ]; then
        log "[警告] 完整性验证有非致命警告（rc=1），继续上线"
    else
        log "[OK] 完整性验证全通过"
    fi
else
    log "[警告] 未找到 verify-iso.sh，跳过完整性门控（建议部署）"
    notify WARN "未找到 verify-iso.sh,本锅跳过内容门控(不保证东西对不对),请确认部署"
fi

log "计算校验和…"
( cd "${WORK}" && md5sum "${ISO_NAME}" > "${ISO_NAME}.md5" && sha256sum "${ISO_NAME}" > "${ISO_NAME}.sha256" ) || fail "校验和计算失败"
SHA="$(awk '{print $1}' "${WORK}/${ISO_NAME}.sha256")"

# ── 5c. 【关键】验证通过的 ISO 先落持久 SSD,再上传 ──────────────────
#   血泪教训(第10锅):verify 全过(27/1/0)却因下载站 SSH 瞬时抽风,上传第一步
#   `|| fail` → cleanup_mounts 把 tmpfs 里 3.8G 成品一起清了。改:先拷到 SSD 暂存,
#   之后所有上传从 SSD 取;上传失败 ISO 仍在,可手动重传不必重编几小时。
STAGE="${PERSIST}/last-iso"
mkdir -p "${STAGE}"
# 先落新盘、再删旧 fallback:杜绝"先 rm 旧盘、cp 新盘前被杀"两头空(reupload 无可恢复盘只能重编)。
cp -f "${WORK}/${ISO_NAME}" "${WORK}/${ISO_NAME}.md5" "${WORK}/${ISO_NAME}.sha256" "${STAGE}/" || fail "暂存 ISO 到 SSD 失败"
# 新盘就位后,删掉除本锅外的旧盘 + 旧/残 manifest,保证 manifest 与本锅 ISO 同生同死:
# 有 manifest ⟺ 这锅成功 stage 完成(崩在 stage 前 → 无本锅 manifest → reupload 拒绝盲传旧盘)。
find "${STAGE}" -maxdepth 1 -name 'gig-os-*.iso*' \
     ! -name "${ISO_NAME}" ! -name "${ISO_NAME}.md5" ! -name "${ISO_NAME}.sha256" -delete 2>/dev/null || true
rm -f "${STAGE}/BUILD_MANIFEST" "${STAGE}/BUILD_MANIFEST.tmp" 2>/dev/null || true
# manifest 先写 .tmp 再原子 mv,杜绝半截 manifest 被 reupload 读到
cat > "${STAGE}/BUILD_MANIFEST.tmp" <<MANI
RUN_STAMP=${STAMP}
GIT_COMMIT=${GIT_COMMIT}
GIT_BRANCH=${REPO_BRANCH}
ISO_NAME=${ISO_NAME}
ISO_SHA256=${SHA}
ISO_SIZE=${ISO_SIZE}
BUILD_DONE=$(date '+%F %T')
MANI
mv -f "${STAGE}/BUILD_MANIFEST.tmp" "${STAGE}/BUILD_MANIFEST" || fail "写 BUILD_MANIFEST 失败"
log "[OK] 验证通过的 ISO 已暂存 + 写 BUILD_MANIFEST:stamp=${STAMP} sha=${SHA:0:12}… iso=${ISO_NAME}(上传失败也不会丢)"

# 瞬时网络抖动重试(最多4次,退避 10/20/30s);输出进日志
retry() { local n=1; while true; do "$@" >>"${LOG}" 2>&1 && return 0; [ "$n" -ge 4 ] && return 1; log "  …第${n}次失败,$((n*10))s 后重试"; sleep $((n*10)); n=$((n+1)); done; }

# ── 6. 上传到下载站(从 SSD 暂存;每步重试抗抖动;失败保留 ISO)──────
# 不在上传【前】做破坏性清理:旧版 KEEP-1 预清理会在新盘落地前先删一份归档,若随后上传失败
# → 站上更少盘、可能只剩旧坏盘(正是事故土壤)。预检已确保盘够 KEEP+1;清理一律放到上线成功之后。
UPLOAD_OK=0
log "上传 ${ISO_NAME} 到 .incoming(瞬时抖动自动重试)…"
if retry ${SSH} "${M_USER}@${M_HOST}" "rm -rf '${M_ISODIR}/.incoming'; mkdir -p '${M_ISODIR}/.incoming'" \
   && retry ${SCP} "${STAGE}/${ISO_NAME}" "${STAGE}/${ISO_NAME}.md5" "${STAGE}/${ISO_NAME}.sha256" "${M_USER}@${M_HOST}:${M_ISODIR}/.incoming/"; then
    log "下载站校验 sha256 → 原子上线(校验文件先 mv、ISO 最后 mv)→ 上线后回读…"
    ${SSH} "${M_USER}@${M_HOST}" "bash -s" >>"${LOG}" 2>&1 <<REMOTE
set -e
cd '${M_ISODIR}/.incoming'
echo '${SHA}  ${ISO_NAME}' | sha256sum -c - || { echo '[错误] .incoming sha256 校验失败'; exit 1; }
chmod 644 '${ISO_NAME}' '${ISO_NAME}.md5' '${ISO_NAME}.sha256'
# 校验/MD5 先落、ISO 最后落:若中途断,目标目录是"旧 ISO+旧 sidecar"或"新 sidecar 无新 ISO",
# render 按 ISO glob 仍指向旧盘(安全),绝不出现"新 ISO 无校验文件"被无校验渲染。
mv -f '${ISO_NAME}.sha256' '${ISO_NAME}.md5' '${M_ISODIR}/'
mv -f '${ISO_NAME}' '${M_ISODIR}/'
# 上线后回读:对 live 里 mv 完的 ISO 再算一次 sha256,确认镜像站文件系统上服务的就是本锅
cd '${M_ISODIR}'
echo '${SHA}  ${ISO_NAME}' | sha256sum -c - || { echo '[错误] 上线后 live sha256 与本锅不符(mv 截断/被并发清理?)'; exit 1; }
echo '[OK] 已上线且 live 回读 sha256 一致:${ISO_NAME}'
REMOTE
    [ $? -eq 0 ] && UPLOAD_OK=1
fi

if [ "${UPLOAD_OK}" != 1 ]; then
    log "[警告] 上传/上线失败(下载站可能临时不可达),但 ISO 已验证通过并暂存:"
    log "    ${STAGE}/${ISO_NAME}"
    log "  待下载站恢复,手动重传(不必重编):sudo /opt/live-iso-builder/reupload-iso.sh"
    notify FAILED "上传失败但 ISO 已验证+暂存:${ISO_NAME};下载站恢复后跑 reupload-iso.sh(勿重编);用时 $(fmt_dur)、$(date '+%F %T')"
    NOTIFIED=1
    cleanup_mounts; exit 1
fi

log "下载站:保留最近 ${KEEP} 份,删更旧的(上线成功后才清理,且本锅 ${ISO_NAME} 永不删)…"
retry ${SSH} "${M_USER}@${M_HOST}" "ISO_DIR='${M_ISODIR}' KEEP=${KEEP} KEEPNAME='${ISO_NAME}' /usr/local/bin/cleanup-old-iso.sh" || { log "远程清理告警"; notify WARN "下载站清理旧版失败,旧盘可能堆积撑盘,请留意:${ISO_NAME}"; }
log "下载站:渲染落地页…"
retry ${SSH} "${M_USER}@${M_HOST}" "SKIP_SHA_SELFCHECK=1 /usr/local/bin/render-index.sh" || log "落地页渲染告警(ISO 已上线,仅页面未刷新)"
# ── 端到端核对:镜像站对外【实际服务】的就是本锅,否则视同白跑(编译了没更新/上线了旧盘)──
verify_published "${ISO_NAME}" "${SHA}" || fail "端到端核对失败:镜像站对外服务的不是本锅 ${ISO_NAME}(已上传但站上不一致)"
log "下载站当前空间与列表:"
${SSH} "${M_USER}@${M_HOST}" "df -h /srv | tail -1; ls -lh '${M_ISODIR}'/gig-os-*.iso 2>/dev/null" >>"${LOG}" 2>&1

# ── 6b. 上传到 Cloudflare R2（零出口流量；保留 R2_KEEP 份；失败仅告警，站上已上线不影响本锅成功）──
#   从 SSD 暂存（STAGE）取已验证 ISO 上传；R2_* 缺任一或无 rclone 则跳过。
if [ -n "${R2_ACCESS_KEY_ID:-}" ] && [ -n "${R2_SECRET_ACCESS_KEY:-}" ] && [ -n "${R2_BUCKET:-}" ] && [ -n "${R2_ENDPOINT:-}" ] && command -v rclone >/dev/null 2>&1; then
    R2_KEEP="${R2_KEEP:-3}"; R2_PUBLIC_BASE="${R2_PUBLIC_BASE:-https://r2.gentoozh.org}"
    export RCLONE_CONFIG_R2_TYPE=s3 RCLONE_CONFIG_R2_PROVIDER=Cloudflare RCLONE_CONFIG_R2_REGION=auto
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID}" RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY}" RCLONE_CONFIG_R2_ENDPOINT="${R2_ENDPOINT}"
    log "R2：上传 ${ISO_NAME}（+校验）到 bucket ${R2_BUCKET}…"
    if rclone copyto "${STAGE}/${ISO_NAME}" "R2:${R2_BUCKET}/${ISO_NAME}" --s3-no-check-bucket --s3-chunk-size 64M --retries 5 2>>"${LOG}"; then
        for e in sha256 md5; do [ -f "${STAGE}/${ISO_NAME}.${e}" ] && rclone copyto "${STAGE}/${ISO_NAME}.${e}" "R2:${R2_BUCKET}/${ISO_NAME}.${e}" --s3-no-check-bucket --retries 5 2>>"${LOG}"; done
        # 对外核对：R2 远端大小 + 公开域名 content-length 都等于本地
        r2_remote=$(rclone size "R2:${R2_BUCKET}/${ISO_NAME}" --json 2>>"${LOG}" | grep -oE '"bytes":[0-9]+' | grep -oE '[0-9]+')
        loc_size=$(stat -c%s "${STAGE}/${ISO_NAME}" 2>/dev/null)
        pub_len=$(curl -fsSLI "${R2_PUBLIC_BASE}/${ISO_NAME}" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)
        if [ -n "${loc_size:-}" ] && [ "${r2_remote:-0}" = "${loc_size}" ] && [ "${pub_len:-0}" = "${loc_size}" ]; then
            log "[OK] R2 上线并通过对外核对：${R2_PUBLIC_BASE}/${ISO_NAME}（${loc_size} bytes）"
            mapfile -t _r2 < <(rclone lsf "R2:${R2_BUCKET}/" 2>/dev/null | grep -E '^gig-os-[0-9]{8}\.iso$' | sort -r)
            _i=0; for f in "${_r2[@]}"; do _i=$((_i+1)); [ "${_i}" -le "${R2_KEEP}" ] && continue; [ "${f}" = "${ISO_NAME}" ] && continue
                log "R2 删旧：${f}（含 .sha256/.md5）"; rclone deletefile "R2:${R2_BUCKET}/${f}" 2>>"${LOG}" || true
                rclone deletefile "R2:${R2_BUCKET}/${f}.sha256" 2>>"${LOG}" || true; rclone deletefile "R2:${R2_BUCKET}/${f}.md5" 2>>"${LOG}" || true
            done
        else
            log "[警告] R2 对外核对不一致（remote=${r2_remote:-空} pub=${pub_len:-空} local=${loc_size:-空}）"; notify WARN "R2 已传但对外核对不一致：${ISO_NAME}"
        fi
    else
        log "[警告] R2 上传失败（站上已上线，不影响本锅成功）"; notify WARN "R2 上传失败：${ISO_NAME}（站上已上线）"
    fi
else
    log "R2 未配置或无 rclone，跳过 R2 上传（仅发布到镜像站）"
fi

# ── 7. 收尾（tmpfs 整块释放，零 SSD 残留）────────────────────
# OK 文案据 PUBLISHED_VERIFIED 如实写:ok=已通过对外核对;skip=M_URLBASE 未配、未做核对(别谎称已核对)
if [ "${PUBLISHED_VERIFIED:-skip}" = ok ]; then
    VTXT="已上线并通过对外核对(sha ${SHA:0:12}…)"
else
    VTXT="已上线;但【未做】对外核对(M_URLBASE 未配,无法确认站上=本锅,请补 config.env)"
fi
log "===== [OK] 全部完成：${ISO_NAME}(源 ${REPO_BRANCH}@${SRC_HEAD})${VTXT} ====="
notify OK "成功:${ISO_NAME}(源 ${REPO_BRANCH}@${SRC_HEAD})${VTXT} mirror.gentoozh.org;用时 $(fmt_dur)、$(date '+%F %T')"
DONE=1   # 走到这里=ISO 确已上线(且对外核对通过或显式标注未核对),on_exit 不再补发 FAILED
# 仅保留最近 10 份构建日志
ls -1t "${LOG_DIR}"/build-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
exit 0
