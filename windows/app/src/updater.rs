//! Updates from app-hosting's Windows feed (appcast-windows.xml), the same way
//! the Mac app updates: check in the background, download, check the
//! installer's Ed25519 signature against the key the Mac app uses, and install
//! once no agent has a window or a call in flight. Installing restarts the
//! app; `bcu mcp` reconnects on its next call.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use windows::Win32::System::Com::Urlmon::URLDownloadToFileW;
use windows::Win32::UI::WindowsAndMessaging::{MB_ICONINFORMATION, MB_OK, MessageBoxW};
use windows::core::{HSTRING, w};

use crate::sessions;

const FEED: &str = "https://apps.moulik.dev/background-computer-use/appcast-windows.xml";
/// The app's Sparkle key (the Mac app's SUPublicEDKey); app-hosting signs Windows installers with it too.
const PUBLIC_KEY: &str = "+k+OitC0q+Sidp2n59PQ0mjvjzUsW0VhCUWQ2a4ifS0=";
const CHECK_EVERY: Duration = Duration::from_secs(60 * 60);

/// This build's version, set by the release build (BCU_VERSION), X.Y.Z.
pub fn version() -> &'static str {
    option_env!("BCU_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

struct Update {
    version: String,
    installer: PathBuf,
}

/// A downloaded, verified update waiting for the agents to go idle.
static READY: Mutex<Option<Update>> = Mutex::new(None);
static CHECKING: AtomicBool = AtomicBool::new(false);

/// Called when the app has to quit to install (from any thread).
static QUIT: Mutex<Option<Box<dyn Fn() + Send>>> = Mutex::new(None);

pub fn start(quit: impl Fn() + Send + 'static) {
    *QUIT.lock().unwrap_or_else(|e| e.into_inner()) = Some(Box::new(quit));
    cleanup_old_files();
    std::thread::Builder::new()
        .name("updater".into())
        .spawn(|| {
            std::thread::sleep(Duration::from_secs(30));
            let mut last_check: Option<Instant> = None;
            loop {
                if last_check.is_none_or(|t| t.elapsed() >= CHECK_EVERY) {
                    last_check = Some(Instant::now());
                    if let Err(e) = check() {
                        eprintln!("update check: {e}");
                    }
                }
                install_if_idle();
                std::thread::sleep(Duration::from_secs(15));
            }
        })
        .expect("updater thread");
}

/// "Check for updates" from the tray: check now, and say so if there's nothing new.
pub fn check_now() {
    std::thread::spawn(|| {
        let result = check();
        let text = match (&result, READY.lock().unwrap_or_else(|e| e.into_inner()).as_ref()) {
            (_, Some(u)) => format!("Version {} is ready. It installs as soon as no agent is working.", u.version),
            (Ok(()), None) => format!("You're on the latest version ({}).", version()),
            (Err(e), None) => format!("Couldn't check for updates: {e}"),
        };
        unsafe {
            MessageBoxW(None, &HSTRING::from(text), w!("Background Computer Use"), MB_OK | MB_ICONINFORMATION);
        }
        install_if_idle();
    });
}

/// The version ready to install, for the tray menu.
pub fn pending() -> Option<String> {
    READY.lock().unwrap_or_else(|e| e.into_inner()).as_ref().map(|u| u.version.clone())
}

/// Install the ready update now, agents or not (the tray's "Restart to update").
pub fn install_now() {
    let update = READY.lock().unwrap_or_else(|e| e.into_inner()).take();
    if let Some(u) = update {
        run_installer(&u);
    }
}

fn install_if_idle() {
    let idle = sessions::all().iter().all(|v| v.windows == 0 && v.busy.is_none() && v.last_call.is_none_or(|t| t.elapsed() > Duration::from_secs(60)));
    if idle {
        install_now();
    }
}

fn run_installer(u: &Update) {
    // The installer waits for this app to quit, replaces it and starts the new one.
    let ok = std::process::Command::new(&u.installer).args(["--silent", "--update"]).spawn().is_ok();
    if ok && let Some(quit) = QUIT.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        quit();
    }
}

fn check() -> Result<(), String> {
    if CHECKING.swap(true, Ordering::AcqRel) {
        return Ok(());
    }
    let result = check_inner();
    CHECKING.store(false, Ordering::Release);
    result
}

fn check_inner() -> Result<(), String> {
    let dir = std::env::temp_dir().join("BackgroundComputerUse-update");
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let feed_path = dir.join("appcast-windows.xml");
    // A query string keeps the system's download cache out of the way.
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    download(&format!("{FEED}?t={stamp}"), &feed_path)?;
    let feed = std::fs::read_to_string(&feed_path).map_err(|e| e.to_string())?;
    let Some(item) = newest(&feed) else { return Ok(()) };
    if !newer(&item.version, version()) {
        return Ok(());
    }
    if READY.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|u| u.version == item.version) {
        return Ok(());
    }
    let name = item.url.rsplit('/').next().filter(|n| n.to_lowercase().ends_with(".exe")).unwrap_or("BackgroundComputerUse-Setup.exe");
    let installer = dir.join(name);
    download(&item.url, &installer)?;
    let bytes = std::fs::read(&installer).map_err(|e| e.to_string())?;
    if item.length.is_some_and(|n| n != bytes.len() as u64) {
        return Err("the download is the wrong size".into());
    }
    if !verify(&bytes, &item.signature) {
        let _ = std::fs::remove_file(&installer);
        return Err("the update's signature doesn't match".into());
    }
    *READY.lock().unwrap_or_else(|e| e.into_inner()) = Some(Update { version: item.version, installer });
    Ok(())
}

