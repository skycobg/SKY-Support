fn main() {
    #[cfg(windows)]
    {
        use std::io::Write;
        let mut res = winres::WindowsResource::new();
        res.set_icon("../../res/icon.ico")
            .set_language(winapi::um::winnt::MAKELANGID(
                winapi::um::winnt::LANG_ENGLISH,
                winapi::um::winnt::SUBLANG_ENGLISH_US,
            ))
            .set_manifest_file("../../res/manifest.xml");
        // SKY: our version (1.5.0-3) in the Details tab; finish-release.sh passes it.
        println!("cargo:rerun-if-env-changed=SKY_VERSION");
        if let Ok(v) = std::env::var("SKY_VERSION") {
            res.set("ProductVersion", &v).set("FileVersion", &v);
        }
        match res.compile() {
            Err(e) => {
                write!(std::io::stderr(), "{}", e).unwrap();
                std::process::exit(1);
            }
            Ok(_) => {}
        }
    }
}
