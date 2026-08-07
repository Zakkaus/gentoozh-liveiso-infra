# gentoozh-liveiso-infra

[简体中文](README.md) · [正體中文](README.zh-TW.md) · [English](README.en.md)

Build and release automation for the Gentoo-zh Community Live ISO. It produces a KDE Plasma desktop
Live ISO (`gig-os-YYYYMMDD.iso`), built weekly by a systemd timer on the build host and uploaded to
the mirror at `distfiles.gentoozh.org/gigos/` once it passes verification.

This repository only orchestrates. The build itself lives on the `KDE` branch of
[Gig-OS/Live-ISO](https://github.com/Gig-OS/Live-ISO), including the concurrency lock, the overlay,
`@world` and the shipped contents.

## Deployment

The scripts run on the build host, which does not pull by itself. **This repository is the source:
sync changes to the host after editing, and sync back anything edited on the host**, otherwise the
two drift apart.

| In this repository | Deployed to |
|---|---|
| `build/*.sh` | `/opt/live-iso-builder/` |
| `systemd/*` | `/etc/systemd/system/` |
| `config.env.example` | copy to `/opt/live-iso-builder/config.env` and fill it in |

The release gate `99-sanitize-for-release.sh` is **not in this repository**. It lives in `hooks/` in
[Live-ISO](https://github.com/Gig-OS/Live-ISO) and is sourced directly by `build.sh`; edit it there.

Steps:

1. Confirm no build is running: `systemctl is-active live-iso-build.service`. Overwriting a script
   mid-build makes the running process read half-written code and wastes the whole run.
2. Sync the scripts, then `chmod +x /opt/live-iso-builder/*.sh`.
3. After changing a unit, run `systemctl daemon-reload`. Enable the timer with
   `systemctl enable --now live-iso-build.timer`; `live-iso-notify-fail.service` is started by
   `OnFailure=` and does not need enabling.
4. Fill in `config.env` and give root a key that can write to `/srv/pub/gigos` on the mirror. An
   unwritable target stops the preflight immediately
   rather than after hours of compilation.

## config.env

```sh
cp config.env.example /opt/live-iso-builder/config.env
vim /opt/live-iso-builder/config.env
chmod 600 /opt/live-iso-builder/config.env
```

The fields are documented in `config.env.example`. The key named in `MIRROR_SSH_OPTS` has to be in
in Cloudflare, granting Object Read & Write scoped to that bucket.

## What a run does

`live-iso-build.timer` fires `build-and-deploy.sh` every Monday at 04:00 Asia/Shanghai:

1. Fetch the `KDE` branch of `Gig-OS/Live-ISO` and record the commit.
2. Preflight: the repository, the overlay and the mirror's upload directory must all be reachable.
   Stop if not.
3. Build. **Disk-backed by default**; set `USE_TMPFS=1` to build in RAM instead. This is a shared
   machine and other people's compiles need the memory too. The binpkg and distfiles caches live on
   SSD and are reused across runs.
4. `verify-iso.sh` mounts the squashfs and checks the things that must be present: calamares, the
   install-time cleanup, grub, the graphics drivers, and the absence of leaked credentials. A
   failure blocks the release.
5. Upload to `distfiles.gentoozh.org/gigos/`, keeping the most recent `MIRROR_KEEP` builds and
   checking the public status code and `content-length`. `r2.gentoozh.org` redirects here, so this
   is the only public path and a failure fails the run. Skipped when `MIRROR_SSH_TARGET` is unset.
6. Check that the landing page lists the build. The page is a Worker view over the mirror's
   directory listing, it lags behind the edge cache and is not authoritative.

`reupload-iso.sh` retries a failed upload without rebuilding. It trusts `BUILD_MANIFEST` and refuses
to upload when the checksum does not match.

## Notifications

Start, success and failure are pushed to Telegram
[@gentoomirror](https://t.me/gentoomirror). Set `TG_TOKEN` and `TG_CHAT` in `config.env` to enable
them; leave them empty to stay silent. The script's `on_exit` trap reports failures; if the script
never starts, `live-iso-notify-fail.service` reports instead.

## Manual operation

```sh
sudo systemctl start live-iso-build.service          # build once
sudo USE_TMPFS=1 systemctl start live-iso-build      # build in RAM instead
journalctl -u live-iso-build.service -f              # follow progress
tail -f /opt/live-iso-builder/logs/build-*.log       # the log
sudo /opt/live-iso-builder/reupload-iso.sh           # re-upload a verified ISO without rebuilding
```

`live-iso-build.service` is `Type=oneshot`, so `systemctl is-active` reports `activating` for the
whole build; read the log to tell whether it finished. When a release gate blocks the build, locate
the failing item with `grep -nE '关键：|关键失败|拒绝上线' <log>`. Those markers are Simplified
Chinese in the scripts and must be matched verbatim.

## Credentials

`config.env` is not committed and is mode `600`. The scripts contain no real credentials and
`config.env.example` holds only placeholders. Run `git grep` before committing to confirm no token
slipped in.

## Licence

[MIT](LICENSE) © Gentoo-zh Community.

## Related repositories

- [Gig-OS/Live-ISO](https://github.com/Gig-OS/Live-ISO) (`KDE` branch): build scripts and customisation
- [Gig-OS/calamares-settings-gig](https://github.com/Gig-OS/calamares-settings-gig): installer configuration
- [Gig-OS/gigos-mirror](https://github.com/Gig-OS/gigos-mirror): the download site, iso.gentoozh.org
