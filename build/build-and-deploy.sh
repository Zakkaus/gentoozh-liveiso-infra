#!/bin/bash
# Gentoo 中文社区 Live ISO 自动构建 + 镜像站发布
# 只做编排，构建本身在 Live-ISO 仓库的 build.sh。由 systemd timer 触发，需 root。

set -uo pipefail

SELF_DIR="$(dirname "$(readlink -f "$0")")"
PERSIST="/opt/live-iso-builder"
SRC="${PERSIST}/Live-ISO"
STAGE="${PERSIST}/last-iso"                 # 验证通过的 ISO 暂存，上传失败可重传
LOG_DIR="${PERSIST}/logs"
CACHE_BINPKG="${PERSIST}/cache/binpkgs"     # 跨次复用的 binpkg 缓存
CACHE_DISTFILES="${PERSIST}/cache/distfiles"

# 因为这台是共享机、其他编译也要内存，所以默认落磁盘，速度差别由 binpkg 缓存补回。
USE_TMPFS="${USE_TMPFS:-0}"                 # 1=工作区挂 tmpfs;0=落磁盘
TMPROOT="/mnt/isobuild"
WORK="${TMPROOT}/Live-ISO"
TMPFS_SIZE="72G"                            # 峰值约 23G，留 3 倍余量
LOCK="/run/live-iso-build.lock"
SELFNOTIFIED="/run/live-iso-build.selfnotified"

REPO_URL="https://github.com/Gig-OS/Live-ISO.git"
REPO_BRANCH="KDE"                           # Gig-OS 上游的构建分支，社区 fork 的改动已合并至此
CORES="$(nproc)"

# 开始前整机 CPU ≥ BUSY_PCT 则等待 DEFER_MIN 分钟再查，最多 MAX_DEFERS 次
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

# MIRROR_* / TG_* 等密钥与默认值覆盖从 config.env 读，不入库。
CONFIG_ENV="${PERSIST}/config.env"
[ -f "${CONFIG_ENV}" ] || { echo "缺 ${CONFIG_ENV}（从 config.env.example 复制并填）"; exit 1; }
. "${CONFIG_ENV}"

mkdir -p "${LOG_DIR}"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${LOG_DIR}/build-${STAMP}.log"
BUILD_START="$(date +%s)"

# 跨阶段结果先置空，供 set -u 下的后续函数读取
GIT_COMMIT=""; ISO=""; ISO_NAME=""; ISO_SIZE=""; SHA=""; MIRROR_NOTE=""
DONE=0; NOTIFIED=0      # 退出陷阱据此去重：DONE=到达正常终点，NOTIFIED=已显式通知

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "${LOG}"; }

fmt_dur() { local d=$(( $(date +%s) - BUILD_START )); printf '%d时%d分' $((d/3600)) $(((d%3600)/60)); }

# 发 FAILED 时落哨兵文件供 systemd OnFailure 去重：本脚本已通知过，OnFailure 就不再补发。
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

# 逆序卸载 build.sh 在 squashfs 内建立的 bind/tmpfs，再卸载 tmpfs 工作区本身。
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

# 未到正常终点又未经 fail 通知的非零退出在此补发 FAILED，避免静默失败。
# flock 抢锁失败以 exit 0 结束，且当时陷阱尚未安装，不会误报。
on_exit() {
    local rc=$?
    if [ "${DONE}" != 1 ] && [ "${NOTIFIED}" != 1 ] && [ "${rc}" != 0 ]; then
        log "[错误] 构建未到终点即退出（rc=${rc}），补发 FAILED"
        notify FAILED "异常中止（rc=${rc}）；用时 $(fmt_dur)、$(date '+%F %T')；日志 ${LOG##*/}"
    fi
    cleanup_mounts
}

# wrapper 级锁（build.sh 另有一把）：同一时刻只允许一次构建。
acquire_lock() {
    exec 9>"${LOCK}"
    flock -n 9 || { echo "已有构建在执行（${LOCK} 被占），退出。"; exit 0; }
}

# 整机 CPU 使用率，返回整数百分比。
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

# CPU 忙则延后；达上限仍忙则照常开始，不无限等待。
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

