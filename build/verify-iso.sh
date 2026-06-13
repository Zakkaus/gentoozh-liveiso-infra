#!/bin/bash
# ISO 完整性验证:构建出 ISO 后,挂载 squashfs 实际检查所有改动是否真进了镜像。
# 在构建机上 root 运行。验证的是"产物"而非"源码",确认 build.sh 真把改动打进去了。
#
# 用法: verify-iso.sh [ISO路径]   不给则自动在构建目录里找最新的 gig-os-*.iso
# 退出码: 0=全通过  1=仅有警告(可上线)  2=有【关键项】缺失(必须拦截,禁止上线)
set -uo pipefail

# ISO 优先取参数;否则在 tmpfs 构建目录 / 持久目录里找最新的
ISO="${1:-}"
if [ -z "${ISO}" ]; then
  for d in /mnt/isobuild/Live-ISO /opt/live-iso-builder/Live-ISO; do
    c="$(ls -1t "${d}"/gig-os-*.iso 2>/dev/null | head -1)"
    [ -n "${c}" ] && { ISO="${c}"; break; }
  done
fi
PASS=0; WARN=0; CRIT=0
ok(){   echo "  [OK] $*"; PASS=$((PASS+1)); }
no(){   echo "  [警告] $*"; WARN=$((WARN+1)); }       # 警告:不拦上线
bad(){  echo "  [错误] $* 【关键】"; CRIT=$((CRIT+1)); } # 关键:拦截上线

echo "===== ISO 完整性验证 ====="
[ -n "${ISO}" ] && [ -f "${ISO}" ] || { echo "[错误] 没找到 gig-os-*.iso(构建可能没完成)"; exit 2; }
echo "ISO: ${ISO} ($(du -h "${ISO}"|cut -f1))"

# 挂 ISO → 取 squashfs → 挂 squashfs
M_ISO=$(mktemp -d); M_SQ=$(mktemp -d)
cleanup(){ umount "${M_SQ}" 2>/dev/null; umount "${M_ISO}" 2>/dev/null; rmdir "${M_SQ}" "${M_ISO}" 2>/dev/null; }
trap cleanup EXIT
mount -o loop,ro "${ISO}" "${M_ISO}" 2>/dev/null || { echo "[错误] 挂 ISO 失败"; exit 2; }
SQ="${M_ISO}/LiveOS/squashfs.img"
[ -f "${SQ}" ] || SQ=$(find "${M_ISO}" -name 'squashfs.img' -o -name '*.squashfs' 2>/dev/null | head -1)
mount -o loop,ro "${SQ}" "${M_SQ}" 2>/dev/null || { echo "[错误] 挂 squashfs 失败"; exit 2; }
R="${M_SQ}"

