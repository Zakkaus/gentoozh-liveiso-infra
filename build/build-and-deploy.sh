#!/bin/bash
# Gentoo 中文社区 Live ISO 自动构建 + 镜像站发布
#
# 拉源码、执行 build.sh、验证、发布到镜像站、通知 Telegram。只做编排，构建本身在 Live-ISO 的 build.sh。
# 由 systemd timer 触发，需 root。

set -uo pipefail

# 配置
# 路径与调优写这里；密钥（Telegram token）从 config.env 读、不入库。
SELF_DIR="$(dirname "$(readlink -f "$0")")"
PERSIST="/opt/live-iso-builder"             # 持久目录：脚本 + 源码副本 + 缓存 + 日志
SRC="${PERSIST}/Live-ISO"                   # 构建源仓库（持久，git 更新）
STAGE="${PERSIST}/last-iso"                 # 验证通过的 ISO 暂存（上传失败可重传）
LOG_DIR="${PERSIST}/logs"
CACHE_BINPKG="${PERSIST}/cache/binpkgs"     # 跨构建复用的 binpkg 缓存（落 SSD）
CACHE_DISTFILES="${PERSIST}/cache/distfiles"

USE_TMPFS="${USE_TMPFS:-0}"                  # 1=工作区挂 tmpfs 跑在内存;0=直接落磁盘。
                                            # 因为这台是共享机、别的编译也要内存，所以默认落磁盘；
                                            # 实测峰值约 23G,磁盘足够，速度差别由 binpkg 缓存补回。
TMPROOT="/mnt/isobuild"                     # 工作区根目录（USE_TMPFS=1 时是 tmpfs 挂载点）
WORK="${TMPROOT}/Live-ISO"                  # 本次构建工作副本
TMPFS_SIZE="72G"                            # 实测峰值仅 23G,72G 仍有 3 倍余量；共享机上留更多内存给其他任务
LOCK="/run/live-iso-build.lock"
SELFNOTIFIED="/run/live-iso-build.selfnotified"

REPO_URL="https://github.com/Gig-OS/Live-ISO.git"
REPO_BRANCH="KDE"                           # Gig-OS 上游的构建分支，社区 fork 的改动已合并至此
CORES="$(nproc)"

# CPU 忙时延后：开跑前整机 CPU ≥ BUSY_PCT 就睡 DEFER_MIN 分钟再查，最多 MAX_DEFERS 次
BUSY_PCT=40
DEFER_MIN=30
MAX_DEFERS=12

MIRROR_URL="${MIRROR_URL:-https://iso.gentoozh.org/}"       # Worker 落地页（有缓存滞后）

# 镜像站发布（唯一发布目标；未配 MIRROR_SSH_TARGET 时整段跳过）
MIRROR_SSH_TARGET="${MIRROR_SSH_TARGET:-}"                     # 如 zakk@159.195.212.91
MIRROR_SSH_OPTS="${MIRROR_SSH_OPTS:-}"                         # 如 -i /root/.ssh/gigos_mirror -p 60001
MIRROR_PATH="${MIRROR_PATH:-/srv/pub/gigos}"                   # 镜像机上的落地目录
MIRROR_KEEP="${MIRROR_KEEP:-2}"                                # 镜像站保留最近几份 ISO
MIRROR_PUBLIC_BASE="${MIRROR_PUBLIC_BASE:-https://distfiles.gentoozh.org/gigos}"  # 末尾不带斜杠

# 密钥 + 环境配置（MIRROR_* / TG_* / 上面默认的覆盖）从 config.env 读
CONFIG_ENV="${PERSIST}/config.env"
[ -f "${CONFIG_ENV}" ] || { echo "缺 ${CONFIG_ENV}（从 config.env.example 复制并填）"; exit 1; }
. "${CONFIG_ENV}"

mkdir -p "${LOG_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/build-${STAMP}.log"
BUILD_START="$(date +%s)"

# 跨阶段结果（在各函数里赋值、后续函数与通知里用；先置空，set -u 友好）
GIT_COMMIT=""; ISO=""; ISO_NAME=""; ISO_SIZE=""; SHA=""; MIRROR_NOTE=""
DONE=0; NOTIFIED=0      # 进程内哨兵：DONE=走到正常终点；NOTIFIED=已显式通知过。供退出陷阱去重。

