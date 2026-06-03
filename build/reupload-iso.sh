#!/bin/bash
# 从 /opt/live-iso-builder/last-iso/ 重传【已验证】ISO 到下载站(不重编)。
#
# 以 last-iso/BUILD_MANIFEST 为唯一权威身份(构建脚本 stage 成功时原子写入):
#   无 manifest / 实盘 sha 与 manifest 不符 / RUN_STAMP 陈旧  → 拒绝盲传。
# 这是事故直接修复:旧版盲取 last-iso 里"最新一盘"就推,曾把崩在 stage 前残留的旧坏盘
# (early-KMS 炸显卡 / 无 calamares-r8 / 装机清理为空=后门)推上站还发了通知。
#
# 注意:下载站 root shell 是 zsh,rm -f dir/* 空目录会 nomatch 报错 → 用 rm -rf+mkdir。
set -uo pipefail
STAGE=/opt/live-iso-builder/last-iso
LOCK=/run/live-iso-build.lock
. /opt/live-iso-builder/config.env || { echo "missing config.env"; exit 1; }

notify(){ [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT:-}" ] || return 0
  curl -fsS -m 20 "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d "chat_id=${TG_CHAT}" --data-urlencode "text=[$1] gig-os 重传:$2" >/dev/null 2>&1 || true; }
DONE=0; NOTIFIED=0
on_exit(){ local rc=$?; [ "$DONE" = 1 ] && return 0; [ "$NOTIFIED" = 1 ] && return 0; [ "$rc" = 0 ] && return 0
  echo "[错误] 重传异常退出(rc=$rc)"; notify FAILED "重传异常中止(rc=$rc)"; }
# 手动跑时 Ctrl-C/挂断也要让 on_exit 读到真 rc 发 FAILED(否则 $? 读成 0 漏发)
trap 'exit 143' TERM; trap 'exit 130' INT; trap 'exit 129' HUP
trap on_exit EXIT

# 防并发:与自动构建共用同一把锁(构建在跑就别同时重传,避免互删 .incoming / 并发 render)
exec 9>"$LOCK"
flock -n 9 || { echo "[错误] 已有构建/重传在跑($LOCK 被占),退出"; DONE=1; exit 0; }

SSH="ssh -p $M_PORT -i $M_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=20"
SCP="scp -P $M_PORT -i $M_KEY -o StrictHostKeyChecking=accept-new -o BatchMode=yes"

# ── 以 BUILD_MANIFEST 为权威,三道闸 ──────────────────────────
MANIFEST="$STAGE/BUILD_MANIFEST"
[ -f "$MANIFEST" ] || { echo "[错误] 无 BUILD_MANIFEST:last-iso/ 非成功构建产物(很可能崩在 stage 前的旧盘),拒绝上传"; notify FAILED "拒绝重传:last-iso 无 BUILD_MANIFEST(疑似旧盘)"; NOTIFIED=1; exit 1; }
. "$MANIFEST"
NAME="${ISO_NAME:-}"; SHA="${ISO_SHA256:-}"; STAMP="${RUN_STAMP:-}"
[ -n "$NAME" ] && [ -n "$SHA" ] || { echo "[错误] BUILD_MANIFEST 残缺(缺 ISO_NAME/ISO_SHA256)"; notify FAILED "拒绝重传:manifest 残缺"; NOTIFIED=1; exit 1; }
[ -f "$STAGE/$NAME" ] || { echo "[错误] manifest 指向 $NAME 但实盘不存在"; notify FAILED "拒绝重传:$NAME 实盘不存在"; NOTIFIED=1; exit 1; }
echo "[*] manifest: stamp=$STAMP commit=${GIT_COMMIT:-?} iso=$NAME sha=${SHA:0:12}…"
echo "    实盘 mtime=$(date -r "$STAGE/$NAME" '+%F %T') 大小=$(du -h "$STAGE/$NAME"|cut -f1)"
# (1) 实盘 sha256 必须与 manifest 对账(不信旁 .sha256:旧盘配旧 sha 也自洽)
REAL_SHA=$(sha256sum "$STAGE/$NAME" | awk '{print $1}')
[ "$REAL_SHA" = "$SHA" ] || { echo "[错误] 实盘 sha256 与 manifest 不符(盘被换/损坏):实=$REAL_SHA 录=$SHA"; notify FAILED "拒绝重传:实盘 sha 与 manifest 不符"; NOTIFIED=1; exit 1; }
# (2) 陈旧闸:RUN_STAMP(形如 20260604-040000)超过 14 天需显式 --force / CONFIRM=1
d="${STAMP%-*}"; t="${STAMP#*-}"
ST_EPOCH=$(date -d "${d:0:4}-${d:4:2}-${d:6:2} ${t:0:2}:${t:2:2}:${t:4:2}" +%s 2>/dev/null || echo 0)
if [ "$ST_EPOCH" != 0 ]; then
  AGE_DAYS=$(( ( $(date +%s) - ST_EPOCH ) / 86400 ))
  if [ "$AGE_DAYS" -gt 14 ] && [ "${1:-}" != "--force" ] && [ "${CONFIRM:-}" != 1 ]; then
    echo "[警告] 这锅 stamp=$STAMP 已 ${AGE_DAYS} 天,疑似陈旧。确认要重传请:CONFIRM=1 $0  或  $0 --force"
    notify WARN "重传被陈旧闸拦下:$NAME stamp=$STAMP(${AGE_DAYS}天),需 --force"; NOTIFIED=1; exit 1
  fi
fi
echo "[OK] manifest 三道闸通过,准备重传 $NAME"

# ── 上传(不做破坏性预清理;清理放到上线成功后)────────────────
$SSH "$M_USER@$M_HOST" "rm -rf '$M_ISODIR/.incoming'; mkdir -p '$M_ISODIR/.incoming'" || { echo 建incoming失败; notify FAILED "重传:建 .incoming 失败"; NOTIFIED=1; exit 1; }
echo "scp $(du -h "$STAGE/$NAME"|cut -f1) 中(HK→US,几分钟)…"
$SCP "$STAGE/$NAME" "$STAGE/$NAME.md5" "$STAGE/$NAME.sha256" "$M_USER@$M_HOST:$M_ISODIR/.incoming/" || { echo scp失败; notify FAILED "重传:scp 失败"; NOTIFIED=1; exit 1; }
$SSH "$M_USER@$M_HOST" "bash -s" <<R
set -e
cd '$M_ISODIR/.incoming'
echo '$SHA  $NAME' | sha256sum -c -
chmod 644 '$NAME' '$NAME.md5' '$NAME.sha256'
mv -f '$NAME.sha256' '$NAME.md5' '$M_ISODIR/'
mv -f '$NAME' '$M_ISODIR/'
cd '$M_ISODIR'
echo '$SHA  $NAME' | sha256sum -c -
echo "OK 已上线且 live 回读一致 $NAME"
R
[ $? -eq 0 ] || { echo "[错误] 远端上线/回读失败"; notify FAILED "重传:远端上线/回读失败 $NAME"; NOTIFIED=1; exit 1; }

# ── 上线成功后才清理 + 渲染(本盘永不删)────────────────────────
$SSH "$M_USER@$M_HOST" "ISO_DIR='$M_ISODIR' KEEP=$KEEP KEEPNAME='$NAME' /usr/local/bin/cleanup-old-iso.sh; SKIP_SHA_SELFCHECK=1 /usr/local/bin/render-index.sh" || echo "清理/渲染告警"

# ── 端到端核对:站上对外【实际服务】的就是这盘 ──────────────────
if [ -n "${M_URLBASE:-}" ]; then
  RSHA=$(curl -fsS -m 30 -H 'Cache-Control: no-cache' "${M_URLBASE}/${NAME}.sha256" 2>/dev/null | awk '{print $1}')
  PAGE=$(curl -fsS -m 30 -H 'Cache-Control: no-cache' "${M_PAGEURL:-${M_URLBASE%/*}/}" 2>/dev/null)
  if [ "$RSHA" = "$SHA" ] && printf '%s' "$PAGE" | grep -qF "$NAME" && printf '%s' "$PAGE" | grep -qiF "$SHA"; then
    echo "[OK] 对外核对:站上=本盘 $NAME"
    notify OK "重传成功并通过对外核对:$NAME(sha ${SHA:0:12}…)"
  else
    echo "[错误] 对外核对失败:站上 sha=${RSHA:-空} 期望=$SHA(可能渲染了旧盘)"
    notify FAILED "重传后对外核对失败:站上不是 $NAME"; NOTIFIED=1; exit 1
  fi
else
  echo "[警告] 未配 M_URLBASE,跳过对外核对(强烈建议配上)"
  notify WARN "重传完成但未做对外核对(M_URLBASE 未配):$NAME"
fi

DONE=1   # 上线+核对都过=真成功;放在收尾展示之前,免得展示用的 ls 瞬时抖动/nomatch 误触发 on_exit 的 FAILED
echo "=== 完成,下载站现有 ==="
$SSH "$M_USER@$M_HOST" "ls -lh '$M_ISODIR'/gig-os-*.iso" 2>/dev/null || true