echo
echo "--- 0. Calamares 图形安装器本体(关键!没它 ISO 装不了机)---"
{ [ -x "${R}/usr/bin/calamares" ] || [ -x "${R}/usr/sbin/calamares" ]; } && ok "calamares 安装器本体已装" || bad "calamares 安装器缺失(@world 漏装,补装 patch 没生效)"
[ -f "${R}/etc/calamares/settings.conf" ] && ok "calamares-settings-gig 配置已装" || bad "calamares-settings-gig 配置缺(无安装流程定义)"
ls "${R}"/usr/share/applications/*[Cc]alamares*.desktop >/dev/null 2>&1 && ok "calamares 桌面启动项在" || no "calamares .desktop 缺(桌面可能没图标,命令行仍可启)"

echo
echo "--- 0b. Calamares 版本锁定(必须 3.3.14-r8,fork 对齐的唯一好版本)---"
# 旧门控只查 calamares 本体在不在,没查版本——上游滚动树升级会改 settings/shellprocess schema,
# 与我们 fork 配置失配。查 vdb 实测产物版本。【升级 calamares 时记得同步改这里的版本号】。
CALV="$(ls -1d "${R}"/var/db/pkg/app-admin/calamares-* 2>/dev/null | grep -v settings | xargs -r -n1 basename)"
echo "${CALV}" | grep -qx 'calamares-3.3.14-r8' && ok "calamares 版本=3.3.14-r8(vdb 实测)" \
    || bad "calamares 版本非 3.3.14-r8(vdb 实测=[${CALV:-缺}]),settings/shellprocess schema 可能失配"

echo
echo "--- 0c. shellprocess 装机清理契约(缺=安装后门,关键)---"
# 装机后清 live 残留(autologin / SSH 密码登录 / 桌面调试按钮 / polkit 免密)全靠 settings.conf 启用
# - shellprocess + shellprocess*.conf 的清理项。缺任一 = 装好的系统残留 live 后门。这正是事故盘形态。
SET="${R}/etc/calamares/settings.conf"
SHP="$(ls -1 "${R}"/etc/calamares/modules/shellprocess*.conf 2>/dev/null | head -1)"
if [ -f "${SET}" ] && grep -qE '^[[:space:]]*-[[:space:]]*shellprocess([[:space:]]|$)' "${SET}"; then
    ok "settings.conf 已在 exec 启用 - shellprocess"
else
    bad "settings.conf 未启用 - shellprocess(装机清理整段不跑=后门)"
fi
if [ -n "${SHP}" ] && [ -f "${SHP}" ]; then
    miss=""
    for f in kde_settings.conf 49-calamares-nopasswd.rules 00-gigos-passwordlogin.conf; do
        grep -qF "${f}" "${SHP}" || miss="${miss} ${f}"
    done
    [ -z "${miss}" ] && ok "shellprocess.conf 含三件清理(kde_settings/49-nopasswd/00-passwordlogin)" \
                     || bad "shellprocess.conf 缺清理项:${miss}(装机后留 live 免密=后门)"
else
    bad "shellprocess.conf 缺失(装机清理契约无定义=后门)"
fi

echo
echo "--- 1. 中文输入法(rime,无 chinese-addons)---"
[ -d "${R}/usr/share/rime-data" ] && ok "rime-data 已装" || bad "rime-data 缺失"
ls "${R}"/usr/lib*/fcitx5/*rime* >/dev/null 2>&1 && ok "fcitx5-rime 引擎已装" || bad "fcitx5-rime 引擎缺"
[ -f "${R}/etc/skel/.config/fcitx5/profile" ] && grep -q 'rime' "${R}/etc/skel/.config/fcitx5/profile" && ok "skel fcitx5 profile 启用 rime" || no "skel fcitx5 profile 缺/无 rime"
[ -f "${R}/etc/skel/.local/share/fcitx5/rime/default.custom.yaml" ] && ok "skel rime 方案预置" || no "skel rime 方案缺"
ls "${R}"/usr/lib*/fcitx5/*chinese-addon* >/dev/null 2>&1 && no "chinese-addons 仍在(应删)" || ok "chinese-addons 已删"

echo
echo "--- 2. 中文字体 ---"
find "${R}/usr/share/fonts" -iname '*notosanscjk*' -o -iname '*notoserifcjk*' 2>/dev/null | grep -q . && ok "noto-cjk 字体已装" || bad "noto-cjk 字体缺(会豆腐块)"

echo
echo "--- 3. locale 地板(服务不跑也中文)---"
[ -f "${R}/etc/locale.conf" ] && grep -q 'zh_CN' "${R}/etc/locale.conf" && ok "/etc/locale.conf=zh_CN 地板" || bad "locale.conf 地板缺"
grep -q 'zh_CN\|zh_TW' "${R}/etc/locale.gen" 2>/dev/null && ok "locale.gen 含 zh_CN/zh_TW" || no "locale.gen 缺中文"

echo
echo "--- 4. 开机选语言服务 ---"
[ -f "${R}/usr/local/bin/gigos-live-lang.sh" ] && [ -x "${R}/usr/local/bin/gigos-live-lang.sh" ] && ok "gigos-live-lang.sh 在且可执行" || no "语言脚本缺/不可执行"
[ -f "${R}/etc/systemd/system/gigos-live-lang.service" ] && ok "语言服务 unit 在" || no "语言服务 unit 缺"
ls "${R}"/etc/systemd/system/*.wants/gigos-live-lang.service >/dev/null 2>&1 && ok "语言服务已 enable" || no "语言服务没 enable(开机不跑)"

echo
echo "--- 5. 显卡双驱动 + nouveau 黑名单解除 ---"
{ ls "${R}"/usr/lib*/xorg/modules/drivers/nvidia* >/dev/null 2>&1 || ls "${R}"/opt/bin/nvidia* >/dev/null 2>&1 || find "${R}/lib/modules" -name 'nvidia*.ko*' 2>/dev/null|grep -q .; } && ok "nvidia 驱动已装" || no "nvidia 驱动缺(仅 nouveau 可用)"
if [ -f "${R}/etc/modprobe.d/nvidia.conf" ]; then
  grep -q '^#blacklist nouveau' "${R}/etc/modprobe.d/nvidia.conf" && ok "nvidia.conf 的 blacklist nouveau 已注释(双驱动可共存)" \
    || { grep -q '^blacklist nouveau' "${R}/etc/modprobe.d/nvidia.conf" && bad "nvidia.conf 仍 blacklist nouveau(nouveau起不来!)" || ok "nvidia.conf 无激活的 nouveau 黑名单"; }