# 日志 / 通知
log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG}"; }

fmt_dur() { local d=$(( $(date +%s) - BUILD_START )); printf '%d时%d分' $((d/3600)) $(((d%3600)/60)); }

# 推送到 Telegram（token/chat 从 config.env；未配则静默跳过）。发 FAILED 时落一个哨兵文件，
# 供 systemd OnFailure 通知去重：wrapper 自己发出来了，OnFailure 就别再补一条。
notify() {
    [ "${1:-}" = FAILED ] && { : > "${SELFNOTIFIED}" 2>/dev/null || true; }
    [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
    curl -fsS -m 20 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=${TG_CHAT}" --data-urlencode "text=[$1] gig-os 构建：$2" >/dev/null 2>&1 || true
}

fail() {
    log "[错误] $*"
    notify FAILED "失败：$*（日志 ${LOG##*/}）；用时 $(fmt_dur)、$(date '+%F %T')"
    NOTIFIED=1; cleanup_mounts; exit 1
}

# 挂载清理 + 退出陷阱
# 卸载 build.sh 在 squashfs 里建的 bind/tmpfs，再拆掉 tmpfs 工作区本身（逆序卸，兜底）。
cleanup_mounts() {
    [ "${PRESERVE:-0}" = 1 ] && { log "PRESERVE=1：保留 tmpfs ${TMPROOT} 待查（手动 umount -R）"; return 0; }
    log "清理挂载…"
    awk -v p="${WORK}" '$2 ~ "^"p {print $2}' /proc/mounts | sort -r | while read -r mp; do
        umount -l "${mp}" 2>/dev/null || true
    done
    if mountpoint -q "${TMPROOT}"; then
        awk -v p="${TMPROOT}" '$2 ~ "^"p"/" {print $2}' /proc/mounts | sort -r | while read -r mp; do
            umount -l "${mp}" 2>/dev/null || true
        done
        umount -l "${TMPROOT}" 2>/dev/null || true
    fi
}

# 未到正常终点、又没被 fail 显式通知过的非零退出（运行期语法错 / 被 kill / set -u 撞未定义变量）
# 都在这里补发 FAILED，避免静默失败。flock 抢锁失败走 exit 0（此时陷阱尚未安装，不会误报）。
on_exit() {
    local rc=$?
    if [ "${DONE}" != 1 ] && [ "${NOTIFIED}" != 1 ] && [ "${rc}" != 0 ]; then
        log "[错误] 构建未到终点即退出（rc=${rc}），补发 FAILED"
        notify FAILED "异常中止（rc=${rc}）；用时 $(fmt_dur)、$(date '+%F %T')；日志 ${LOG##*/}"
    fi
    cleanup_mounts
}

# 防并发 + 忙时延后
# wrapper 级锁（build.sh 自己也有一把）：同一时刻只允许一次构建。
acquire_lock() {
    exec 9>"${LOCK}"
    flock -n 9 || { echo "已有构建在执行（${LOCK} 被占），退出。"; exit 0; }
}

# 整机 CPU 使用率（%，整数）：采两次 /proc/stat、间隔 1s。
cpu_busy_pct() {
    local _ a b c d e f g idle1 tot1 idle2 tot2 dt di
    read -r _ a b c d e f g _ < /proc/stat
    idle1=$((d+e)); tot1=$((a+b+c+d+e+f+g))
    sleep 1
    read -r _ a b c d e f g _ < /proc/stat
    idle2=$((d+e)); tot2=$((a+b+c+d+e+f+g))
    dt=$((tot2-tot1)); di=$((idle2-idle1))
    (( dt <= 0 )) && { echo 0; return; }
    echo $(( (100*(dt-di) + dt/2) / dt ))
}

# CPU 忙就延后；达上限仍忙则照常开跑（不无限等）。
wait_for_idle_cpu() {
    local n=0 pct
    while (( n < MAX_DEFERS )); do
        pct="$(cpu_busy_pct)"
        (( pct < BUSY_PCT )) && { log "CPU ${pct}% < ${BUSY_PCT}%，开始构建。"; return 0; }
        n=$((n+1))
        log "CPU ${pct}% ≥ ${BUSY_PCT}%（机器忙），延后 ${DEFER_MIN} 分钟（第 ${n}/${MAX_DEFERS} 次）…"
        sleep $(( DEFER_MIN * 60 ))
    done
    log "延后达上限（CPU 仍 $(cpu_busy_pct)%），照常开始构建。"
}

# 预检（开跑前几秒查清硬性前置，失败即 fail，不白烧几小时）
# git 仓库可达性，3 次退避重试（瞬时 TLS/DNS/5xx 抖动不该毙整锅）。
git_reachable() {
    local n=0
    until git ls-remote --exit-code "$@" >/dev/null 2>&1; do
        n=$((n+1)); [ "${n}" -ge 3 ] && return 1
        sleep 10
    done
}

# 装机刚需的两个 fork 必须可达：缺了会装出"无 calamares 安装器"或"装机不清理 = 后门"的坏盘。
preflight_overlays() {
    log "预检：gig overlay（calamares 来源）+ settings-gig fork 可达…"
    git_reachable -h https://github.com/Gig-OS/gig.git \
        || { log "[错误] Gig-OS/gig overlay 连续 3 次不可达"; return 1; }
    # 用 GitHub API 确认 gig overlay 里有 calamares-3.3.14-r* ebuild（不写死 r 号，合法 revbump 也放行）。
    # API 失败只 WARN 不 abort（别因限流误杀）；@world 和 verify-iso 后面还会把关版本。
    local eb
    eb=$(curl -fsS -m 20 "https://api.github.com/repos/Gig-OS/gig/contents/app-admin/calamares" 2>/dev/null \
         | grep -oE 'calamares-3\.3\.14-r[0-9]+\.ebuild' | head -1)
    [ -n "${eb}" ] && log "  [OK] gig overlay 含 ${eb}" || log "  [警告] 未能经 API 确认 calamares ebuild（限流？），不阻断"
    git_reachable https://github.com/Gig-OS/calamares-settings-gig.git \
        || { log "[错误] Gig-OS/calamares-settings-gig 连续 3 次不可达"; return 1; }
    log "  [OK] settings-gig 仓库可达"
    # gentoo-zh / guru 提供 flclash 等非装机刚需包，不可达不阻断（只少装非关键包）。
    local ov
    for ov in "gentoo-zh|https://github.com/gentoo-zh/overlay.git" "guru|https://github.com/gentoo-mirror/guru.git"; do
        git_reachable "${ov##*|}" || log "[警告] ${ov%%|*} overlay 暂不可达（非刚需，继续）"
    done
}

# 可用内存够不够挂 tmpfs。tmpfs 是上限不是预留（按需占用、page cache 可回收），按真实工作集
# （约上限 7 成）估需求，避免阈值不可达导致每锅编译前自我误杀。
# 落磁盘构建时检查可用空间。实测峰值约 23G,要求 60G 留足余量(squashfs + ISO 另占)。
preflight_disk() {
    local avail need=60
    avail=$(df -BG --output=avail "$(dirname "${TMPROOT}")" 2>/dev/null | tail -1 | tr -dc '0-9')
    [ -n "${avail}" ] || avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    log "预检：磁盘空间（落盘构建）…"
    log "  可用 ${avail}G，需 ${need}G"
    [ "${avail}" -ge "${need}" ] || { log "[错误] 磁盘空间不足：${avail}G < 需 ${need}G"; return 1; }
}

preflight_ram() {
    log "预检：内存能否装下 ${TMPFS_SIZE} tmpfs…"
    local want avail need
    want="$(printf '%s' "${TMPFS_SIZE}" | tr -dc '0-9')"
    avail=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 / 1024 ))
    need=$(( want * 7 / 10 ))
    log "  MemAvailable ${avail}G，需工作集约 ${need}G"
    [ "${avail}" -ge "${need}" ] || { log "[错误] 可用内存不足：${avail}G < 需 ${need}G"; return 1; }
}

