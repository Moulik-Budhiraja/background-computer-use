//! The named pipe bcu.exe connects to. One JSON request or response per line,
//! the same format as the Mac app's unix socket. Only the signed-in user (and
//! SYSTEM) may open it, and remote clients are refused.

use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::FromRawHandle;
use std::sync::mpsc;

use serde_json::{Map, Value, json};
use windows::Win32::Foundation::*;
use windows::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows::Win32::Security::{GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, PIPE_ACCESS_DUPLEX};
use windows::Win32::System::Pipes::*;
use windows::Win32::System::Threading::{GetCurrentProcess, OpenProcessToken};
use windows::core::{HSTRING, PCWSTR, PWSTR};

use crate::engine::{self, Request, ToolResult};

pub fn pipe_name() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
    format!(r"\\.\pipe\BackgroundComputerUse-{user}")
}

fn current_user_sid() -> Option<String> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token).ok()?;
        let mut len = 0u32;
        let _ = GetTokenInformation(token, TokenUser, None, 0, &mut len);
        let mut buf = vec![0u8; len as usize];
        let ok = GetTokenInformation(token, TokenUser, Some(buf.as_mut_ptr() as *mut _), len, &mut len);
        let _ = CloseHandle(token);
        ok.ok()?;
        let user = &*(buf.as_ptr() as *const TOKEN_USER);
        let mut s = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut s).ok()?;
        let out = s.to_string().ok();
        let _ = LocalFree(Some(HLOCAL(s.0 as *mut _)));
        out
    }
}

/// Serve the pipe forever, one thread per connection. Each request runs on
/// its agent session's thread.
pub fn serve() -> Result<(), String> {
    let sid = current_user_sid().ok_or("couldn't read the current user's SID")?;
    let sddl = HSTRING::from(format!("D:P(A;;GA;;;{sid})(A;;GA;;;SY)"));
    let mut sd = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(&sddl, SDDL_REVISION_1, &mut sd, None)
            .map_err(|e| format!("pipe security: {e}"))?;
    }
    let attrs = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        lpSecurityDescriptor: sd.0,
        bInheritHandle: false.into(),
    };
    let name = HSTRING::from(pipe_name());
    let mut first = true;
    loop {
        let mut mode = PIPE_ACCESS_DUPLEX;
        if first {
            // Fail if another copy of the app already owns the pipe.
            mode |= FILE_FLAG_FIRST_PIPE_INSTANCE;
        }
        let handle = unsafe {
            CreateNamedPipeW(
                PCWSTR(name.as_ptr()),
                mode,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                PIPE_UNLIMITED_INSTANCES,
                1 << 20,
                1 << 16,
                0,
                Some(&attrs),
            )
        };
        if handle.is_invalid() {
            return Err(if first { "another copy of the app is running".into() } else { "couldn't create the pipe".into() });
        }
        first = false;
        let connected = unsafe { ConnectNamedPipe(handle, None) };
        if connected.is_err() && unsafe { GetLastError() } != ERROR_PIPE_CONNECTED {
            unsafe {
                let _ = CloseHandle(handle);
            }
            continue;
        }
        let raw = handle.0 as usize;
        std::thread::spawn(move || {
            let file = unsafe { std::fs::File::from_raw_handle(raw as *mut _) };
            serve_connection(file);
        });
    }
}

fn serve_connection(file: std::fs::File) {
    let Ok(mut writer) = file.try_clone() else { return };
    let reader = BufReader::new(file);
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let (id, result) = match serde_json::from_str::<Value>(&line) {
            Ok(v) => {
                let id = v.get("id").cloned().unwrap_or(Value::Null);
                let tool = v["tool"].as_str().unwrap_or("").to_string();
                let args: Map<String, Value> = v["args"].as_object().cloned().unwrap_or_default();
                let (tx, rx) = mpsc::channel();
                engine::submit(Request { tool, args, reply: tx });
                (id, rx.recv().unwrap_or_else(|_| ToolResult::error("the app is shutting down")))
            }
            Err(_) => (Value::Null, ToolResult::error("bad request")),
        };
        let mut out = if result.is_error {
            json!({"id": id, "ok": false, "error": result.text})
        } else {
            let mut o = json!({"id": id, "ok": true, "text": result.text});
            if !result.images.is_empty() {
                o["images"] = result.images.iter().map(|i| json!({"mime": i.mime, "data": i.data})).collect();
            }
            o
        };
        let mut bytes = serde_json::to_vec(&out.take()).unwrap_or_default();
        bytes.push(b'\n');
        if writer.write_all(&bytes).is_err() {
            break;
        }
    }
}