else echo "  ? 无 nvidia.conf(nvidia 可能没装成,仅 nouveau)"; fi
# gigos-nvidia-load.service:early-KMS 的安全替代——不进 initramfs,系统起来后按 gigos.gpu 选项加载 nvidia
[ -f "${R}/etc/systemd/system/gigos-nvidia-load.service" ] && ok "gigos-nvidia-load.service 在(运行时加载 nvidia,非 early-KMS)" || bad "gigos-nvidia-load.service 缺(nvidia 无安全加载路径)"
ls "${R}"/etc/systemd/system/*.wants/gigos-nvidia-load.service >/dev/null 2>&1 && ok "gigos-nvidia-load.service 已 enable" || bad "gigos-nvidia-load.service 没 enable(开机不加载 nvidia)"

# early KMS(nvidia 模块+GSP 固件进 initramfs)已由 build.sh buildbootfiles 在 chroot 内用
# lsinitrd 实查门控(dracut 刚完、tmpfs 未满时读取可靠);此处 host-lsinitrd 在构建末期 tmpfs
# 满时会读残缺误报,故不再重复检查。

echo
echo "--- 6. 出厂安全清理生效(发给用户的配置)---"
MC="${R}/etc/portage/make.conf"
# MAKEOPTS:出厂 common 必须是安全小字面量——不泄漏构建机 -j76(会让小机 OOM),也【不能】写
# $(nproc)(portage 的 make.conf 解析器不支持命令替换,会每次 emerge 报 bad substitution + MAKEOPTS 失效)。
# 真正按本机核数自适应由开机的 gigos-cpuflags.service 写 make.conf.d/cpuflags 的 MAKEOPTS=-jN 覆盖。
MKLINE="$(grep -rhE '^MAKEOPTS=' "${MC}/" 2>/dev/null | head -1)"
MKJOBS="$(printf '%s' "${MKLINE}" | grep -oE -- '-j[0-9]+' | grep -oE '[0-9]+' | head -1)"
if printf '%s' "${MKLINE}" | grep -q 'nproc'; then
  bad "MAKEOPTS 写了 \$(nproc)(portage 不支持命令替换,会 bad substitution 且 MAKEOPTS 失效)"
elif [ -z "${MKJOBS}" ] || [ "${MKJOBS}" -gt 8 ]; then
  bad "MAKEOPTS 未还原为安全小值(实测 [${MKLINE:-缺}],疑似泄漏构建机 -j76,用户机 OOM)"
elif grep -q 'MAKEOPTS' "${R}/usr/local/bin/gigos-cpuflags.sh" 2>/dev/null; then
  ok "MAKEOPTS 出厂安全字面量(${MKLINE}),开机 gigos-cpuflags 按本机核数写 cpuflags 覆盖"
else
  bad "MAKEOPTS 出厂安全但缺开机自适应(gigos-cpuflags.sh 未写 MAKEOPTS,装好系统并行度不会按机调整)"
fi
if grep -rqE '^CPU_FLAGS_X86=' "${MC}/" 2>/dev/null; then
  grep -rq 'gigos-auto-cpuflags' "${MC}/" 2>/dev/null && ok "CPU_FLAGS_X86 为出厂安全基线(带 gigos-auto-cpuflags 标记,开机按本机 cpuid2cpuflags 覆盖)" || no "CPU_FLAGS_X86 有固定值但无 gigos-auto-cpuflags 标记(疑似构建机泄漏)"
else ok "CPU_FLAGS_X86 已清(改 cpuid2cpuflags 生成)"; fi
grep -rq 'aliyun' "${MC}/mirror" 2>/dev/null && ok "GENTOO_MIRRORS=阿里云" || echo "  ? mirror 非阿里云"
grep -rqE 'buildpkg|--usepkg' "${MC}/" 2>/dev/null && bad "构建调优泄漏(buildpkg/usepkg,用户 emerge 会塞满盘)" || ok "无构建调优泄漏"
ls "${R}"/var/cache/binpkgs/* >/dev/null 2>&1 && bad "binpkg 残留进 ISO(体积暴涨)" || ok "binpkg 未进 ISO"

echo
echo "--- 7. Calamares 装机刚需工具 ---"
{ [ -x "${R}/sbin/mkfs.xfs" ] || [ -x "${R}/usr/sbin/mkfs.xfs" ]; } && ok "xfsprogs" || no "xfsprogs 缺(Calamares 格式化 xfs 灰掉)"
{ [ -x "${R}/sbin/cryptsetup" ] || [ -x "${R}/usr/sbin/cryptsetup" ]; } && ok "cryptsetup" || no "cryptsetup 缺(加密安装失败)"
ls "${R}"/usr/bin/gparted >/dev/null 2>&1 && ok "gparted" || no "gparted 缺"
[ -x "${R}/usr/bin/cpuid2cpuflags" ] && ok "cpuid2cpuflags(配合出厂CPU_FLAGS清理)" || no "cpuid2cpuflags 缺"

echo
echo "--- 8. live 用户 + sddm autologin(live 会话需免密自动登录)---"
grep -q '^live:' "${R}/etc/passwd" 2>/dev/null && ok "live 用户已建" || bad "live 用户缺(开机无人登录)"
grep -q 'User=live' "${R}/etc/sddm.conf.d/kde_settings.conf" 2>/dev/null && ok "sddm autologin=live" || no "sddm autologin 未配(需手动登录)"

echo
echo "--- 8b. 无硬编码 plasma-localerc(语言应由运行时 gigos-live-lang 决定)---"
# 硬编码这个文件会把某固定 locale 写死进每个新用户 home,覆盖开机选语言。存在即异常(非致命,归警告)。
[ -e "${R}/etc/skel/.config/plasma-localerc" ] && no "skel 含硬编码 plasma-localerc(会锁死语言,覆盖开机选语言)" || ok "skel 无硬编码 plasma-localerc(语言由运行时决定)"

echo
echo "--- 8c. SSH 桌面按钮三语 + 无 ssh-nopasswd 免密规则 ---"
# SSH 桌面按钮(三语).desktop 在 etc/skel/Desktop/;polkit 49-gigos-ssh-nopasswd.rules 必须【不存在】
# (存在=SSH 操作免密提权后门,随装机泄漏)。前者缺只警告,后者存在归关键拦截。
SSHDT="$(ls "${R}"/etc/skel/Desktop/*ssh*.desktop 2>/dev/null | head -1)"
if [ -n "${SSHDT}" ] && grep -q 'Name\[zh_CN\]' "${SSHDT}" 2>/dev/null && grep -q 'Name\[zh_TW\]' "${SSHDT}" 2>/dev/null; then
    ok "SSH 桌面按钮三语(zh_CN/zh_TW/en)在"
else
    no "SSH 桌面按钮缺/非三语(.desktop=${SSHDT:-缺})"
fi
if find "${R}/etc" "${R}/usr/share/polkit-1" -name '49-gigos-ssh-nopasswd.rules' 2>/dev/null | grep -q .; then
    bad "存在 49-gigos-ssh-nopasswd.rules(SSH 免密提权后门,装机会泄漏)"
else
    ok "无 49-gigos-ssh-nopasswd.rules(SSH 不免密提权)"
fi

echo
echo "--- 9. grub 菜单(语言/驱动项)---"
GRUB="${M_ISO}/boot/grub/grub.cfg"
[ -f "${GRUB}" ] || GRUB=$(find "${M_ISO}" -name grub.cfg 2>/dev/null|head -1)
if [ -f "${GRUB}" ]; then
  n=$(grep -cE '^menuentry|menuentry ' "${GRUB}" 2>/dev/null)
  grep -q 'gigos.lang=zh_TW' "${GRUB}" && ok "grub 有繁体项(gigos.lang=zh_TW)" || no "grub 无繁体项"
  grep -qE 'module_blacklist=nouveau|modprobe.blacklist=nouveau' "${GRUB}" && ok "grub 有闭源 nvidia 项" || no "grub 无 nvidia 项"
  grep -q 'gigos.gpu=nvidia' "${GRUB}" && ok "grub 内核行含 gigos.gpu=nvidia(运行时配 nvidia)" || no "grub 无 gigos.gpu=nvidia 项"
  # early-KMS 反向门控:rd.driver.pre=nvidia 把 nvidia 塞 initramfs 早加载,不兼容机一开机就黑屏炸显卡(事故症状)
  if grep -qE 'rd\.driver\.pre=nvidia' "${GRUB}"; then
    bad "grub 含 early-KMS rd.driver.pre=nvidia(initramfs 早加载 nvidia,不兼容机黑屏炸显卡)"
  else
    ok "grub 无 early-KMS rd.driver.pre=nvidia(不会在 initramfs 早期炸显卡)"
  fi
  echo "  grub 菜单项数: ${n}"
else echo "  ? 没找到 grub.cfg(可能在 EFI 镜像内)"; fi

echo
echo "--- 10. ISO 内无密钥/拓扑泄漏(关键安全)---"
# 红线:本脚本入库,绝不写死 token/IP。从 config.env(600 root,本机才有)读取要扫的敏感串。
# 非 root 跑(读不到 config.env)时,token/IP 扫描自动跳过,但 config.env 文件与私钥扫描仍生效。
LEAK=0
CFG="${CONFIG_ENV:-/opt/live-iso-builder/config.env}"
# shellcheck disable=SC1090
[ -f "${CFG}" ] && . "${CFG}" 2>/dev/null
SCAN_DIRS="${R}/etc ${R}/root ${R}/home ${R}/usr/local ${R}/opt"
for pat in "${TG_TOKEN:-}" "${R2_ACCESS_KEY_ID:-}" "${R2_SECRET_ACCESS_KEY:-}"; do
  [ -n "${pat}" ] || continue
  hit="$(grep -rlIF "${pat}" ${SCAN_DIRS} 2>/dev/null | head -3)"
  [ -n "${hit}" ] && { bad "ISO 内含敏感串(config.env 的 Telegram/R2 凭据)于:${hit}"; LEAK=1; }
done
find "${R}/etc" "${R}/root" "${R}/home" "${R}/opt" -name 'config.env' 2>/dev/null | grep -q . && { bad "ISO 内含 config.env(运维密钥全集)"; LEAK=1; }
if grep -rlE 'BEGIN (OPENSSH|RSA|EC|DSA)? ?PRIVATE KEY' "${R}/root/.ssh" "${R}/etc/skel" "${R}/home" 2>/dev/null | grep -q .; then
  bad "ISO 内含 SSH/PEM 私钥(构建机/运维凭据泄漏)"; LEAK=1
fi
[ "${LEAK}" = 0 ] && ok "ISO 内未发现 Telegram/R2 凭据/config.env/私钥"

echo
echo "===== 验证结果:通过 ${PASS} / 警告 ${WARN} / 关键失败 ${CRIT} ====="
if [ "${CRIT}" -gt 0 ]; then echo "[错误] 有 ${CRIT} 项【关键】缺失 → 拦截,禁止上线"; exit 2
elif [ "${WARN}" -gt 0 ]; then echo "[警告] 有 ${WARN} 项警告(非致命),允许上线"; exit 1
else echo "[OK] ISO 完整性全通过"; exit 0; fi