# 镜像站是唯一发布目标：目标可 ssh、落地目录可写。缺料就别白编几小时。
preflight_mirror() {
    [ -n "${MIRROR_SSH_TARGET}" ] || { log "预检：未配 MIRROR_SSH_TARGET，跳过镜像站检查"; return 0; }
    log "预检：镜像站可达…"
    local ssh_cmd="ssh ${MIRROR_SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15"
    local n=0
    until ${ssh_cmd} "${MIRROR_SSH_TARGET}" "test -w ${MIRROR_PATH}" >/dev/null 2>&1; do
        n=$((n+1)); [ "${n}" -ge 3 ] && { log "[错误] ${MIRROR_SSH_TARGET}:${MIRROR_PATH} 连续 3 次不可写"; return 1; }
        sleep 10
    done
    log "  [OK] 镜像站可达：${MIRROR_SSH_TARGET}:${MIRROR_PATH}"
}

preflight() {
    log "===== 预检 ====="
    preflight_mirror   || fail "预检失败：镜像站不可达或落地目录不可写"
    preflight_overlays || fail "预检失败：calamares overlay / settings-gig fork 缺失"
    if [ "${USE_TMPFS}" = 1 ]; then
        preflight_ram  || fail "预检失败：内存不足以挂 ${TMPFS_SIZE} tmpfs"
    else
        preflight_disk || fail "预检失败：磁盘空间不足"
    fi
    log "[OK] 预检全过"
}

