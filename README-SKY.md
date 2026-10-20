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
- `--noinstall` (upstream flag: run portable, never install) additionally hides the "Install" card and
  buttons (`src/core_main.rs`). The SKY Zapper desktop app starts SKY Support with it.
- Monitor layout per peer (desktop): `flutter/lib/common/sky_display_layout.dart` remembers on which local
  screen each remote display was shown (per set of local screens) and restores it on the next connection.
  Recorded when a session is established and on every window move/resize/fullscreen; a display switched away
  from is forgotten; windows the user closes get a "closed at" time, so a window closed long before the end
  of the session stays closed while the ones closed together at the end come back. Thin hooks in `model.dart`
  (`handlePeerInfo`), `tabbar_widget.dart` (`_saveFrame`), `remote_tab_page.dart`, `remote_page.dart`
  (`dispose`), `common.dart` (`openMonitorInTheSameTab`, exact frame through `screen_rect.f`),
  `multi_window_manager.dart`, `desktop_home_page.dart`; `src/ui_interface.rs` serializes
  `set_peer_flutter_option` (several windows write the same peer file).
- Automatic updates from our server: `src/sky_update.rs` reads `SKY_UPDATE_INFO_URL`
  (`https://zapper.sky.bg/support/version.json`, written by our release script), compares the version with
  `crate::VERSION`, downloads the signed exe, verifies its sha256 and hands it to the upstream `--update`
  path; hooked into `src/updater.rs` (installed Windows clients, service process) and on by default
  (`apply_defaults()` in `core_main`). Our versions are `<upstream>-<n>` (1.5.0-2, …, n ≤ 9) in `Cargo.toml`
  and `Cargo.lock`; the registry DWORD `VersionBuild` takes the number before the dash (`src/platform/windows.rs`).
- Build: `.github/workflows/sky-build.yml` builds Windows x64 and Android arm64 with GitHub Actions.

Only the public key of our server is embedded; private keys and credentials are never in this repository.

Builds: GitHub Actions workflow `sky-build.yml` (manual run or tag `sky-*`).