# 3 次重试：瞬时 TLS/DNS/5xx 抖动不应中止这次构建。
git_reachable() {
    local n=0
    until git ls-remote --exit-code "$@" >/dev/null 2>&1; do
        n=$((n+1)); [ "${n}" -ge 3 ] && return 1
        sleep 10
    done
}

# 装机刚需的两个 fork 必须可达：缺失会产出无 calamares 安装器、或装机不清理（等于后门）的坏盘。
preflight_overlays() {
    log "预检：gig overlay（calamares 来源）+ settings-gig fork 可达…"
    git_reachable -h https://github.com/Gig-OS/gig.git \
        || { log "[错误] Gig-OS/gig overlay 连续 3 次不可达"; return 1; }
    # 装的是主树的 calamares，gig 只提供 calamares-settings-gig，所以确认后者在。
    # API 失败只警告不中止（避免限流误判），版本由 verify-iso 按 vdb 实测把关。
    local eb
    eb=$(curl -fsS -m 20 "https://api.github.com/repos/Gig-OS/gig/contents/app-admin/calamares-settings-gig" 2>/dev/null \
         | grep -oE '"name": "calamares-settings-gig-[0-9]+\.ebuild"' | head -1)
    [ -n "${eb}" ] && log "  [OK] gig overlay 含 calamares-settings-gig ebuild" \
        || log "  [警告] 未能经 API 确认 calamares-settings-gig ebuild（限流？），不阻断"
    git_reachable https://github.com/Gig-OS/calamares-settings-gig.git \
        || { log "[错误] Gig-OS/calamares-settings-gig 连续 3 次不可达"; return 1; }
    log "  [OK] settings-gig 仓库可达"
    # gentoo-zh 只提供非装机刚需包，不可达不阻断。
    local ov
    for ov in "gentoo-zh|https://github.com/gentoo-zh/overlay.git"; do
        git_reachable "${ov##*|}" || log "[警告] ${ov%%|*} overlay 暂不可达（非刚需，继续）"
    done
}

# 落磁盘构建峰值约 23G，要求 60G 以留出 squashfs 与 ISO 的余量。
preflight_disk() {
    local avail need=60
    avail=$(df -BG --output=avail "$(dirname "${TMPROOT}")" 2>/dev/null | tail -1 | tr -dc '0-9')
    [ -n "${avail}" ] || avail=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
    log "预检：磁盘空间（落盘构建）…"
    log "  可用 ${avail}G，需 ${need}G"
    [ "${avail}" -ge "${need}" ] || { log "[错误] 磁盘空间不足：${avail}G < 需 ${need}G"; return 1; }
}

# tmpfs 是上限不是预留，按约 7 成上限的真实工作集估算需求，避免阈值不可达导致每次构建前自我中止。
preflight_ram() {
    log "预检：内存能否装下 ${TMPFS_SIZE} tmpfs…"
    local want avail need
    want="$(printf '%s' "${TMPFS_SIZE}" | tr -dc '0-9')"
    avail=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 / 1024 ))
    need=$(( want * 7 / 10 ))
    log "  MemAvailable ${avail}G，需工作集约 ${need}G"
    [ "${avail}" -ge "${need}" ] || { log "[错误] 可用内存不足：${avail}G < 需 ${need}G"; return 1; }
}

# 镜像站是唯一发布目标，须可 ssh 且落地目录可写。
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

# 网络 git 操作一律加 timeout，跨境 TLS 卡死时不会无限挂起而形成既无 START 也无 FAILED 的盲窗。
update_source() {
    log "更新源仓库 ${SRC}（${REPO_URL} @ ${REPO_BRANCH}）…"
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
    log "本次源码：${REPO_BRANCH}@${GIT_COMMIT}"
    # 本地与远端不一致只警告，不中止这次构建
    local remote_head
    remote_head="$(git -C "${SRC}" rev-parse --short "origin/${REPO_BRANCH}" 2>/dev/null || echo '')"
    [ -n "${remote_head}" ] && [ "${GIT_COMMIT}" != "${remote_head}" ] \
        && notify WARN "源码非最新：本次 ${GIT_COMMIT} != origin ${remote_head}（fetch 可能失败、用了旧副本）"
}

