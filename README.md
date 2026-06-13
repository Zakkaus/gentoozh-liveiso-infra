# gentoozh-liveiso-infra

Gentoo 中文社区 Live ISO 的自动构建 / 发布脚本(开源,MIT 许可)。脚本本身不含任何密钥——Cloudflare R2 token / Telegram token 全在 `config.env`(已被 `.gitignore` 排除、绝不入库),见下。

构建产物是 KDE Plasma 桌面 Live ISO(`gig-os-YYYYMMDD.iso`),每周由 systemd timer 自动编译,编好后上传到 **Cloudflare R2**(零出口流量),保留最近几版;落地页 **mirror.gentoozh.org** 是一个 Cloudflare Worker,在边缘即时读 R2、永远反映当前内容(源在另一个仓库,见文末)。构建用的镜像源也在另一个仓库,见文末。

## 目录与部署位置

机器上没有自动 pull;这里是源,改完要同步到构建机(也同步回这里)。所有脚本都跑在**构建机**上。

| 仓库内 | 部署到 |
|---|---|
| `build/build-and-deploy.sh` | `/opt/live-iso-builder/` |
| `build/verify-iso.sh` | `/opt/live-iso-builder/` |
| `build/reupload-iso.sh` | `/opt/live-iso-builder/` |
| `systemd/live-iso-build.service` `.timer` | `/etc/systemd/system/` |
| `systemd/live-iso-notify-fail.service` | `/etc/systemd/system/` |
| `config.env.example` | 复制为 `/opt/live-iso-builder/config.env` 并填写 |

### 部署步骤(顺序要紧)

1. **务必等当前没有构建在跑**再部署:`build-and-deploy.sh` 被 bash 增量读取,在构建进行中覆盖它会让在跑的进程读到半截新代码而崩(又一锅白跑)。先 `systemctl is-active live-iso-build.service` 确认非 activating/active。
2. 同步脚本到上表位置,保持可执行:`chmod +x /opt/live-iso-builder/*.sh`。
3. 改过 systemd unit 后必须 `sudo systemctl daemon-reload`;`live-iso-notify-fail.service` 由 `OnFailure=` 按需拉起、**无需 enable**;`.timer` 仍需 `systemctl enable --now live-iso-build.timer`。
4. 在 `config.env` 填好 `R2_*`(见 `config.env.example`)。缺任一项,编译前预检 `preflight_r2()` 会直接失败(不烧几小时)。构建机需装 `rclone`。
5. 部署后过一遍语法:`bash -n /opt/live-iso-builder/{build-and-deploy,verify-iso,reupload-iso}.sh`(service 的 `ExecStartPre` 也会在每次启动前自动做这件事)。

## 配置(密钥)

所有敏感信息(Cloudflare R2 token、Telegram token)都在 **`config.env`**,**不入库**(`.gitignore` 已排除)。脚本运行时 `source` 它。

```sh
cp config.env.example /opt/live-iso-builder/config.env
vim /opt/live-iso-builder/config.env      # 填真实值
chmod 600 /opt/live-iso-builder/config.env
```

字段说明见 `config.env.example`。R2 token 在 Cloudflare → R2 → Manage API Tokens 建,选 **Object Read & Write、限定该 bucket**。

## 流程

`live-iso-build.timer`(每周一次)触发 `build-and-deploy.sh`:

1. 拉取 Live-ISO 构建仓库(KDE 分支),记下本锅 commit;源非 origin 最新会发 WARN。
2. **编译前预检**(几秒):R2 配置齐全且 bucket 可达、gig/settings-gig fork 可达、内存够挂 tmpfs。缺料即 abort+通知,绝不白烧几小时。
3. 挂 tmpfs,在内存里 `build.sh` 全量构建(吃满核;binpkg/distfiles 缓存落 SSD、跨构建复用)。
4. `verify-iso.sh` 挂载 squashfs 实检关键项(calamares 版本、shellprocess 装机清理契约、grub 无 early-KMS、nvidia 加载、无 plasma-localerc、无密钥泄漏…),关键项缺失则拦截、不上线。
5. 校验通过后把 ISO + `BUILD_MANIFEST`(commit/sha 身份证)原子暂存到 SSD,再 `rclone` 上传到 **R2**(上传失败=整锅失败,但 ISO 已暂存,跑 `reupload-iso.sh` 可重传不必重编),按 `R2_KEEP` 删旧版(本锅永不删)。
6. **端到端核对**:curl R2 公开域名(`r2.gentoozh.org`)取本锅 `content-length` 与本地逐字节对账,不符即 fail+通知;再确认落地页 `mirror.gentoozh.org`(Worker 即时读 R2)已列出本锅文件名(边缘缓存延迟时 WARN、不阻断)。这一步根治"编译了没更新/上了旧盘"。

`reupload-iso.sh`(R2 上传抽风时手动重传,不重编)以 `BUILD_MANIFEST` 为权威:无 manifest / sha 不符 / 陈旧一律拒传,杜绝盲传旧盘;重传走的也是同一套 R2 上传 + 公开域核对 + 落地页核对。

## 通知

构建**开始 / 成功 / 失败**自动推送到 Telegram 频道 **<https://t.me/gentoomirror>**(成功/失败附用时与时间)。配置 `config.env` 的 `TG_TOKEN` / `TG_CHAT` 即启用,留空则静默。

**任何异常都不会静默**:R2 上传失败、对外核对不一致、运行期语法错、被 kill(systemd 超时 / Ctrl-C / 挂断)、未到终点的退出,都由 `on_exit` 兜底发 FAILED;连 wrapper 都没起来(语法体检不过 / config 缺)则由 `live-iso-notify-fail.service`(`OnFailure=`)兜底。`reupload-iso.sh` 同样会通知。`service` 的 `ExecStartPre` 在每次启动前对脚本做 `bash -n` 语法体检,语法错绝不进入几小时构建。

## 手动操作

```sh
sudo systemctl start live-iso-build.service     # 手动触发一次
journalctl -u live-iso-build.service -f         # 看进度
tail -f /opt/live-iso-builder/logs/build-*.log  # 详细日志
sudo /opt/live-iso-builder/reupload-iso.sh      # 不重编,把暂存的已验证 ISO 重传到 R2
```

## 安全

- 所有密钥(Cloudflare R2 token、Telegram token)只在 `config.env`,**绝不入库**(`.gitignore` 已排除)。仓库内任何脚本都不含真实凭据;`config.env.example` 全是占位值。
- 提交前请确认无密钥混入:`git grep -nE '私钥|PRIVATE KEY|cloudflarestorage|[0-9]{6}:[A-Za-z0-9_-]{30}'` 应无真实命中。
- 自托管者:把 `config.env` 权限设 `600`、仅 root 可读;R2 token 用 **Object Read & Write、限定单个 bucket** 的最小权限 token。

## 许可

[MIT](LICENSE) © Gentoo 中文社区(gentoozh)。

## 相关仓库

- [Gentoo-zh/Live-ISO](https://github.com/Gentoo-zh/Live-ISO)(KDE 分支)—— 构建脚本与定制
- [Gentoo-zh/calamares-settings-gig](https://github.com/Gentoo-zh/calamares-settings-gig) —— 图形安装器配置
- [Gentoo-zh/gig](https://github.com/Gentoo-zh/gig) —— 构建用的 overlay(锁版本)
- [Zakkaus/gentoozh-mirror](https://github.com/Zakkaus/gentoozh-mirror) —— 下载站落地页(Cloudflare Worker)源
