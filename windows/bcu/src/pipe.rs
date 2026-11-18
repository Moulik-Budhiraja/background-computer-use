//! Client for the app's named pipe. One JSON request or response per line, the
//! same format as the Mac app's unix socket:
//!   request:  {"id": 1, "tool": "click", "args": {...}}
//!   response: {"id": 1, "ok": true, "text": "...", "images": [{"mime": "image/png", "data": "<base64>"}]}
//!             {"id": 1, "ok": false, "error": "..."}

use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::AsRawHandle;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};
use windows::Win32::Foundation::{CloseHandle, ERROR_PIPE_BUSY, HANDLE};
use windows::Win32::Security::{EqualSid, GetTokenInformation, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows::Win32::System::Pipes::{GetNamedPipeServerProcessId, WaitNamedPipeW};
use windows::Win32::System::RemoteDesktop::ProcessIdToSessionId;
use windows::Win32::System::Threading::{GetCurrentProcess, GetCurrentProcessId, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION};
use windows::core::HSTRING;

pub const APP_NAME: &str = "Background Computer Use";
pub const APP_EXE: &str = "BackgroundComputerUse.exe";

/// Per user and Windows session, so two people signed in to the same PC (or
/// one person in two sessions) each get their own app.
pub fn pipe_name() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
    format!(r"\\.\pipe\BackgroundComputerUse-{user}-{}", session_of(unsafe { GetCurrentProcessId() }).unwrap_or(0))
}

fn session_of(pid: u32) -> Option<u32> {
    let mut session = 0u32;
    unsafe { ProcessIdToSessionId(pid, &mut session).ok()? };
    Some(session)
}

/// The user a process runs as, as its TOKEN_USER buffer.
fn process_user(process: HANDLE) -> Option<Vec<u8>> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).ok()?;
        let mut len = 0u32;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut len);
        let mut buf = vec![0u8; len as usize];
        let ok = GetTokenInformation(token, TokenUser, Some(buf.as_mut_ptr() as *mut _), len, &mut len);
        let _ = CloseHandle(token);
        ok.ok()?;
        Some(buf)
    }
}

/// Whether the pipe is served by a process of this user in this session.
/// Pipe names are shared by every user on the PC, so another one could have
/// made it first; then this is false and nothing is sent.
fn served_by_us(pipe: &std::fs::File) -> bool {
    unsafe {
        let mut pid = 0u32;
        if GetNamedPipeServerProcessId(HANDLE(pipe.as_raw_handle()), &mut pid).is_err() {
            return false;
        }
        if session_of(pid).is_none() || session_of(pid) != session_of(GetCurrentProcessId()) {
            return false;
        }
        let Ok(server) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
        let theirs = process_user(server);
        let _ = CloseHandle(server);
        let (Some(theirs), Some(ours)) = (theirs, process_user(GetCurrentProcess())) else { return false };
        let theirs = &*(theirs.as_ptr() as *const TOKEN_USER);
        let ours = &*(ours.as_ptr() as *const TOKEN_USER);
        EqualSid(theirs.User.Sid, ours.User.Sid).is_ok()
    }
}

pub enum ConnectError {
    /// Nothing serves the pipe: the app isn't running.
    NotRunning,
    Failed(String),
}

impl From<ConnectError> for String {
    fn from(e: ConnectError) -> String {
        match e {
            ConnectError::NotRunning => format!("{APP_NAME} is not running"),
            ConnectError::Failed(why) => why,
        }
    }
}

pub struct Image {
    pub mime: String,
    pub data: String,
}

pub struct ToolResult {
    pub text: String,
    pub images: Vec<Image>,
    pub is_error: bool,
}

impl ToolResult {
    pub fn error(text: impl Into<String>) -> Self {
        ToolResult { text: text.into(), images: Vec::new(), is_error: true }
    }

    fn from_wire(v: &Value) -> Self {
        if v["ok"].as_bool() == Some(true) {
            let images = v["images"]
                .as_array()
                .map(|list| {
                    list.iter()
                        .filter_map(|img| {
                            Some(Image {
                                mime: img["mime"].as_str().unwrap_or("image/png").to_string(),
                                data: img["data"].as_str()?.to_string(),
                            })
                        })
                        .collect()
                })
                .unwrap_or_default();
            ToolResult { text: v["text"].as_str().unwrap_or("").to_string(), images, is_error: false }
        } else {
            ToolResult::error(v["error"].as_str().unwrap_or("unknown error"))
        }
    }
}

pub struct Client {
    reader: BufReader<std::fs::File>,
    writer: std::fs::File,
    next_id: u64,
}

impl Client {
    pub fn connect() -> Result<Client, ConnectError> {
        let name = pipe_name();
        let deadline = Instant::now() + Duration::from_secs(10);
        let file = loop {
            match std::fs::OpenOptions::new().read(true).write(true).open(&name) {
                Ok(f) => break f,
                // Every instance is taken for a moment, while the app makes
                // the next one: wait for it rather than start a second app.
                Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY.0 as i32) && Instant::now() < deadline => unsafe {
                    let _ = WaitNamedPipeW(&HSTRING::from(name.as_str()), 1000);
                },
                Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY.0 as i32) => {
                    return Err(ConnectError::Failed(format!("{APP_NAME} is busy; try again")));
                }
                Err(_) => return Err(ConnectError::NotRunning),
            }
        };
        if !served_by_us(&file) {
            return Err(ConnectError::Failed(format!(
                "something other than {APP_NAME} for this user holds its connection ({name}), so bcu won't send it anything. Signing out and back in (or restarting the PC) clears it."
            )));
        }
        let writer = file.try_clone().map_err(|e| ConnectError::Failed(e.to_string()))?;
        Ok(Client { reader: BufReader::new(file), writer, next_id: 1 })
    }

    pub fn call(&mut self, tool: &str, args: Map<String, Value>) -> Result<ToolResult, String> {
        let id = self.next_id;
        self.next_id += 1;
        let mut line = serde_json::to_vec(&json!({"id": id, "tool": tool, "args": args})).map_err(|e| e.to_string())?;
        line.push(b'\n');
        self.writer.write_all(&line).map_err(|_| "write failed".to_string())?;
        let mut response = String::new();
        let n = self.reader.read_line(&mut response).map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("the app closed the connection".into());
        }
        let value: Value = serde_json::from_str(&response).map_err(|_| "bad response from the app".to_string())?;
        Ok(ToolResult::from_wire(&value))
    }
}

/// Connect, starting the app (it lives next to bcu.exe) if it isn't running.
pub fn connect_or_launch() -> Result<Client, String> {
    match Client::connect() {
        Ok(c) => return Ok(c),
        Err(ConnectError::NotRunning) => {}
        Err(e) => return Err(e.into()),
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let app = exe.with_file_name(APP_EXE);
    if !app.exists() {
        return Err(format!("can't find {}", app.display()));
    }
    std::process::Command::new(&app).spawn().map_err(|e| format!("couldn't start {APP_NAME}: {e}"))?;
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        match Client::connect() {
            Ok(c) => return Ok(c),
            Err(ConnectError::NotRunning) => {}
            Err(e) => return Err(e.into()),
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(format!("{APP_NAME} is not running"))
}