# 1. 更新源仓库
# 网络 git 操作一律加 timeout，跨境 TLS 卡死时不至于无限挂（既不 START 也不 FAILED 的盲窗）。
update_source() {
    log "更新源仓库 ${SRC}（${REPO_URL} @ ${REPO_BRANCH}）…"
    # 现有副本若 remote 指向旧上游（如 Gig-OS），删掉重 clone 确保用对仓库
    if [ -d "${SRC}/.git" ] && [ "$(git -C "${SRC}" remote get-url origin 2>/dev/null)" != "${REPO_URL}" ]; then
        log "现有副本 remote 不对，删除重 clone…"; rm -rf "${SRC}"
    fi
    if [ -d "${SRC}/.git" ]; then
        timeout 300 git -C "${SRC}" fetch origin "${REPO_BRANCH}" 2>&1 | tee -a "${LOG}" || log "fetch 失败/超时（用现有副本继续）"
        git -C "${SRC}" checkout "${REPO_BRANCH}" 2>&1 | tee -a "${LOG}" || true
        git -C "${SRC}" reset --hard "origin/${REPO_BRANCH}" 2>&1 | tee -a "${LOG}" || log "reset 失败（用现有副本继续）"
        timeout 300 git -C "${SRC}" submodule update --init --recursive 2>&1 | tee -a "${LOG}" || log "submodule 更新失败/超时"
    else
        timeout 600 git clone --recurse-submodules --branch "${REPO_BRANCH}" "${REPO_URL}" "${SRC}" 2>&1 | tee -a "${LOG}" || fail "clone 失败/超时"
    fi
    GIT_COMMIT="$(git -C "${SRC}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    log "本锅源码：${REPO_BRANCH}@${GIT_COMMIT}"
    # 源码新鲜度提醒：本地 != 远端（fetch 可能失败、用了旧副本）只 WARN，不毙整锅
    local remote_head
    remote_head="$(git -C "${SRC}" rev-parse --short "origin/${REPO_BRANCH}" 2>/dev/null || echo '')"
    [ -n "${remote_head}" ] && [ "${GIT_COMMIT}" != "${remote_head}" ] \
        && notify WARN "源码非最新：本锅 ${GIT_COMMIT} != origin ${remote_head}（fetch 可能失败、用了旧副本）"
}

