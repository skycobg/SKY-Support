# SKY Support

**SKY Support** is the remote-support client of [SKY](https://sky.bg) (Bulgaria), used by SKY technicians
to help customers on Windows and Android. It is a fork of [RustDesk](https://github.com/rustdesk/rustdesk)
1.5.0 and is licensed, like RustDesk, under the **GNU AGPL-3.0** (see `LICENCE`).

This repository is the complete corresponding source of the SKY Support binaries distributed at
<https://zapper.sky.bg/softuer>. Our changes live on the `sky` branch and are listed below; everything else
is upstream RustDesk. RustDesk is a trademark of Purslane Tech Pte. Ltd.; SKY Support is not affiliated with
or endorsed by them.

## What we changed (branch `sky`)

- Built-in server: `libs/hbb_common/src/config.rs` (`RENDEZVOUS_SERVERS`, `RS_PUB_KEY`,
  `DEFAULT_API_SERVER`), `src/common.rs` (`get_api_server_`). The submodule `libs/hbb_common` points to
  our fork <https://github.com/skycobg/hbb_common>.
- Branding: app name `SKY-Support` (technical: files, pipes, services, uri scheme) with the display name
  `SKY Support` (`APP_DISPLAY_NAME` in `libs/hbb_common/src/config.rs`, `get_app_display_name()` in
  `src/common.rs`, shown in title bars and substituted for "RustDesk" in all translated texts by `src/lang.rs`),
  Android package `bg.sky.support`, icons in `res/`, `flutter/assets/`, `flutter/android/.../mipmap-*`,
  Windows resource strings.
- Build: `.github/workflows/sky-build.yml` builds Windows x64 and Android arm64 with GitHub Actions.

Only the public key of our server is embedded; private keys and credentials are never in this repository.

Builds: GitHub Actions workflow `sky-build.yml` (manual run or tag `sky-*`).
