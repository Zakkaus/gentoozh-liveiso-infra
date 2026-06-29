# gentoozh-liveiso-infra

Gentoo 中文社区 Live ISO 的自动构建 / 发布脚本。产物是 KDE Plasma 桌面 Live ISO（`gig-os-YYYYMMDD.iso`），构建机上 systemd timer 每周编一次，传到 Cloudflare R2。

密钥（R2 / Telegram token）都在 `config.env`，不入库。

## 部署

脚本跑在构建机上，机器上不自动 pull。这里是源，改完手动同步过去；在机器上改了也同步回来。

| 仓库内 | 部署到 |
|---|---|
| `build/*.sh` | `/opt/live-iso-builder/` |
| `systemd/*` | `/etc/systemd/system/` |
| `config.env.example` | 复制成 `/opt/live-iso-builder/config.env` 填好 |

步骤：

1. 先看没有构建在跑：`systemctl is-active live-iso-build.service`。构建跑到一半覆盖脚本，在跑的进程会读到半截代码崩掉，白编一锅。
2. 同步脚本，`chmod +x /opt/live-iso-builder/*.sh`。
3. 动过 unit 要 `systemctl daemon-reload`。`.timer` 用 `systemctl enable --now live-iso-build.timer`；`notify-fail` 由 `OnFailure=` 拉起，不用 enable。
4. 填 `config.env`，装好 `rclone`。R2 字段缺了，编译前预检会直接停。

## config.env

```sh
cp config.env.example /opt/live-iso-builder/config.env
vim /opt/live-iso-builder/config.env
chmod 600 /opt/live-iso-builder/config.env
```

字段见 `config.env.example`。R2 token 在 Cloudflare → R2 → Manage API Tokens 建，给 Object Read & Write、限定该 bucket。

## 流程

`live-iso-build.timer` 每周触发 `build-and-deploy.sh`：

1. 拉 [Live-ISO](https://github.com/Gentoo-zh/Live-ISO) 的 KDE 分支，记下 commit。
2. 预检：R2 可达、overlay 可达、内存够挂 tmpfs；缺料就停。
3. 挂 tmpfs，在内存里 `build.sh` 全量编，binpkg / distfiles 缓存落 SSD 复用。
4. `verify-iso.sh` 挂 squashfs 抽查关键项：calamares 版本、装机清理、grub、nvidia、有没有混进密钥…不过就拦下不上线。
5. `rclone` 传到 R2，按 `R2_KEEP` 留最近几版。
6. 核对：从 R2 公开域名取回本锅文件逐字节对账，再看落地页有没有列出它。

`reupload-iso.sh`：R2 传挂了用它手动重传，不重编，以 `BUILD_MANIFEST` 为准，sha 对不上不传。

## 通知

开始 / 成功 / 失败都推到 Telegram [@gentoomirror](https://t.me/gentoomirror)，填 `config.env` 的 `TG_TOKEN` / `TG_CHAT` 即开，留空就静默。脚本里 `on_exit` 兜底报失败；脚本根本没起来时由 `live-iso-notify-fail.service` 报。

## 手动

```sh
sudo systemctl start live-iso-build.service     # 手动编一次
journalctl -u live-iso-build.service -f         # 看进度
tail -f /opt/live-iso-builder/logs/build-*.log  # 日志
sudo /opt/live-iso-builder/reupload-iso.sh      # 重传已验证的 ISO，不重编
```

## 密钥

`config.env` 不入库，权限 `600`。脚本里没有真凭据，`config.env.example` 全是占位。提交前 `git grep` 一下，别混进 token。

## 许可

[MIT](LICENSE) © Gentoo 中文社区。

## 相关仓库

- [Gentoo-zh/Live-ISO](https://github.com/Gentoo-zh/Live-ISO)（KDE 分支）— 构建脚本与定制
- [Gentoo-zh/calamares-settings-gig](https://github.com/Gentoo-zh/calamares-settings-gig) — 图形安装器配置
- [Gig-OS/gig](https://github.com/Gig-OS/gig) — 构建用 overlay
- [Zakkaus/gentoozh-mirror](https://github.com/Zakkaus/gentoozh-mirror) — 下载站落地页源
