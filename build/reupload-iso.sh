#!/bin/bash
# 从 /opt/live-iso-builder/last-iso/ 把【已验证】ISO 重传到镜像站(不重编)。
# 用途：自动构建里上传那步失败(网络/镜像机故障)时,ISO 已编好+验过+暂存，
# 镜像站恢复后跑本脚本重传即可，不必再烧几小时重编。
#
# 以 last-iso/BUILD_MANIFEST 为唯一权威身份(构建脚本 stage 成功时原子写入):
#   无 manifest / 实盘 sha 与 manifest 不符 / RUN_STAMP 陈旧  → 拒绝盲传。
# 这是事故直接修复：旧版盲取 last-iso 里"最新一盘"就推，曾把崩在 stage 前残留的旧坏盘
# (early-KMS 炸显卡 / 无 calamares-r8 / 装机清理为空=后门)推上站还发了通知。
#
# 任何异常都会推 Telegram(与构建脚本同一 TG_TOKEN/TG_CHAT)。
set -uo pipefail
STAGE=/opt/live-iso-builder/last-iso
LOCK=/run/live-iso-build.lock
. /opt/live-iso-builder/config.env || { echo "missing config.env"; exit 1; }

MIRROR_SSH_TARGET="${MIRROR_SSH_TARGET:-}"
MIRROR_SSH_OPTS="${MIRROR_SSH_OPTS:-}"
MIRROR_PATH="${MIRROR_PATH:-/srv/pub/gigos}"
MIRROR_KEEP="${MIRROR_KEEP:-2}"
MIRROR_PUBLIC_BASE="${MIRROR_PUBLIC_BASE:-https://distfiles.gentoozh.org/gigos}"
MIRROR_URL="${MIRROR_URL:-https://iso.gentoozh.org/}"