prepare_workdir() {
    cleanup_mounts                                  # 清除上次残留
    mkdir -p "${TMPROOT}"
    if [ "${USE_TMPFS}" = 1 ]; then
        log "挂载 ${TMPFS_SIZE} tmpfs 到 ${TMPROOT}（全内存构建）…"
        mount -t tmpfs -o size="${TMPFS_SIZE}",mode=755 tmpfs "${TMPROOT}" || fail "tmpfs 挂载失败"
    else
        # 因为落磁盘时上一次的文件不会随 umount 消失，所以这里显式清空，避免残留混进本次。
        log "落磁盘构建，清空工作区 ${TMPROOT}…"
        rm -rf "${TMPROOT:?}/"* 2>/dev/null || true
    fi
    log "拷贝源码副本到工作区…"
    cp -a "${SRC}" "${WORK}" || fail "拷贝失败"

    # host 专属参数经环境变量传给 build.sh，其 config 用 := 取默认值，env 可覆盖。
    export CORES="${CORES}"
    export TMPFS=""                                 # 整个 WORK 已在 tmpfs，chroot 内不再单独挂
    export MAKEOPTS="-j${CORES} -l${CORES}"
    export BINPKG_CACHE="${CACHE_BINPKG}"           # build.sh 据此把宿主缓存 bind 进 chroot
    export DISTFILES_CACHE="${CACHE_DISTFILES}"

    # 仅构建机用的 make.conf 调优，出厂前由 99-sanitize 删除、exclude.txt 兜底。
    # zz- 前缀使其按字母序最后加载以覆盖 common；--load-average 防止满核并发引发内存雪崩。
    cat > "${WORK}/include-squashfs/etc/portage/make.conf/zz-buildhost" <<EOF
MAKEOPTS="-j${CORES} -l${CORES}"
EMERGE_DEFAULT_OPTS="--load-average=${CORES} --quiet-build=y --usepkg --buildpkg"
FEATURES="\${FEATURES} buildpkg"
EOF

    # 9999 包版本号恒定，git 源更新后 portage 不重新打包，--usepkg 会复用陈旧 binpkg，
    # 因此每次都清除并重建 Packages 索引；不重建则 portage 按旧索引调度已删除的包而失败。
    mkdir -p "${CACHE_BINPKG}" "${CACHE_DISTFILES}"
    local purged
    purged=$(find "${CACHE_BINPKG}" -type f -name '*-9999*' 2>/dev/null | wc -l)
    find "${CACHE_BINPKG}" -type f -name '*-9999*' -delete 2>/dev/null || true
    PKGDIR="${CACHE_BINPKG}" emaint binhost --fix >/dev/null 2>&1 || true
    log "已清 live/9999 binpkg 缓存 ${purged} 个并重建索引"

    # 缓存跨次复用，overlay 从 config 的 OVERLAYS 移除后其 binpkg 仍留在缓存，--usepkg 会把它装回，
    # 而对应仓库已不在 repos.conf。允许的仓库取自本次源码的 OVERLAYS 加 gentoo，其余一律清除。
    local allowed stale
    allowed=$(sed -n '/^OVERLAYS=(/,/^)/p' "${WORK}/config" 2>/dev/null \
              | sed -n 's/.*"\([a-z0-9-]*\)|.*/\1/p' | tr '\n' ' ')
    allowed="gentoo ${allowed}"
    if [ -s "${CACHE_BINPKG}/Packages" ]; then
        stale=$(awk -v ok=" ${allowed} " '
            /^CPV: /{cpv=$2} /^REPO: /{ if (index(ok, " " $2 " ")==0) print cpv }
        ' "${CACHE_BINPKG}/Packages" | sort -u)
        if [ -n "${stale}" ]; then
            local cp
            for cp in ${stale}; do
                rm -rf "${CACHE_BINPKG}/${cp%-[0-9]*}" 2>/dev/null || true
            done
            PKGDIR="${CACHE_BINPKG}" emaint binhost --fix >/dev/null 2>&1 || true
            log "已清来自已移除 overlay 的 binpkg：$(echo ${stale} | tr '\n' ' ')"
        fi
    fi

    # 出厂清理由仓库内的 hooks/99-sanitize-for-release.sh 负责，此处只补 exclude.txt 兜底排除构建调优文件。
    local line
    for line in 'etc/portage/make.conf/zz-buildhost'; do
        grep -qxF "${line}" "${WORK}/exclude.txt" 2>/dev/null || echo "${line}" >> "${WORK}/exclude.txt"
    done
    log "已补 exclude.txt 兜底(出厂清理用仓库内 hook)"
}

run_build() {
    log "开始构建（日志同上，预计数小时）…"
    cd "${WORK}" || fail "cd 失败"
    bash ./build.sh >>"${LOG}" 2>&1 || fail "build.sh 退出非零，详见 ${LOG}"
    log "[OK] build.sh 完成"
}

# verify-iso.sh 的退出码：0=全通过，1=仅警告，2=关键项缺失。
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
        notify WARN "未找到 verify-iso.sh，本次跳过内容门控，请确认部署"
    fi

    log "计算校验和…"
    ( cd "${WORK}" && md5sum "${ISO_NAME}" > "${ISO_NAME}.md5" && sha256sum "${ISO_NAME}" > "${ISO_NAME}.sha256" ) \
        || fail "校验和计算失败"
    SHA="$(awk '{print $1}' "${WORK}/${ISO_NAME}.sha256")"
}