# 2. 准备工作区
# tmpfs 全内存构建（省 SSD），拷贝源码副本，注入 build-host 调优 + env，装出厂清理 hook。
prepare_workdir() {
    cleanup_mounts                                  # 防上次残留
    mkdir -p "${TMPROOT}"
    if [ "${USE_TMPFS}" = 1 ]; then
        log "挂载 ${TMPFS_SIZE} tmpfs 到 ${TMPROOT}（全内存构建）…"
        mount -t tmpfs -o size="${TMPFS_SIZE}",mode=755 tmpfs "${TMPROOT}" || fail "tmpfs 挂载失败"
    else
        # 因为落磁盘时上一锅的文件不会随 umount 消失，所以这里显式清空，避免残留混进本锅。
        log "落磁盘构建，清空工作区 ${TMPROOT}…"
        rm -rf "${TMPROOT:?}/"* 2>/dev/null || true
    fi
    log "拷贝源码副本到工作区…"
    cp -a "${SRC}" "${WORK}" || fail "拷贝失败"

    # host 专属参数经环境变量传给 build.sh（它的 config 用 := 默认值、env 可覆盖）。
    # 镜像源已在 build.sh 的 config 默认官方源，这里不重复。
    export CORES="${CORES}"
    export TMPFS=""                                 # 整个 WORK 已在 tmpfs，chroot 内不再单独挂
    export MAKEOPTS="-j${CORES} -l${CORES}"
    export BINPKG_CACHE="${CACHE_BINPKG}"           # build.sh 据此把宿主缓存 bind 进 chroot
    export DISTFILES_CACHE="${CACHE_DISTFILES}"

    # 仅构建机用的 make.conf 调优，出厂前由 99-sanitize 删除、exclude.txt 兜底。
    # zz- 前缀让它按字母序最后加载以覆盖 common。-merge-sync 一类构建期 workaround 不在这里，
    # 由 build.sh 在对应 emerge 上内联设置。
    #   --usepkg/--buildpkg 把编完的包存成 binpkg，下次只重编有更新的
    #   --load-average 在 load 到顶时暂停放新包，防满核内存雪崩
    cat > "${WORK}/include-squashfs/etc/portage/make.conf/zz-buildhost" <<EOF
MAKEOPTS="-j${CORES} -l${CORES}"
EMERGE_DEFAULT_OPTS="--load-average=${CORES} --quiet-build=y --usepkg --buildpkg"
FEATURES="\${FEATURES} buildpkg"
EOF

    # 清除缓存里所有 9999 包的 binpkg。它们版本号恒为 9999，git 源更新后 portage 不会重打，
    # --usepkg 会复用陈旧 binpkg，装进缺功能的旧版。删文件后必须重建 Packages 索引，
    # 否则 portage 按旧索引调度已删的包，报 non-existent binary 失败。
    # 非 9999 包的缓存照常复用。
    mkdir -p "${CACHE_BINPKG}" "${CACHE_DISTFILES}"
    local purged
    purged=$(find "${CACHE_BINPKG}" -type f -name '*-9999*' 2>/dev/null | wc -l)
    find "${CACHE_BINPKG}" -type f -name '*-9999*' -delete 2>/dev/null || true
    PKGDIR="${CACHE_BINPKG}" emaint binhost --fix >/dev/null 2>&1 || true
    log "已清 live/9999 binpkg 缓存 ${purged} 个并重建索引"

    # 出厂清理用仓库里的 hooks/99-sanitize-for-release.sh(build.sh 会 source 整个 hooks/),不再从这里覆盖装陈旧副本;exclude.txt 兜底排除构建调优文件。
    local line
    for line in 'etc/portage/make.conf/zz-buildhost'; do
        grep -qxF "${line}" "${WORK}/exclude.txt" 2>/dev/null || echo "${line}" >> "${WORK}/exclude.txt"
    done
    log "已补 exclude.txt 兜底(出厂清理用仓库内 hook)"
}

# 3. 跑构建
run_build() {
    log "开始构建（日志同上，预计数小时）…"
    cd "${WORK}" || fail "cd 失败"
    bash ./build.sh >>"${LOG}" 2>&1 || fail "build.sh 退出非零，详见 ${LOG}"
    log "[OK] build.sh 完成"
}

# 4. 定位产物 + 完整性验证 + 校验和
# verify-iso.sh 挂 squashfs 实检 calamares/rime/字体/locale/双驱动等；rc 0=全过 1=仅警告 2=关键缺失。
verify_iso() {
    ISO="$(ls -1t "${WORK}"/gig-os-*.iso 2>/dev/null | head -n1)"
    [ -n "${ISO}" ] && [ -f "${ISO}" ] || fail "未找到产物 ISO"
    ISO_NAME="$(basename "${ISO}")"
    ISO_SIZE="$(du -h "${ISO}" | cut -f1)"
    log "产物：${ISO_NAME}（${ISO_SIZE}）"

    if [ -x "${PERSIST}/verify-iso.sh" ]; then
        log "完整性验证（挂 squashfs 实检 calamares/rime/字体/locale…）"
        "${PERSIST}/verify-iso.sh" "${ISO}" 2>&1 | tee -a "${LOG}"
        local rc="${PIPESTATUS[0]}"
        if [ "${rc}" -ge 2 ]; then
            PRESERVE=1; fail "完整性验证发现关键项缺失（rc=${rc}），拒绝上线（tmpfs 保留待查：${WORK}）"
        elif [ "${rc}" -eq 1 ]; then
            log "[警告] 完整性验证有非致命警告（rc=1），继续"
        else
            log "[OK] 完整性验证全通过"
        fi
    else
        log "[警告] 未找到 verify-iso.sh，跳过内容门控"
        notify WARN "未找到 verify-iso.sh，本锅跳过内容门控，请确认部署"
    fi

    log "计算校验和…"
    ( cd "${WORK}" && md5sum "${ISO_NAME}" > "${ISO_NAME}.md5" && sha256sum "${ISO_NAME}" > "${ISO_NAME}.sha256" ) \
        || fail "校验和计算失败"
    SHA="$(awk '{print $1}' "${WORK}/${ISO_NAME}.sha256")"
}

