# gentoozh-liveiso-infra

Gentoo 中文社区 Live ISO 的自动构建 / 部署 / 下载站渲染脚本(开源,MIT 许可)。脚本本身不含任何密钥——部署目标 IP / 端口 / SSH key 路径 / Telegram token 全在 `config.env`(已被 `.gitignore` 排除、绝不入库),见下。

构建产物是 KDE Plasma 桌面 Live ISO(`gig-os-YYYYMMDD.iso`),每周由 systemd timer 自动编译、上传到下载站 mirror.gentoozh.org、保留最近几版。构建用的镜像源在另一个仓库,见文末。

## 目录与部署位置

机器上没有自动 pull;这里是源,改完要同步到对应机器(也同步回这里)。

| 仓库内 | 部署到 | 机器 |
|---|---|---|
| `build/build-and-deploy.sh` | `/opt/live-iso-builder/` | 构建机 |
| `build/verify-iso.sh` | `/opt/live-iso-builder/` | 构建机 |
| `build/cleanup-old-iso.sh` | `/opt/live-iso-builder/` 与下载站 `/usr/local/bin/` | 两边同一份 |
| `build/reupload-iso.sh` | `/opt/live-iso-builder/` | 构建机 |
| `systemd/live-iso-build.service` `.timer` | `/etc/systemd/system/` | 构建机 |
| `systemd/live-iso-notify-fail.service` | `/etc/systemd/system/` | 构建机 |
| `mirror/render-index.sh` | `/usr/local/bin/` | 下载站 |
| `config.env.example` | 复制为 `/opt/live-iso-builder/config.env` 并填写 | 构建机 |

### 部署步骤(顺序要紧)

1. **务必等当前没有构建在跑**再部署:`build-and-deploy.sh` 被 bash 增量读取,在构建进行中覆盖它会让在跑的进程读到半截新代码而崩(又一锅白跑)。先 `systemctl is-active live-iso-build.service` 确认非 activating/active。
2. 同步脚本到上表位置,保持可执行:`chmod +x /opt/live-iso-builder/*.sh`(构建机)、`chmod +x /usr/local/bin/{render-index,cleanup-old-iso}.sh`(下载站)。`cleanup-old-iso.sh` 两边各一份,别只更新一边。
3. 改过 systemd unit 后必须 `sudo systemctl daemon-reload`;`live-iso-notify-fail.service` 由 `OnFailure=` 按需拉起、**无需 enable**;`.timer` 仍需 `systemctl enable --now live-iso-build.timer`。
4. **首次部署后在 `config.env` 补 `M_URLBASE` / `M_PAGEURL`**(见 `config.env.example`),否则端到端"站上=本锅"核对会被静默跳过(只发 WARN、不拦上线)。补好后用一次真实上线验证 `curl ${M_URLBASE}/<iso>.sha256` 取得到。
5. 部署后过一遍语法:`bash -n /opt/live-iso-builder/{build-and-deploy,verify-iso,reupload-iso}.sh`(service 的 `ExecStartPre` 也会在每次启动前自动做这件事)。

## 配置(密钥)

所有敏感信息(下载站 IP/端口/SSH key 路径、Telegram token)都在 **`config.env`**,**不入库**(`.gitignore` 已排除)。脚本运行时 `source` 它。

```sh
cp config.env.example /opt/live-iso-builder/config.env
vim /opt/live-iso-builder/config.env      # 填真实值
chmod 600 /opt/live-iso-builder/config.env
```

字段说明见 `config.env.example`。

## 流程

`live-iso-build.timer`(每周一次)触发 `build-and-deploy.sh`:

1. 拉取 Live-ISO 构建仓库(KDE 分支),记下本锅 commit;源非 origin 最新会发 WARN。
2. **编译前预检**(几秒):镜像站 SSH+磁盘余量、gig/settings-gig fork 可达、内存够挂 tmpfs。缺料即 abort+通知,绝不白烧几小时。
3. 挂 tmpfs,在内存里 `build.sh` 全量构建(吃满核;binpkg/distfiles 缓存落 SSD、跨构建复用)。
4. `verify-iso.sh` 挂载 squashfs 实检关键项(calamares 版本、shellprocess 装机清理契约、grub 无 early-KMS、nvidia 加载、无 plasma-localerc、无密钥泄漏…),关键项缺失则拦截、不上线。
5. 校验通过后把 ISO + `BUILD_MANIFEST`(commit/sha 身份证)原子暂存到 SSD,再上传、上线后**回读 live sha256**、按 `KEEP` 删旧版(本锅永不删)。
6. 调下载站 `render-index.sh` 渲染落地页,然后**端到端核对**:curl 站上 `.sha256` 与落地页确为本锅,不符即 fail+通知。这一步根治"编译了没更新/上了旧盘"。

`reupload-iso.sh`(下载站抽风时手动重传,不重编)以 `BUILD_MANIFEST` 为权威:无 manifest / sha 不符 / 陈旧一律拒传,杜绝盲传旧盘。

## 通知

构建**开始 / 成功 / 失败**自动推送到 Telegram 频道 **<https://t.me/gentoomirror>**(成功/失败附用时与时间)。配置 `config.env` 的 `TG_TOKEN` / `TG_CHAT` 即启用,留空则静默。

**任何异常都不会静默**:运行期语法错、被 kill(systemd 超时 / Ctrl-C / 挂断)、未到终点的退出,都由 `on_exit` 兜底发 FAILED;连 wrapper 都没起来(语法体检不过 / config 缺)则由 `live-iso-notify-fail.service`(`OnFailure=`)兜底。`reupload-iso.sh` 同样会通知。`service` 的 `ExecStartPre` 在每次启动前对脚本做 `bash -n` 语法体检,语法错绝不进入几小时构建。

## 手动操作

```sh
sudo systemctl start live-iso-build.service     # 手动触发一次
journalctl -u live-iso-build.service -f         # 看进度
tail -f /opt/live-iso-builder/logs/build-*.log  # 详细日志
sudo /opt/live-iso-builder/reupload-iso.sh      # 不重编,把暂存的已验证 ISO 重传上线
```

## 安全

- 所有密钥与部署拓扑(下载站 IP/端口/用户、SSH key 路径、Telegram token)只在 `config.env`,**绝不入库**(`.gitignore` 已排除)。仓库内任何脚本都不含真实凭据;`config.env.example` 全是占位值。
- 提交前请确认无密钥混入:`git grep -nE '私钥|PRIVATE KEY|真实IP'` 应无命中。
- 自托管者:把 `config.env` 权限设 `600`、仅 root 可读;SSH 部署 key 用单独的、最小权限的密钥对。

## 许可

[MIT](LICENSE) © Gentoo 中文社区(gentoozh)。

## 相关仓库

- [Gentoo-zh/Live-ISO](https://github.com/Gentoo-zh/Live-ISO)(KDE 分支)—— 构建脚本与定制
- [Gentoo-zh/calamares-settings-gig](https://github.com/Gentoo-zh/calamares-settings-gig) —— 图形安装器配置
- [Gentoo-zh/gig](https://github.com/Gentoo-zh/gig) —— 构建用的 overlay(锁版本)
- [Zakkaus/gentoozh-mirror](https://github.com/Zakkaus/gentoozh-mirror) —— 下载站落地页源
