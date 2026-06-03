#!/bin/bash
# 下载站：根据 iso 目录里最新的 gig-os-*.iso，把落地页模板渲染成静态 index.html。
# 动态字段：文件名、大小、构建日期、SHA256/MD5 链接。纯静态产出（无客户端 JS 依赖，
# 文本浏览器/无脚本环境同样正确）。由上传脚本在每次部署新 ISO 后调用，也可手动跑。
#
# 用法：[TMPL=/srv/mirror/index.html.tmpl OUT=/srv/mirror/index.html ISO_DIR=/srv/mirror/iso] render-index.sh
set -uo pipefail

TMPL="${TMPL:-/srv/mirror/index.html.tmpl}"
OUT="${OUT:-/srv/mirror/index.html}"
ISO_DIR="${ISO_DIR:-/srv/mirror/iso}"

[ -f "${TMPL}" ] || { echo "[错误] 模板不存在：${TMPL}"; exit 1; }

# 最新 ISO（文件名 gig-os-YYYYMMDD.iso，字典序即时间序）
ISO_NAME="$(ls -1 "${ISO_DIR}"/gig-os-*.iso 2>/dev/null | xargs -r -n1 basename | sort -r | head -n1)"
[ -n "${ISO_NAME}" ] || { echo "[错误] ${ISO_DIR} 下没有 gig-os-*.iso，保留现有 index.html"; exit 1; }

ISO_PATH="${ISO_DIR}/${ISO_NAME}"

# 校验值(从 .sha256/.md5 取首字段;hex 无 sed 特殊字符,安全)
ISO_SHA256="$(awk '{print $1}' "${ISO_PATH}.sha256" 2>/dev/null)"
ISO_MD5="$(awk '{print $1}' "${ISO_PATH}.md5" 2>/dev/null)"

# 自洽门控:渲染前重算实盘 sha256 与旁 .sha256 对账。不符=盘损坏/被换/上传截断,拒绝把它
# 渲染进对外落地页(最后一道:即便上游闸被绕过,也不给坏盘发对外下载页)。无 .sha256 则退回
# 旧行为(仅 line 下方的缺文件告警),不硬拦,兼容无 sidecar 的历史盘,避免 false-abort。
# SKIP_SHA_SELFCHECK=1:调用方(build/reupload)上线时已做过 live 回读核对,免在此重复算 3.8G;
# 手动单跑 render-index(不传该变量)仍做自洽校验,保留独立安全网。
if [ "${SKIP_SHA_SELFCHECK:-0}" != 1 ] && [ -n "${ISO_SHA256}" ]; then
    REAL="$(sha256sum "${ISO_PATH}" | awk '{print $1}')"
    [ "${REAL}" = "${ISO_SHA256}" ] || { echo "[错误] ${ISO_NAME} 实盘 sha256 与旁文件不符(盘损坏/被换/截断),拒绝渲染落地页"; exit 1; }
fi

# 大小（人类可读，如 3.8 GB）
ISO_SIZE="$(du -b "${ISO_PATH}" | cut -f1 | awk '{
  s=$1; if (s>=1073741824) printf "%.1f GB", s/1073741824;
  else if (s>=1048576) printf "%.0f MB", s/1048576;
  else printf "%d B", s }')"

# 构建日期：优先从文件名 gig-os-YYYYMMDD.iso 提取，取不到则退回文件 mtime
d="$(echo "${ISO_NAME}" | grep -oE '[0-9]{8}' | head -n1)"
if [ -n "${d}" ]; then
    ISO_DATE="${d:0:4}-${d:4:2}-${d:6:2}"
else
    ISO_DATE="$(date -r "${ISO_PATH}" +%Y-%m-%d)"
fi

# 校验文件存在性提醒（不阻塞渲染；缺了链接会 404，先告警）
for ext in sha256 md5; do
    [ -f "${ISO_PATH}.${ext}" ] || echo "[警告] 缺校验文件：${ISO_NAME}.${ext}（落地页该链接将 404）"
done

# 渲染：占位符替换（ISO_NAME 不含特殊正则字符，安全）
tmp="$(mktemp)"
sed -e "s/@@ISO_NAME@@/${ISO_NAME}/g" \
    -e "s/@@ISO_SIZE@@/${ISO_SIZE}/g" \
    -e "s/@@ISO_DATE@@/${ISO_DATE}/g" \
    -e "s|@@ISO_SHA256@@|${ISO_SHA256}|g" \
    -e "s|@@ISO_MD5@@|${ISO_MD5}|g" \
    "${TMPL}" > "${tmp}" || { echo "[错误] 渲染失败"; rm -f "${tmp}"; exit 1; }

# 兜底：确认没有残留占位符
if grep -q '@@ISO_' "${tmp}"; then
    echo "[错误] 渲染后仍有未替换占位符，放弃覆盖"; grep -o '@@ISO_[A-Z]*@@' "${tmp}" | sort -u; rm -f "${tmp}"; exit 1
fi

install -m 644 "${tmp}" "${OUT}" && rm -f "${tmp}"
echo "[OK] 已渲染落地页：${ISO_NAME} · ${ISO_SIZE} · ${ISO_DATE} → ${OUT}"

# 顺手清理累积的 index.html 备份，只留最近 3 个（防小盘被备份占满）
ls -1t "$(dirname "${OUT}")"/index.html.bak.* 2>/dev/null | tail -n +4 | xargs -r rm -f