# 5. 暂存到 SSD，上传失败可重传而不必重编。
# 上传瞬时失败时，tmpfs 里的成品已被 cleanup 清除，只能重编几小时。先把验证通过的 ISO 拷到
# SSD，之后所有上传从 SSD 取。BUILD_MANIFEST 与 ISO 同生同死，reupload-iso.sh 据它判断
# 有没有可重传的盘，不盲传旧盘。
stage_iso() {
    mkdir -p "${STAGE}"
    # 先落新盘、再删旧盘：避免"先删旧、拷新前被杀"两头空。
    cp -f "${WORK}/${ISO_NAME}" "${WORK}/${ISO_NAME}.md5" "${WORK}/${ISO_NAME}.sha256" "${STAGE}/" \
        || fail "暂存 ISO 到 SSD 失败"
    find "${STAGE}" -maxdepth 1 -name 'gig-os-*.iso*' \
         ! -name "${ISO_NAME}" ! -name "${ISO_NAME}.md5" ! -name "${ISO_NAME}.sha256" -delete 2>/dev/null || true
    rm -f "${STAGE}/BUILD_MANIFEST" "${STAGE}/BUILD_MANIFEST.tmp" 2>/dev/null || true
    # 先写 .tmp 再原子 mv，避免半截 manifest 被 reupload 读到。值加引号（BUILD_DONE 含空格）。
    cat > "${STAGE}/BUILD_MANIFEST.tmp" <<EOF
RUN_STAMP="${STAMP}"
GIT_COMMIT="${GIT_COMMIT}"
GIT_BRANCH="${REPO_BRANCH}"
ISO_NAME="${ISO_NAME}"
ISO_SHA256="${SHA}"
ISO_SIZE="${ISO_SIZE}"
BUILD_DONE="$(date '+%F %T')"
EOF
    mv -f "${STAGE}/BUILD_MANIFEST.tmp" "${STAGE}/BUILD_MANIFEST" || fail "写 BUILD_MANIFEST 失败"
    log "[OK] ISO 已暂存 + 写 manifest：sha=${SHA:0:12}…（上传失败也不会丢）"
}

