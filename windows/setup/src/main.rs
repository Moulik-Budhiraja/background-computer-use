//! BackgroundComputerUse-Setup-X.Y.Z.exe: installs Background Computer Use for
//! the current user (no admin prompt) in %LOCALAPPDATA%\Programs, with a Start
//! menu shortcut and an entry in Settings > Apps, then starts it. The app's
//! updater runs it with --silent --update; it waits for the app to quit first.
//!
//!   --silent      no messages
//!   --update      started by the app's updater
//!   --no-launch   don't start the app afterwards
#![windows_subsystem = "windows"]

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};

use windows::Win32::Foundation::{CloseHandle, WAIT_OBJECT_0};
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx, IPersistFile};
use windows::Win32::System::Registry::{HKEY, HKEY_CURRENT_USER, REG_DWORD, REG_SZ, RegCloseKey, RegCreateKeyW, RegSetValueExW};
use windows::Win32::System::Threading::{OpenProcess, PROCESS_SYNCHRONIZE, PROCESS_TERMINATE, TerminateProcess, WaitForSingleObject};
use windows::Win32::UI::Shell::{IShellLinkW, ShellLink};
use windows::Win32::UI::WindowsAndMessaging::{FindWindowW, GetWindowThreadProcessId, MB_ICONERROR, MB_OK, MessageBoxW, PostMessageW, WM_CLOSE};
use windows::core::{HSTRING, Interface, PCWSTR, w};

include!(concat!(env!("OUT_DIR"), "/payload.rs"));

const APP_EXE: &str = "BackgroundComputerUse.exe";
const NAME: &str = "Background Computer Use";

fn version() -> &'static str {
    option_env!("BCU_VERSION").unwrap_or(env!("CARGO_PKG_VERSION"))
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |f: &str| args.iter().any(|a| a.eq_ignore_ascii_case(f) || a.eq_ignore_ascii_case(&f.replace("--", "/")));
    let silent = flag("--silent") || flag("/S");
    if let Err(e) = install(!flag("--no-launch")) {
        if !silent {
            unsafe {
                MessageBoxW(None, &HSTRING::from(format!("Couldn't install {NAME}: {e}")), &HSTRING::from(NAME), MB_OK | MB_ICONERROR);
            }
        }
        std::process::exit(1);
    }
}

fn install_dir() -> Result<PathBuf, String> {
    let local = std::env::var_os("LOCALAPPDATA").ok_or("LOCALAPPDATA isn't set")?;
    Ok(PathBuf::from(local).join("Programs").join(NAME))
}

fn install(launch: bool) -> Result<(), String> {
    if FILES.is_empty() {
        return Err("this installer was built without the app".into());
    }
    let dir = install_dir()?;
    quit_running();
    std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0);
    for (rel, bytes) in FILES {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
        }
        write_file(&path, bytes, stamp)?;
    }
    let exe = dir.join(APP_EXE);
    shortcut(&exe, &dir);
    register(&dir, &exe);
    if launch {
        let _ = std::process::Command::new(&exe).current_dir(&dir).creation_flags(0x0000_0008).spawn();
    }
    Ok(())
}

/// Replace a file, even one that's running (an agent's `bcu mcp` keeps
/// bcu.exe open): Windows lets a running exe be renamed, so move it aside
/// as <name>.old-N; the app deletes those once they're free.
fn write_file(path: &Path, bytes: &[u8], stamp: u128) -> Result<(), String> {
    if path.exists() && std::fs::remove_file(path).is_err() {
        let aside = path.with_file_name(format!("{}.old-{stamp}", path.file_name().unwrap_or_default().to_string_lossy()));
        std::fs::rename(path, &aside).map_err(|e| format!("{} is in use: {e}", path.display()))?;
    }
    std::fs::write(path, bytes).map_err(|e| format!("{}: {e}", path.display()))
}

/// Ask the running app to quit (it closes its agents' windows first), and wait for it.
fn quit_running() {
    for _ in 0..3 {
        unsafe {
            let Ok(hwnd) = FindWindowW(w!("BackgroundComputerUseTray"), PCWSTR::null()) else { return };
            let mut pid = 0u32;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            let process = OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_TERMINATE, false, pid).ok();
            let _ = PostMessageW(Some(hwnd), WM_CLOSE, Default::default(), Default::default());
            match process {
                Some(p) => {
                    if WaitForSingleObject(p, 15_000) != WAIT_OBJECT_0 {
                        let _ = TerminateProcess(p, 0);
                        WaitForSingleObject(p, 5_000);
                    }
                    let _ = CloseHandle(p);
                }
                None => std::thread::sleep(std::time::Duration::from_secs(1)),
            }
        }
    }
}

fn shortcut(exe: &Path, dir: &Path) {
    let Some(appdata) = std::env::var_os("APPDATA") else { return };
    let lnk = PathBuf::from(appdata).join(r"Microsoft\Windows\Start Menu\Programs").join(format!("{NAME}.lnk"));
    unsafe {
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
        let Ok(link) = CoCreateInstance::<_, IShellLinkW>(&ShellLink, None, CLSCTX_INPROC_SERVER) else { return };
        let _ = link.SetPath(&HSTRING::from(exe.as_os_str()));
        let _ = link.SetWorkingDirectory(&HSTRING::from(dir.as_os_str()));
        let _ = link.SetDescription(&HSTRING::from(NAME));
        if let Ok(file) = link.cast::<IPersistFile>() {
            let _ = file.Save(&HSTRING::from(lnk.as_os_str()), true);
        }
    }
}

/// The entry in Settings > Apps.
fn register(dir: &Path, exe: &Path) {
    let size_kb: u32 = FILES.iter().map(|(_, b)| b.len() as u64).sum::<u64>().div_ceil(1024) as u32;
    let exe = exe.display().to_string();
    let strings = [
        ("DisplayName", NAME.to_string()),
        ("DisplayVersion", version().to_string()),
        ("Publisher", "Moulik Budhiraja".to_string()),
        ("InstallLocation", dir.display().to_string()),
        ("DisplayIcon", exe.clone()),
        ("UninstallString", format!("\"{exe}\" --uninstall")),
        ("QuietUninstallString", format!("\"{exe}\" --uninstall --silent")),
    ];
    let dwords = [("NoModify", 1u32), ("NoRepair", 1), ("EstimatedSize", size_kb)];
    unsafe {
        let mut key = HKEY::default();
        if RegCreateKeyW(HKEY_CURRENT_USER, w!(r"Software\Microsoft\Windows\CurrentVersion\Uninstall\BackgroundComputerUse"), &mut key).is_err() {
            return;
        }
        for (name, value) in strings {
            let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
            let bytes = std::slice::from_raw_parts(wide.as_ptr() as *const u8, wide.len() * 2);
            let _ = RegSetValueExW(key, &HSTRING::from(name), None, REG_SZ, Some(bytes));
        }
        for (name, value) in dwords {
            let _ = RegSetValueExW(key, &HSTRING::from(name), None, REG_DWORD, Some(&value.to_le_bytes()));
        }
        let _ = RegCloseKey(key);
    }
}