notify(){ [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  curl -fsS -m 20 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=[$1] gig-os 重传：$2" >/dev/null 2>&1 || true; }
DONE=0; NOTIFIED=0
on_exit(){ local rc=$?; [ "$DONE" = 1 ] && return 0; [ "$NOTIFIED" = 1 ] && return 0; [ "$rc" = 0 ] && return 0
  echo "[错误] 重传异常退出(rc=$rc)"; notify FAILED "重传异常中止(rc=$rc)"; }
# 手动跑时 Ctrl-C/挂断也要让 on_exit 读到真 rc 发 FAILED(否则 $? 读成 0 漏发)
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
trap on_exit EXIT

# 防并发：与自动构建共用同一把锁(构建执行期间不重传，避免互删旧盘与并发上传)
exec 9>"$LOCK"
flock -n 9 || { echo "[错误] 已有构建或重传在执行($LOCK 被占),退出"; DONE=1; exit 0; }

# ── 配置闸：缺 MIRROR_SSH_TARGET 直接拒绝(镜像站是唯一发布目标)──
[ -n "${MIRROR_SSH_TARGET}" ] \
  || { echo "[错误] config.env 缺 MIRROR_SSH_TARGET"; notify FAILED "拒绝重传:config.env 缺 MIRROR_SSH_TARGET"; NOTIFIED=1; exit 1; }
SSH_CMD="ssh ${MIRROR_SSH_OPTS} -o BatchMode=yes -o ConnectTimeout=15"

# ── 以 BUILD_MANIFEST 为权威，三道闸 ──────────────────────────
MANIFEST="$STAGE/BUILD_MANIFEST"
[ -f "$MANIFEST" ] || { echo "[错误] 无 BUILD_MANIFEST:last-iso/ 非成功构建产物(很可能崩在 stage 前的旧盘),拒绝上传"; notify FAILED "拒绝重传:last-iso 无 BUILD_MANIFEST(疑似旧盘)"; NOTIFIED=1; exit 1; }
. "$MANIFEST"
NAME="${ISO_NAME:-}"; SHA="${ISO_SHA256:-}"; STAMP="${RUN_STAMP:-}"
[ -n "$NAME" ] && [ -n "$SHA" ] || { echo "[错误] BUILD_MANIFEST 残缺(缺 ISO_NAME/ISO_SHA256)"; notify FAILED "拒绝重传:manifest 残缺"; NOTIFIED=1; exit 1; }
[ -f "$STAGE/$NAME" ] || { echo "[错误] manifest 指向 $NAME 但实盘不存在"; notify FAILED "拒绝重传：$NAME 实盘不存在"; NOTIFIED=1; exit 1; }
echo "[*] manifest: stamp=$STAMP commit=${GIT_COMMIT:-?} iso=$NAME sha=${SHA:0:12}…"
echo "    实盘 mtime=$(date -r "$STAGE/$NAME" '+%F %T') 大小=$(du -h "$STAGE/$NAME"|cut -f1)"
# (1) 实盘 sha256 必须与 manifest 对账(不信旁 .sha256:旧盘配旧 sha 也自洽)
REAL_SHA=$(sha256sum "$STAGE/$NAME" | awk '{print $1}')
[ "$REAL_SHA" = "$SHA" ] || { echo "[错误] 实盘 sha256 与 manifest 不符(盘被换/损坏):实=$REAL_SHA 录=$SHA"; notify FAILED "拒绝重传：实盘 sha 与 manifest 不符"; NOTIFIED=1; exit 1; }
# (2) 陈旧闸:RUN_STAMP(形如 20260604-040000)超过 14 天需显式 --force / CONFIRM=1
d="${STAMP%-*}"; t="${STAMP#*-}"
ST_EPOCH=$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null || echo 0)
if [ "$ST_EPOCH" != 0 ]; then
  AGE_DAYS=$(( ( $(date +%s) - ST_EPOCH ) / 86400 ))
  if [ "$AGE_DAYS" -gt 14 ] && [ "${1:-}" != "--force" ] && [ "${CONFIRM:-}" != 1 ]; then
    echo "[警告] 这一轮 stamp=$STAMP 已 ${AGE_DAYS} 天，疑似陈旧。确认要重传请:CONFIRM=1 $0  或  $0 --force"
    notify WARN "重传被陈旧闸拦下：$NAME stamp=$STAMP(${AGE_DAYS}天),需 --force"; NOTIFIED=1; exit 1
  fi
fi
echo "[OK] manifest 三道闸通过，准备重传 $NAME 到镜像站"

# ── 上传到镜像站(唯一发布目标)────────────────────────────────
echo "rsync $(du -h "$STAGE/$NAME"|cut -f1) → ${MIRROR_SSH_TARGET}:${MIRROR_PATH}/${NAME} …"
if ! rsync -a --partial --inplace -e "${SSH_CMD}" "$STAGE/$NAME" "${MIRROR_SSH_TARGET}:${MIRROR_PATH}/"; then
  echo "[错误] 镜像站上传失败"; notify FAILED "重传：镜像站上传失败 $NAME(稍后再试)"; NOTIFIED=1; exit 1
fi
for e in sha256 md5; do [ -f "$STAGE/$NAME.$e" ] && rsync -a -e "${SSH_CMD}" "$STAGE/$NAME.$e" "${MIRROR_SSH_TARGET}:${MIRROR_PATH}/" || true; done

# ── 端到端核对 1:公开域名实际服务的就是这盘(content-length == 本地大小)──
LOC_SIZE=$(stat -c%s "$STAGE/$NAME" 2>/dev/null)
PUB_LEN=$(curl -fsSL -H 'Cache-Control: no-cache' -I "${MIRROR_PUBLIC_BASE}/${NAME}" 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)
if [ -z "${LOC_SIZE:-}" ] || [ "${PUB_LEN:-0}" != "${LOC_SIZE}" ]; then
  echo "[错误] 对外核对失败：${MIRROR_PUBLIC_BASE}/${NAME} content-length=${PUB_LEN:-空} != 本地 ${LOC_SIZE:-空}"
  notify FAILED "重传后对外核对失败：${MIRROR_PUBLIC_BASE}/${NAME} 大小不一致"; NOTIFIED=1; exit 1
fi
echo "[OK] 镜像站已发布且对外核对一致：${MIRROR_PUBLIC_BASE}/${NAME}(${LOC_SIZE} bytes)"

# ── 端到端核对 2:落地页(Worker 读镜像站列表)已列出本盘 ──
MIRROR_OK=0
for i in 1 2 3 4 5 6; do
  if curl -fsSL -H 'Cache-Control: no-cache' "${MIRROR_URL}?_=reup-${i}" 2>/dev/null | grep -qF "${NAME}"; then MIRROR_OK=1; break; fi
  echo "  mirror 落地页暂未反映 ${NAME},20s 后重试(${i}/6)…"; sleep 20
done
if [ "$MIRROR_OK" = 1 ]; then
  echo "[OK] mirror 落地页已反映：${MIRROR_URL}(${NAME})"
else
  echo "[警告] 落地页 ~2 分钟内未反映 ${NAME}(镜像站已上线;Worker 边缘缓存延迟？)"
  notify WARN "重传：镜像站已上线但落地页未及时反映 ${NAME}(稍后手动看 ${MIRROR_URL})"
fi

# ── 保留最近 MIRROR_KEEP 份(gig-os-YYYYMMDD.iso),删更旧的；本盘永不删 ──
mapfile -t _have < <(${SSH_CMD} "${MIRROR_SSH_TARGET}" "ls -1 ${MIRROR_PATH}" 2>/dev/null | grep -E '^gig-os-[0-9]{8}\.iso$' | sort -r)
_i=0; for f in "${_have[@]}"; do _i=$((_i+1)); [ "$_i" -le "$MIRROR_KEEP" ] && continue; [ "$f" = "$NAME" ] && continue
  echo "镜像站删旧：$f(含 .sha256/.md5)"
  ${SSH_CMD} "${MIRROR_SSH_TARGET}" "rm -f ${MIRROR_PATH}/${f} ${MIRROR_PATH}/${f}.sha256 ${MIRROR_PATH}/${f}.md5" || true
done

DONE=1   # 镜像站上线 + 对外核对都过 = 真成功；放在收尾展示之前，免得展示用的 ls 瞬时抖动误触发 on_exit
notify OK "重传成功并通过对外核对：$NAME(sha ${SHA:0:12}…)${MIRROR_PUBLIC_BASE} + iso.gentoozh.org"
echo "=== 完成，镜像站现有 ==="
${SSH_CMD} "${MIRROR_SSH_TARGET}" "ls -1 ${MIRROR_PATH}" 2>/dev/null | grep -E '^gig-os-[0-9]{8}\.iso$' | sort -r || true