# 6. 发布到镜像站。r2.gentoozh.org 已 301 到这里，这是唯一的公开路径，失败即失败。
publish_site() {
    if [ -z "${MIRROR_SSH_TARGET}" ]; then
        log "镜像站：未配置 MIRROR_SSH_TARGET，跳过"
        return 0
    fi
    local ssh_cmd="ssh ${MIRROR_SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15"
    local f
    log "镜像站：上传 ${ISO_NAME} 到 ${MIRROR_SSH_TARGET}:${MIRROR_PATH}…"
    for f in "${ISO_NAME}" "${ISO_NAME}.sha256" "${ISO_NAME}.md5"; do
        [ -f "${STAGE}/${f}" ] || continue
        if ! rsync -a --partial --inplace -e "${ssh_cmd}" \
                "${STAGE}/${f}" "${MIRROR_SSH_TARGET}:${MIRROR_PATH}/" 2>>"${LOG}"; then
            log "[警告] 镜像站上传失败，但 ISO 已验证+暂存：${STAGE}/${ISO_NAME}"
            notify FAILED "镜像站上传失败但 ISO 已暂存：${ISO_NAME}；恢复后执行 reupload-iso.sh（勿重编）；用时 $(fmt_dur)、$(date '+%F %T')"
            NOTIFIED=1; cleanup_mounts; exit 1
        fi
    done

    # 对外核对：公开域名服务的就是本锅。不一致时留在原地由下一锅覆盖，不删。
    # 一并读状态码：404 的错误页也带 content-length，只比长度会把它当成一个尺寸。
    local loc code pub head
    loc=$(stat -c%s "${STAGE}/${ISO_NAME}" 2>/dev/null)
    head=$(curl -sSL -H 'Cache-Control: no-cache' -o /dev/null \
           -w '%{http_code} %{size_upload}' -I "${MIRROR_PUBLIC_BASE}/${ISO_NAME}" 2>/dev/null)
    code=${head%% *}
    pub=$(curl -sSL -H 'Cache-Control: no-cache' -I "${MIRROR_PUBLIC_BASE}/${ISO_NAME}" 2>/dev/null \
          | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)
    if [ "${code:-}" != 200 ] || [ -z "${loc:-}" ] || [ "${pub:-0}" != "${loc}" ]; then
        fail "镜像站对外核对失败：HTTP ${code:-空}，content-length=${pub:-空} != 本地 ${loc:-空}"
    fi
    log "[OK] 镜像站已发布且对外核对一致：${MIRROR_PUBLIC_BASE}/${ISO_NAME}（${loc} bytes）"

    # 保留最近 MIRROR_KEEP 份，本锅永不删。
    local keep_i=0 old
    while read -r old; do
        keep_i=$((keep_i+1))
        [ "${keep_i}" -le "${MIRROR_KEEP}" ] && continue
        [ "${old}" = "${ISO_NAME}" ] && continue
        log "镜像站删旧：${old}"
        ${ssh_cmd} "${MIRROR_SSH_TARGET}" \
            "rm -f ${MIRROR_PATH}/${old} ${MIRROR_PATH}/${old}.sha256 ${MIRROR_PATH}/${old}.md5" \
            2>>"${LOG}" || true
    done < <(${ssh_cmd} "${MIRROR_SSH_TARGET}" "ls -1 ${MIRROR_PATH}" 2>/dev/null \
             | grep -E '^gig-os-[0-9]{8}\.iso$' | sort -r)
}

# 7. 落地页是 Worker 读镜像站列表的视图，有边缘缓存滞后，因此只探测不拦下整锅，
# 状态并进末尾的成功通知。
check_landing() {
    local i found=0
    for i in 1 2 3 4 5 6; do
        curl -fsSL -H 'Cache-Control: no-cache' "${MIRROR_URL}?_=$(date +%s)-${i}" 2>/dev/null | grep -qF "${ISO_NAME}" \
            && { found=1; break; }
        [ "${i}" -lt 6 ] && sleep 20
    done
    if [ "${found}" = 1 ]; then
        log "[OK] 落地页已反映新镜像"
    else
        log "落地页暂未反映（镜像站已上线、核对一致；Worker 缓存稍后自动刷新）"
        MIRROR_NOTE="（落地页稍后自动刷新）"
    fi
}

# 8. 收尾
finish() {
    log "===== [OK] 全部完成：${ISO_NAME}（源 ${REPO_BRANCH}@${GIT_COMMIT}）====="
    notify OK "成功：${ISO_NAME}（源 ${REPO_BRANCH}@${GIT_COMMIT}）已上线 ${MIRROR_PUBLIC_BASE} 并通过对外核对（sha ${SHA:0:12}…）iso.gentoozh.org${MIRROR_NOTE}；用时 $(fmt_dur)、$(date '+%F %T')"
    DONE=1
    ls -1t "${LOG_DIR}"/build-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f   # 只留最近 10 份日志
}

# 主流程
main() {
    (( EUID == 0 )) || { echo "需以 root 运行"; exit 1; }
    acquire_lock
    rm -f "${SELFNOTIFIED}" 2>/dev/null || true     # 清上锅遗留的自通知哨兵
    # 信号杀时显式退非零，否则 EXIT 陷阱里 $? 读成 0 → on_exit 误判成功、漏发 FAILED
    trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
    trap on_exit EXIT

    log "===== Live ISO 自动构建开始（${STAMP}）====="
    log "构建机：$(hostname) / ${CORES} 核 / RAM $(free -g | awk '/Mem:/{print $2}')G"
    notify START "已触发，准备拉取源码 $(date '+%F %T')"

    wait_for_idle_cpu
    preflight
    update_source
    prepare_workdir
    run_build
    verify_iso
    stage_iso
    publish_site
    check_landing
    finish
}

main "$@"