fn download(url: &str, to: &Path) -> Result<(), String> {
    let _ = std::fs::remove_file(to);
    unsafe { URLDownloadToFileW(None, &HSTRING::from(url), &HSTRING::from(to.as_os_str()), 0, None) }.map_err(|e| format!("download failed: {e}"))
}

struct Item {
    version: String,
    url: String,
    length: Option<u64>,
    signature: String,
}

/// The newest item in a Sparkle appcast.
fn newest(feed: &str) -> Option<Item> {
    let mut best: Option<Item> = None;
    for chunk in feed.split("<item>").skip(1) {
        let item = chunk.split("</item>").next().unwrap_or("");
        let Some(version) = tag(item, "sparkle:shortVersionString").or_else(|| tag(item, "sparkle:version")) else { continue };
        let Some(enclosure) = item.split("<enclosure").nth(1).and_then(|e| e.split('>').next()) else { continue };
        let (Some(url), Some(signature)) = (attr(enclosure, "url"), attr(enclosure, "sparkle:edSignature")) else { continue };
        let length = attr(enclosure, "length").and_then(|l| l.parse().ok());
        let candidate = Item { version: version.trim().to_string(), url: unescape(&url), length, signature };
        if best.as_ref().is_none_or(|b| newer(&candidate.version, &b.version)) {
            best = Some(candidate);
        }
    }
    best
}

fn tag(s: &str, name: &str) -> Option<String> {
    let start = s.find(&format!("<{name}>"))? + name.len() + 2;
    let end = s[start..].find(&format!("</{name}>"))? + start;
    Some(s[start..end].to_string())
}

fn attr(s: &str, name: &str) -> Option<String> {
    let start = s.find(&format!("{name}=\""))? + name.len() + 2;
    let end = s[start..].find('"')? + start;
    Some(s[start..end].to_string())
}

fn unescape(s: &str) -> String {
    s.replace("&amp;", "&").replace("&quot;", "\"").replace("&apos;", "'").replace("&lt;", "<").replace("&gt;", ">")
}

fn parts(v: &str) -> Vec<u64> {
    v.split('.').map(|p| p.trim().parse().unwrap_or(0)).collect()
}

/// Whether `a` is a later X.Y.Z than `b`.
fn newer(a: &str, b: &str) -> bool {
    parts(a) > parts(b)
}

fn verify(data: &[u8], signature: &str) -> bool {
    use ed25519_dalek::{Signature, Verifier, VerifyingKey};
    let (Some(key), Some(sig)) = (base64(PUBLIC_KEY), base64(signature)) else { return false };
    let (Ok(key), Ok(sig)) = (<[u8; 32]>::try_from(key.as_slice()), <[u8; 64]>::try_from(sig.as_slice())) else { return false };
    let Ok(key) = VerifyingKey::from_bytes(&key) else { return false };
    key.verify(data, &Signature::from_bytes(&sig)).is_ok()
}

fn base64(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        } as u32)
    }
    let mut out = Vec::new();
    let mut acc = 0u32;
    let mut bits = 0;
    for &c in s.trim().as_bytes() {
        if c == b'=' {
            break;
        }
        acc = (acc << 6) | val(c)?;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// Files the installer couldn't replace while they ran (an agent's bcu.exe) were
/// renamed to *.old-N; remove them once they're free.
fn cleanup_old_files() {
    let Some(dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) else { return };
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            if e.file_name().to_string_lossy().contains(".old-") {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_the_newest_item() {
        let feed = r#"<rss><channel>
            <item><sparkle:version>0.1.8</sparkle:version><sparkle:shortVersionString>0.1.8</sparkle:shortVersionString>
            <enclosure url="https://x/releases/0.1.8/S.exe" length="10" type="application/octet-stream" sparkle:os="windows" sparkle:edSignature="abc"/></item>
            <item><sparkle:shortVersionString>0.1.10</sparkle:shortVersionString>
            <enclosure url="https://x/releases/0.1.10/S.exe?a=1&amp;b=2" length="12" sparkle:edSignature="def"/></item>
        </channel></rss>"#;
        let item = newest(feed).unwrap();
        assert_eq!(item.version, "0.1.10");
        assert_eq!(item.url, "https://x/releases/0.1.10/S.exe?a=1&b=2");
        assert_eq!(item.length, Some(12));
        assert!(newer("0.1.10", "0.1.9") && !newer("0.1.7", "0.1.7"));
    }
}