# 验证通过的 ISO 先暂存到 SSD，上传失败可重传而不必重新构建，因为 tmpfs 内的产物会被 cleanup 清除。
# BUILD_MANIFEST 与 ISO 同生同死，reupload-iso.sh 据它判断有无可重传的产物，不盲传旧产物。
stage_iso() {
    mkdir -p "${STAGE}"
    # 先写入新产物再删除旧产物，避免删除后、复制完成前中断而两头落空。
    cp -f "${WORK}/${ISO_NAME}" "${WORK}/${ISO_NAME}.md5" "${WORK}/${ISO_NAME}.sha256" "${STAGE}/" \
        || fail "暂存 ISO 到 SSD 失败"
    find "${STAGE}" -maxdepth 1 -name 'gig-os-*.iso*' \
         ! -name "${ISO_NAME}" ! -name "${ISO_NAME}.md5" ! -name "${ISO_NAME}.sha256" -delete 2>/dev/null || true
    rm -f "${STAGE}/BUILD_MANIFEST" "${STAGE}/BUILD_MANIFEST.tmp" 2>/dev/null || true
    # 先写 .tmp 再原子 mv，避免 reupload 读到半截 manifest。值加引号，因为 BUILD_DONE 含空格。
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

# 镜像站是唯一公开路径（r2.gentoozh.org 已 301 到此），上传失败即判本次失败。
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

    # 核对公开域名服务的确实是本次产物。必须一并判 HTTP 状态码，因为 404 错误页也带 content-length。
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

    # 保留最近 MIRROR_KEEP 份，本次永不删。
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

# 落地页是 Worker 读镜像站列表的视图，有边缘缓存滞后，因此只探测、不中止这次构建。
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

finish() {
    log "===== [OK] 全部完成：${ISO_NAME}（源 ${REPO_BRANCH}@${GIT_COMMIT}）====="
    notify OK "成功：${ISO_NAME}（源 ${REPO_BRANCH}@${GIT_COMMIT}）已上线 ${MIRROR_PUBLIC_BASE} 并通过对外核对（sha ${SHA:0:12}…）iso.gentoozh.org${MIRROR_NOTE}；用时 $(fmt_dur)、$(date '+%F %T')"
    DONE=1
    ls -1t "${LOG_DIR}"/build-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f   # 只留最近 10 份日志
}

main() {
    (( EUID == 0 )) || { echo "需以 root 运行"; exit 1; }
    acquire_lock
    rm -f "${SELFNOTIFIED}" 2>/dev/null || true     # 清除上次遗留的自通知哨兵
    # 收到信号时显式以非零退出，否则 EXIT 陷阱读到 $?=0，on_exit 误判成功而漏发 FAILED
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
