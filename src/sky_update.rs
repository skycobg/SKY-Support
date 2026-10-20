// SKY Support: automatic updates from our own server instead of GitHub.
//
// `SKY_UPDATE_INFO_URL` (hbb_common config) serves a small JSON written by
// finish-release.sh:
//   {"version":"1.5.0-2","windows":{"url":"https://…/SKY-Support-1.5.0-2-x86_64.exe","sha256":"…"}}
// The service's updater (src/updater.rs) calls `check()` once a day and after
// start; a newer version is fetched with `download()`, verified by sha256 and
// installed through the upstream `--update` path, without asking the user.
// Our versions are `<upstream>-<n>` (1.5.0-2, 1.5.0-3, …, n ≤ 9): the
// upstream version comparison reserves that suffix for patch builds.

#![allow(dead_code)]

use hbb_common::{
    bail, config, get_version_number, log,
    sha2::{Digest, Sha256},
    ResultType,
};
use serde_derive::Deserialize;
use std::{io::Write, path::PathBuf};

#[derive(Deserialize, Debug)]
pub struct Asset {
    pub url: String,
    pub sha256: String,
}

#[derive(Deserialize, Debug)]
pub struct Info {
    pub version: String,
    #[serde(default)]
    pub windows: Option<Asset>,
}

pub struct Pending {
    pub version: String,
    pub url: String,
    pub sha256: String,
}

#[inline]
pub fn is_enabled() -> bool {
    !config::SKY_UPDATE_INFO_URL.is_empty()
}

/// Our build updates itself without asking: on unless the user turns it off.
pub fn apply_defaults() {
    if !is_enabled() {
        return;
    }
    config::DEFAULT_SETTINGS.write().unwrap().insert(
        base::config::keys::OPTION_ALLOW_AUTO_UPDATE.to_owned(),
        "Y".to_owned(),
    );
}

/// Asks our server for the current version. `Ok(None)`: nothing newer.
pub fn check() -> ResultType<Option<Pending>> {
    let url = config::SKY_UPDATE_INFO_URL;
    let client = crate::hbbs_http::create_http_client_with_url_strict(url)?;
    let resp = client.get(url).send()?;
    if !resp.status().is_success() {
        bail!("sky update: version info: HTTP {}", resp.status());
    }
    let info: Info = serde_json::from_slice(&resp.bytes()?)?;
    if get_version_number(&info.version) <= get_version_number(crate::VERSION) {
        log::debug!(
            "sky update: {} is current (server has {})",
            crate::VERSION,
            info.version
        );
        return Ok(None);
    }
    let Some(asset) = info.windows else {
        bail!("sky update: version info has no windows asset");
    };
    if !asset.url.starts_with("https://") {
        bail!("sky update: download url must be https: {}", asset.url);
    }
    log::info!("sky update: new version {} at {}", info.version, asset.url);
    Ok(Some(Pending {
        version: info.version,
        url: asset.url,
        sha256: asset.sha256.to_lowercase(),
    }))
}

/// Downloads the new version into the temp dir and verifies its sha256.
pub fn download(p: &Pending) -> ResultType<PathBuf> {
    let file_name = p.url.rsplit('/').next().unwrap_or_default();
    if file_name.is_empty()
        || !file_name.to_lowercase().ends_with(".exe")
        || file_name.contains("..")
    {
        bail!("sky update: bad file name in {}", p.url);
    }
    let file_path = std::env::temp_dir().join(file_name);
    let client = crate::hbbs_http::create_http_client_with_url_strict(&p.url)?;
    let resp = client.get(&p.url).send()?;
    if !resp.status().is_success() {
        bail!("sky update: download failed: HTTP {}", resp.status());
    }
    let data = resp.bytes()?;
    let hex: String = Sha256::digest(&data)
        .iter()
        .map(|b| format!("{:02x}", b))
        .collect();
    if hex != p.sha256 {
        bail!(
            "sky update: sha256 mismatch for {}: got {}, expected {}",
            file_name,
            hex,
            p.sha256
        );
    }
    let mut file = std::fs::File::create(&file_path)?;
    file.write_all(&data)?;
    log::info!("sky update: downloaded {} ({} bytes)", file_path.display(), data.len());
    Ok(file_path)
}
