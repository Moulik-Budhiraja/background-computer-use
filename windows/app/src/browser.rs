//! Telling browsers apart from other apps: agents should use the user's
//! default browser, the one signed in to their accounts (engine.rs).

use std::path::Path;

/// Whether `exe` is a Chromium browser: Chromium installs keep the exe in an
/// Application folder, next to a version folder holding <name>_elf.dll
/// (chrome_elf.dll, msedge_elf.dll).
pub fn is_chromium(exe: &str) -> bool {
    let Some(dir) = Path::new(exe).parent() else { return false };
    if !dir.file_name().is_some_and(|n| n.eq_ignore_ascii_case("Application")) {
        return false;
    }
    let has_elf = |version: &Path| {
        std::fs::read_dir(version).into_iter().flatten().flatten().any(|f| f.file_name().to_string_lossy().to_lowercase().ends_with("_elf.dll"))
    };
    std::fs::read_dir(dir).into_iter().flatten().flatten().any(|e| e.path().is_dir() && has_elf(&e.path()))
}

/// Whether `exe` is a web browser: a Chromium one, or Firefox.
pub fn is_browser(exe: &str) -> bool {
    is_chromium(exe) || Path::new(exe).file_name().is_some_and(|f| f.eq_ignore_ascii_case("firefox.exe"))
}
