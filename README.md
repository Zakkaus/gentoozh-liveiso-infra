# gentoozh-liveiso-infra

[简体中文](README.md) · [正體中文](README.zh-TW.md) · [English](README.en.md)

Gentoo 中文社区 Live ISO 的自动构建与发布脚本。产物是 KDE Plasma 桌面 Live ISO（`gig-os-YYYYMMDD.iso`），由构建机上的 systemd timer 每周编一次，验证通过后传到 Cloudflare R2。

本仓库只做编排。构建本身在 [Gig-OS/Live-ISO](https://github.com/Gig-OS/Live-ISO) 的 `KDE` 分支，包括防并发锁、overlay、`@world` 与出厂内容。

## 部署

脚本运行在构建机上，机器不自动拉取。**本仓库是源，改完手动同步过去；在机器上改了也要同步回来**，否则两边会漂移。

| 仓库内 | 部署到 |
|---|---|
| `build/*.sh` | `/opt/live-iso-builder/` |
| `systemd/*` | `/etc/systemd/system/` |
| `config.env.example` | 复制成 `/opt/live-iso-builder/config.env` 并填写 |

出厂清理的闸门脚本 `99-sanitize-for-release.sh` **不在本仓库**，它在 [Live-ISO](https://github.com/Gig-OS/Live-ISO) 的 `hooks/` 里，由 `build.sh` 直接 source。改闸门要改那边。

步骤：

1. 确认没有构建在执行：`systemctl is-active live-iso-build.service`。构建期间覆盖脚本会让执行中的进程读到半截代码，整锅作废。
2. 同步脚本，`chmod +x /opt/live-iso-builder/*.sh`。
3. 改过 unit 要 `systemctl daemon-reload`。timer 用 `systemctl enable --now live-iso-build.timer`；`live-iso-notify-fail.service` 由 `OnFailure=` 拉起，不必 enable。
4. 填 `config.env`，安装 `rclone`。R2 字段缺失时预检直接停，不会先编几小时。

## config.env

```sh
cp config.env.example /opt/live-iso-builder/config.env
vim /opt/live-iso-builder/config.env
chmod 600 /opt/live-iso-builder/config.env
```

字段说明见 `config.env.example`。R2 token 在 Cloudflare 的 R2 → Manage API Tokens 创建，授予 Object Read & Write 并限定到该 bucket。

## 流程

`live-iso-build.timer` 每周二 06:00（Asia/Shanghai，即 UTC 周一 22:00）触发 `build-and-deploy.sh`：

1. 拉取 `Gig-OS/Live-ISO` 的 `KDE` 分支，记下 commit。
2. 预检：仓库可达、overlay 可达、R2 可列。缺料即停。
3. 构建。**默认落磁盘**；`USE_TMPFS=1` 才挂 tmpfs 在内存里编。这是共享机，其他人的编译同样需要内存。binpkg 与 distfiles 缓存落 SSD 跨锅复用。
4. `verify-iso.sh` 挂载 squashfs 抽查关键项：calamares、装机清理、grub、显卡驱动、有无混入密钥。不通过即拦下。
5. 上传到镜像站 `distfiles.gentoozh.org/gigos/`，按 `MIRROR_KEEP` 保留最近几版，以对外状态码与 content-length 核对。`r2.gentoozh.org` 已 301 到这里，因此这是唯一的公开路径，失败即失败。未配 `MIRROR_SSH_TARGET` 时整段跳过。
6. `rclone` 上传到 R2 作异地备份，按 `R2_KEEP` 保留最近几版。核对直接问 bucket，因为公开域名跟随跳转量到的是镜像站那一份。
7. 看落地页是否已列出本锅。落地页是 Worker 读 R2 的列表视图，有缓存滞后，不作权威。

`reupload-iso.sh` 用于 R2 上传失败后手动重传，不重编，以 `BUILD_MANIFEST` 为准，校验和不符即拒绝。

## 通知

开始、成功、失败都推送到 Telegram [@gentoomirror](https://t.me/gentoomirror)，填好 `config.env` 的 `TG_TOKEN` 与 `TG_CHAT` 即生效，留空则静默。脚本的 `on_exit` 兜底报失败；脚本没能启动时由 `live-iso-notify-fail.service` 报。

## 手动操作

```sh
sudo systemctl start live-iso-build.service          # 手动编一次
sudo USE_TMPFS=1 systemctl start live-iso-build      # 改用内存构建
journalctl -u live-iso-build.service -f              # 看进度
tail -f /opt/live-iso-builder/logs/build-*.log       # 日志
sudo /opt/live-iso-builder/reupload-iso.sh           # 重传已验证的 ISO,不重编
```

`live-iso-build.service` 是 `Type=oneshot`，整个构建期间 `systemctl is-active` 都显示 `activating`，判断是否完成要看日志。被发布闸门拦下时，用 `grep -nE '关键：|关键失败|拒绝上线' <日志>` 定位具体条目。

## 密钥

`config.env` 不入库，权限 `600`。脚本内没有真实凭据，`config.env.example` 全是占位值。提交前用 `git grep` 确认没有混入 token。

## 许可

[MIT](LICENSE) © Gentoo 中文社区。

## 相关仓库

- [Gig-OS/Live-ISO](https://github.com/Gig-OS/Live-ISO)（`KDE` 分支）：构建脚本与定制
- [Gig-OS/calamares-settings-gig](https://github.com/Gig-OS/calamares-settings-gig)：图形安装器配置
- [Gig-OS/gigos-mirror](https://github.com/Gig-OS/gigos-mirror)：下载站 iso.gentoozh.org
