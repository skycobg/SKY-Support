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
- Our own server, not the public one: `using_public_server()` returns false (`src/common.rs`), so there is no
  "set up your own server" tip, no cap on custom image quality and the direct-connection options are shown.
- Audit records to our API server (lejianwen/rustdesk-api): its `{"code":0,...}` answer counts as success
  (`src/server/connection.rs`); before, every record was posted three times.
- A note at the end of each session is asked for by default (`allow-ask-for-note`, `apply_defaults()` in
  `src/sky_update.rs`); our API server keeps it with the connection log.
- About: links to this source code and to sky.bg instead of rustdesk.com (desktop and mobile settings); the
  install page links to our licence.
- Windows app list: the shown name `SKY Support` and the publisher `SKY COMPANY EOOD` (`src/platform/windows.rs`,
  also written on update). The portable exe's Details carry our names (`libs/portable/Cargo.toml`) and our
  version (`SKY_VERSION` in `libs/portable/build.rs`).
- macOS: the bundle is `SKY-Support.app` (the Rust side expects `/Applications/<APP_NAME>.app`), bundle id
  `bg.sky.support`, shown name `SKY Support`, URL scheme `sky-support`, our icon (`flutter/macos/...`, `build.py`).
  Built unsigned (ad-hoc signed, not notarized) until SKY has an Apple Developer ID.
- IDs: a custom ID ("Change ID", `--set-id`) is 6 to 16 of a-z, A-Z, 0-9, `-` and `_` in any order, so only
  digits or only letters too; upstream asks for a letter first (`is_valid_custom_id` in `libs/hbb_common/src/lib.rs`,
  the rules of `changeIdDialog` in `flutter/lib/common/widgets/dialog.dart`, the `id_change_tip` text). Our server
  checks the same: <https://github.com/skycobg/rustdesk-server>.
- Peer menu as in Radmin (`flutter/lib/common/widgets/peer_card.dart`): a right click on a computer opens
  its menu where the pointer is (upstream only has the "more" button); it starts with "Full Control" and
  "View only", the mode of that connection. A double click starts in the default mode (Settings, View
  mode), so a "View only" from before does not stick to the computer (upstream keeps it per peer). The
  mode goes to the peer's config before the session starts (`main_set_peer_view_only` in
  `src/flutter_ffi.rs`).
- Logged in to our API server, connecting timed out ("Failed to secure tcp: deadline has elapsed"): the
  client sends the API access token to the rendezvous server only after a key exchange that our hbbs (OSS)
  does not do, and hbbs has no use for the token. So it is not sent (`io_loop` in
  `src/ui_session_interface.rs`) and the rendezvous goes as for a client not logged in; the token stays
  with the API server. Known limit: switching sides needs the same exchange.
- Build: `.github/workflows/sky-build.yml` builds Windows x64, Android arm64 and macOS (arm64 and Intel) with
  GitHub Actions; a manual run can be limited to `win-android` or `macos`.

Only the public key of our server is embedded; private keys and credentials are never in this repository.

Builds: GitHub Actions workflow `sky-build.yml` (manual run or tag `sky-*`).
