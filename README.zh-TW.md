# gentoozh-liveiso-infra

[简体中文](README.md) · [正體中文](README.zh-TW.md) · [English](README.en.md)

Gentoo 中文社群 Live ISO 的自動建置與發布腳本。產物是 KDE Plasma 桌面 Live ISO（`gig-os-YYYYMMDD.iso`），由建置機上的 systemd timer 每週編一次，驗證通過後傳到 Cloudflare R2。

本倉庫只做編排。建置本身在 [Gig-OS/Live-ISO](https://github.com/Gig-OS/Live-ISO) 的 `KDE` 分支，包括防併發鎖、overlay、`@world` 與出廠內容。

## 部署

腳本執行在建置機上，機器不自動拉取。**本倉庫是來源，改完手動同步過去；在機器上改了也要同步回來**，否則兩邊會漂移。

| 倉庫內 | 部署到 |
|---|---|
| `build/*.sh` | `/opt/live-iso-builder/` |
| `systemd/*` | `/etc/systemd/system/` |
| `config.env.example` | 複製成 `/opt/live-iso-builder/config.env` 並填寫 |

出廠清理的閘門腳本 `99-sanitize-for-release.sh` **不在本倉庫**，它在 [Live-ISO](https://github.com/Gig-OS/Live-ISO) 的 `hooks/` 裡，由 `build.sh` 直接 source。改閘門要改那邊。

步驟：

1. 確認沒有建置在執行：`systemctl is-active live-iso-build.service`。建置期間覆蓋腳本會讓執行中的行程讀到半截程式碼，整鍋作廢。
2. 同步腳本，`chmod +x /opt/live-iso-builder/*.sh`。
3. 改過 unit 要 `systemctl daemon-reload`。timer 用 `systemctl enable --now live-iso-build.timer`；`live-iso-notify-fail.service` 由 `OnFailure=` 拉起，不必 enable。
4. 填 `config.env`，安裝 `rclone`。R2 欄位缺失時預檢直接停，不會先編幾小時。

## config.env

```sh
cp config.env.example /opt/live-iso-builder/config.env
vim /opt/live-iso-builder/config.env
chmod 600 /opt/live-iso-builder/config.env
```

欄位說明見 `config.env.example`。R2 token 在 Cloudflare 的 R2 → Manage API Tokens 建立，授予 Object Read & Write 並限定到該 bucket。

## 流程

`live-iso-build.timer` 每週一 04:00（Asia/Shanghai）觸發 `build-and-deploy.sh`：

1. 拉取 `Gig-OS/Live-ISO` 的 `KDE` 分支，記下 commit。
2. 預檢：倉庫可達、overlay 可達、R2 可列。缺料即停。
3. 建置。**預設落磁碟**；`USE_TMPFS=1` 才掛 tmpfs 在記憶體裡編。這是共享機，其他人的編譯同樣需要記憶體。binpkg 與 distfiles 快取落 SSD 跨鍋重用。
4. `verify-iso.sh` 掛載 squashfs 抽查關鍵項：calamares、安裝清理、grub、顯示卡驅動、有無混入金鑰。不通過即攔下。
5. `rclone` 上傳到 R2，按 `R2_KEEP` 保留最近幾版。
6. 核對：從 R2 公開網域取回本鍋檔案對帳 content-length，再看下載頁是否已列出。

`reupload-iso.sh` 用於 R2 上傳失敗後手動重傳，不重編，以 `BUILD_MANIFEST` 為準，校驗和不符即拒絕。

## 通知

開始、成功、失敗都推送到 Telegram [@gentoomirror](https://t.me/gentoomirror)，填好 `config.env` 的 `TG_TOKEN` 與 `TG_CHAT` 即生效，留空則靜默。腳本的 `on_exit` 兜底報失敗；腳本未能啟動時由 `live-iso-notify-fail.service` 報。

## 手動操作

```sh
sudo systemctl start live-iso-build.service          # 手動編一次
sudo USE_TMPFS=1 systemctl start live-iso-build      # 改用記憶體建置
journalctl -u live-iso-build.service -f              # 看進度
tail -f /opt/live-iso-builder/logs/build-*.log       # 日誌
sudo /opt/live-iso-builder/reupload-iso.sh           # 重傳已驗證的 ISO，不重編
```

`live-iso-build.service` 是 `Type=oneshot`，整個建置期間 `systemctl is-active` 都顯示 `activating`，判斷是否完成要看日誌。被發布閘門攔下時，用 `grep -nE '关键：|关键失败|拒绝上线' <日誌>` 定位具體條目（標記在腳本裡是簡體，逐字保持不變）。

## 金鑰

`config.env` 不入庫，權限 `600`。腳本內沒有真實憑證，`config.env.example` 全是佔位值。提交前用 `git grep` 確認沒有混入 token。

## 授權

[MIT](LICENSE) © Gentoo 中文社群。

## 相關倉庫

- [Gig-OS/Live-ISO](https://github.com/Gig-OS/Live-ISO)（`KDE` 分支）：建置腳本與客製
- [Gig-OS/calamares-settings-gig](https://github.com/Gig-OS/calamares-settings-gig)：圖形安裝器設定
- [Gig-OS/gigos-mirror](https://github.com/Gig-OS/gigos-mirror)：下載站 iso.gentoozh.org
