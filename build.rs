//! Embed a minimal Info.plist into the `smartconnectd` executable on macOS.
//!
//! macOS attributes Bluetooth and local-network privacy prompts to the executable's bundle
//! identifier and usage strings. The daemon normally lives inside `SmartConnect.app`, but it can
//! also be run straight from `target/release/`; embedding the plist makes the same prompts work in
//! both cases (and keeps ad-hoc code signing happy).

fn main() {
    println!("cargo:rerun-if-changed=macapp/DaemonInfo.plist");

    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }

    let manifest = std::env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR");
    let plist = std::path::Path::new(&manifest).join("macapp/DaemonInfo.plist");
    println!(
        "cargo:rustc-link-arg=-Wl,-sectcreate,__TEXT,__info_plist,{}",
        plist.display()
    );
}
