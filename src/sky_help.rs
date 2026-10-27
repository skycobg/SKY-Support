//! SKY: help requests. The customer phones SKY and presses the button in SKY Support, which then sends its ID,
//! its one-time password and what it knows about the computer to our server; a technician accepts the request
//! and connects without digits or questions on the customer's side. The SKY Zapper app (or another of our
//! programs) starts SKY Support with `--sky-help <file>`: a JSON file with what that program knows about itself.
//! The window and the requests are in Flutter (`flutter/lib/common/sky_help.dart`); this file has what only the
//! native side knows. The contract: README-SKY.md.

use hbb_common::config::Config;
use serde_json::{json, Value};

/// Takes `--sky-help <file>` out of the command line, so that the rest of the start runs as without it; Flutter
/// reads the file from its own copy of the command line.
pub fn take_arg(args: &mut Vec<String>) -> Option<String> {
    let i = args.iter().position(|a| a == "--sky-help")?;
    args.remove(i);
    (i < args.len()).then(|| args.remove(i))
}

/// The rows about this computer that go with a help request, as JSON: `{"rows": [{"k", "v"}], "hostname"}`.
pub fn computer_info() -> String {
    let si = crate::common::get_sysinfo();
    let s = |k: &str| {
        si.get(k)
            .and_then(|v| v.as_str())
            .unwrap_or_default()
            .trim()
            .to_owned()
    };
    let host = s("hostname");
    let user = s("username");
    let mut rows: Vec<Value> = vec![];
    let mut push = |k: &str, v: String| {
        let v = v.trim().to_owned();
        if !v.is_empty() {
            rows.push(json!({ "k": k, "v": v }));
        }
    };
    push(
        "Компютър",
        if user.is_empty() {
            host.clone()
        } else {
            format!("{host} (потребител {user})")
        },
    );
    push("Система", s("os"));
    push("Процесор", s("cpu"));
    push("Памет", s("memory"));
    #[cfg(windows)]
    push("WiFi", wifi());
    push("Локален IP", local_ip());
    push("SKY Support", crate::VERSION.to_owned());
    push("ID", Config::get_id());
    json!({ "rows": rows, "hostname": host }).to_string()
}

/// The Wi-Fi network and its signal (`netsh wlan show interfaces`). Empty without Wi-Fi, and on Windows 11 when
/// location is off for apps (Windows hides the network name then).
#[cfg(windows)]
fn wifi() -> String {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let Ok(out) = std::process::Command::new("netsh")
        .args(["wlan", "show", "interfaces"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    else {
        return String::new();
    };
    parse_netsh_wlan(&String::from_utf8_lossy(&out.stdout))
}

/// The first SSID and the first percentage in `netsh wlan show interfaces` (the labels are translated, "SSID"
/// is not; the signal is the only value in per cent).
#[cfg(any(windows, test))]
fn parse_netsh_wlan(text: &str) -> String {
    let mut ssid = String::new();
    let mut signal = String::new();
    for line in text.lines() {
        let Some((k, v)) = line.split_once(':') else {
            continue;
        };
        let (k, v) = (k.trim(), v.trim());
        if k == "SSID" && ssid.is_empty() {
            ssid = v.to_owned();
        } else if signal.is_empty()
            && v.ends_with('%')
            && v.trim_end_matches('%').trim().parse::<u32>().is_ok()
        {
            signal = v.replace(' ', "");
        }
    }
    match (ssid.is_empty(), signal.is_empty()) {
        (true, _) => String::new(),
        (false, true) => ssid,
        (false, false) => format!("{ssid} (сигнал {signal})"),
    }
}

/// The address this computer goes out with (no packet is sent: a UDP socket only picks the route).
fn local_ip() -> String {
    let Ok(s) = std::net::UdpSocket::bind("0.0.0.0:0") else {
        return String::new();
    };
    if s.connect("8.8.8.8:80").is_err() {
        return String::new();
    }
    s.local_addr().map(|a| a.ip().to_string()).unwrap_or_default()
}

/// SKY Support is already open on this computer: the help window opens in it, the same way `--connect` reaches
/// an open SKY Support. True if the open one took it.
#[cfg(all(windows, feature = "flutter"))]
pub fn send_to_running(file: &str) -> bool {
    use winapi::um::winuser::WM_USER;
    crate::platform::send_message_to_hnwd(
        &crate::platform::FLUTTER_RUNNER_WIN32_WINDOW_CLASS,
        &crate::get_app_display_name(),
        (WM_USER + 2) as _, // the uni links message, as in core_main_invoke_new_connection
        &link(file),
        false,
    )
}

/// The link an open SKY Support gets: `sky-support://sky-help?f=<the file's path in hex>`.
#[cfg(any(all(windows, feature = "flutter"), test))]
fn link(file: &str) -> String {
    format!(
        "{}sky-help?f={}",
        crate::get_uri_prefix(),
        hex::encode(file.as_bytes())
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn netsh_english_and_translated() {
        let en = "There is 1 interface on the system:\r\n\r\n    Name                   : Wi-Fi\r\n    State                  : connected\r\n    SSID                   : Vivacom_5G\r\n    BSSID                  : aa:bb:cc:dd:ee:ff\r\n    Receive rate (Mbps)    : 866.7\r\n    Signal                 : 87% \r\n";
        assert_eq!(parse_netsh_wlan(en), "Vivacom_5G (сигнал 87%)");
        let bg = "    Име                    : Wi-Fi\n    SSID                   : Офис\n    BSSID                  : aa:bb:cc:dd:ee:ff\n    Сигнал                 : 60 %\n";
        assert_eq!(parse_netsh_wlan(bg), "Офис (сигнал 60%)");
        assert_eq!(parse_netsh_wlan("    State : disconnected\n"), "");
        assert_eq!(
            parse_netsh_wlan("    SSID : Home\n    Channel : 6\n"),
            "Home"
        );
    }

    #[test]
    fn take_arg_removes_the_flag_and_its_file() {
        let mut a: Vec<String> = ["--noinstall", "--sky-help", "C:\\t\\x.json"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert_eq!(take_arg(&mut a).as_deref(), Some("C:\\t\\x.json"));
        assert_eq!(a, vec!["--noinstall".to_string()]);
        let mut b = vec!["--sky-help".to_string()];
        assert_eq!(take_arg(&mut b), None);
        assert!(b.is_empty());
        let mut c = vec!["--noinstall".to_string()];
        assert_eq!(take_arg(&mut c), None);
        assert_eq!(c.len(), 1);
    }

    #[test]
    fn link_is_hex() {
        let l = link("C:\\Temp\\помощ 1.json");
        assert!(l.ends_with(&format!("sky-help?f={}", hex::encode("C:\\Temp\\помощ 1.json"))));
        assert!(!l.contains(' '));
    }
}
