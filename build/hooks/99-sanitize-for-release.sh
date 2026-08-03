#!/bin/bash
# 出厂安全清理：mksquashfs 打包前移除构建机专用调优，使 ISO 对普通用户安全。
# build.sh 在打包前会 source hooks/*；本 hook 由 build-and-deploy.sh 装进 WORK/hooks/，
# 故仅自动构建生效（手动构建没有这些调优、也就不需要清）。
# 为什么必须清：用户机器可能只有 2-4 核 / 4-8G，若把 -j76 / buildpkg / --usepkg 带进 ISO，
# 用户 emerge 会线程超订、binpkg 塞满磁盘、甚至 OOM。

MC="${WORKDIR}/squashfs/etc/portage/make.conf"

# 1. 删掉构建调优 drop-in（zz-buildhost：-j76 / --usepkg / --buildpkg / load=76 等）
rm -f "${MC}/zz-buildhost" "${MC}/zz-loadavg"

# 2. MAKEOPTS 还原为安全兜底值 -j4。
#    不能写成 $(nproc)：portage 的 make.conf 解析器不支持命令替换，会让用户每次 emerge 都报
#    "bad substitution" 且 MAKEOPTS 失效。真正的按 CPU 自适应交给开机的 gigos-cpuflags.service
#    写进 make.conf.d/cpuflags（字母序在 common 之后、覆盖此值）；-j4 只是服务跑起来前的兜底。
if [ -f "${MC}/common" ]; then
    sed -i 's/^MAKEOPTS=.*/MAKEOPTS="-j4"/' "${MC}/common"
fi

# 3. 清除 @world 的 autounmask 在构建期写的 zz-autounmask（USE / keyword pin 等），
#    不让这些构建期解析产物进 ISO 污染用户的 portage 配置。
PRT="$(dirname "${MC}")"
rm -f "${PRT}/package.use/zz-autounmask" "${PRT}/package.accept_keywords/zz-autounmask" \
      "${PRT}/package.mask/zz-autounmask" "${PRT}/package.license/zz-autounmask" 2>/dev/null || true

# 4. 兜底：清除任何残留的 buildpkg 类 FEATURES / usepkg 类 EMERGE_DEFAULT_OPTS
grep -rlE 'buildpkg|--usepkg|--buildpkg|load-average=' "${MC}/" 2>/dev/null \
  | while read -r f; do
        sed -i -E 's/(--usepkg|--buildpkg|--load-average=[0-9]+)//g; s/[[:space:]]+buildpkg//g' "$f"
    done

# 5. 清空 ISO 内的 binpkg/distfiles 缓存（不让几 GB 缓存进 squashfs 撑大体积）。
#    关键：这两个目录是从宿主 bind 挂进来的，必须先 umount -l 解绑再 find -delete，否则 delete
#    会穿透 bind 把宿主的持久缓存整盘删光，导致以后每次构建都全量重编译。解绑后挂载点露出底层
#    空目录，删的是空目录、无害；宿主缓存安然无恙。
for d in binpkgs distfiles; do
    umount -l "${WORKDIR}/squashfs/var/cache/${d}" 2>/dev/null || true
    find "${WORKDIR}/squashfs/var/cache/${d}" -mindepth 1 -delete 2>/dev/null || true
done

# 6. 安全断言：装机后清除 live 残留（自动登录 / SSH 密码登录 / 桌面调试按钮 / polkit 免密）全靠
#    calamares-settings-gig 的 shellprocess 步骤。打包前强校验这套契约确已接通；若 csg fork 指向
#    失败、或装了没有清理逻辑的旧版，就会做出"装好的系统仍残留 live 后门"的盘。任一缺失即中止构建
#    （hook 被 source，exit 1 会终止 build.sh，wrapper 收到非零退出后发 FAILED）。
CSGSP="${WORKDIR}/squashfs/etc/calamares/modules/shellprocess.conf"
CSGSET="${WORKDIR}/squashfs/etc/calamares/settings.conf"
for pat in "kde_settings.conf" "49-calamares-nopasswd.rules" "00-gigos-passwordlogin.conf" \
           "gigos-nosleep.desktop" "gigos-sudo-nopasswd.desktop"; do
    grep -q "${pat}" "${CSGSP}" 2>/dev/null \
        || { echo "[99-sanitize] 致命：calamares 装机清理缺 ${pat} → 装好的系统会残留 live 后门，中止"; exit 1; }
done
grep -qE '^[[:space:]]*-[[:space:]]*shellprocess([[:space:]]|$)' "${CSGSET}" 2>/dev/null \
    || { echo "[99-sanitize] 致命：settings.conf 未启用 - shellprocess 装机清理步骤，中止"; exit 1; }

echo "[99-sanitize] 安全断言通过：装机清理契约已接（自动登录 / SSH 密码登录 / polkit 残留会被 calamares 删除）"
echo "[99-sanitize] 出厂清理完成：MAKEOPTS 已自适应化、构建调优已移除"
