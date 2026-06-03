#!/bin/bash
# 下载站：保留最近 KEEP 个 gig-os-YYYYMMDD.iso（连同 .md5/.sha256），删除更旧的。
# 文件名 gig-os-YYYYMMDD.iso，字典序即时间序，sort -r 取最新在前。
# KEEPNAME(可选)：本锅 ISO 文件名，永不删除（白名单，防被未来日期/手塞垃圾文件挤出 KEEP 误删）。
#
# 用法：ISO_DIR=/srv/mirror/iso KEEP=3 [KEEPNAME=gig-os-20260604.iso] cleanup-old-iso.sh
set -uo pipefail

ISO_DIR="${ISO_DIR:-/srv/mirror/iso}"
KEEP="${KEEP:-3}"
KEEPNAME="${KEEPNAME:-}"
# 兜底：绝不把目录删空。KEEP 最小为 1（防误配 KEEP=0 把全部删光）。
(( KEEP < 1 )) && KEEP=1

cd "${ISO_DIR}" || { echo "[错误] 无法进入 ${ISO_DIR}"; exit 1; }

# 只认规范命名 gig-os-YYYYMMDD.iso（滤掉手塞的垃圾文件名，防其 shadow 排序、占掉 KEEP 名额）
mapfile -t isos < <(ls -1 gig-os-*.iso 2>/dev/null | grep -E '^gig-os-[0-9]{8}\.iso$' | sort -r)
total="${#isos[@]}"
echo "现有 ${total} 个规范 ISO，保留最近 ${KEEP} 个$( [ -n "${KEEPNAME}" ] && echo "（本锅 ${KEEPNAME} 永不删）" )"

if (( total <= KEEP )); then
    echo "无需删除"
    exit 0
fi

i=0
for iso in "${isos[@]}"; do
    i=$((i+1))
    (( i <= KEEP )) && continue
    if [ -n "${KEEPNAME}" ] && [ "${iso}" = "${KEEPNAME}" ]; then
        echo "跳过（本锅，永不删）：${iso}"; continue
    fi
    echo "删除旧版：${iso}（含 .md5/.sha256）"
    rm -f "${iso}" "${iso}.md5" "${iso}.sha256"
done

# 安全兜底：清理后规范 ISO 绝不应归零；若归零必是异常，报错（不静默）。
remain="$(ls -1 gig-os-*.iso 2>/dev/null | grep -cE '^gig-os-[0-9]{8}\.iso$' || true)"
if [ "${remain}" = 0 ]; then
    echo "[错误] 清理后规范 ISO 归零——异常，请人工检查 ${ISO_DIR}"
    exit 1
fi
echo "清理完成，剩余："
ls -1 gig-os-*.iso 2>/dev/null | grep -E '^gig-os-[0-9]{8}\.iso$' || echo "（无）"
