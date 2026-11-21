//! The named pipe bcu.exe and host apps connect to. One JSON request or
//! response per line, the same format as the Mac app's unix socket: a tool
//! call (`{"id", "tool", "args"}`, what `bcu mcp` sends) or a host's request
//! (`{"id", "op", ...}`, see host.rs), and events the engine pushes to hosts.
//! Only the signed-in user (and SYSTEM) may open it, and remote clients are
//! refused.

use std::io::{BufRead, BufReader, Read};
use std::sync::{Arc, mpsc};

use serde_json::{Map, Value, json};
use windows::Win32::Foundation::*;
use windows::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows::Win32::Security::{GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX, ReadFile, WriteFile};
use windows::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};
use windows::Win32::System::Pipes::*;
use windows::Win32::System::Threading::{CreateEventW, GetCurrentProcess, OpenProcessToken};
use windows::core::{HSTRING, PCWSTR, PWSTR};

use crate::engine::{self, Request, ToolResult};
use crate::host::{self, Conn};

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
    serve_then(|| {})
}

/// `serve`, calling `listening` once the pipe is there for clients.
pub fn serve_then(listening: impl FnOnce()) -> Result<(), String> {
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
    let mut listening = Some(listening);
    loop {
        // Overlapped, so a host can be sent events while a read waits for its
        // next request: on a synchronous handle the write would wait for it.
        let mut mode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED;
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
        if let Some(f) = listening.take() {
            f();
        }
        let pipe = Pipe(handle);
        if pipe.accept().is_err() {
            continue;
        }
        std::thread::spawn(move || serve_connection(Arc::new(pipe)));
    }
}

/// A connected instance of the pipe, opened for overlapped I/O: a read and
/// a write can be under way at once, from different threads.
pub struct Pipe(HANDLE);

// The handle is only used through ReadFile, WriteFile and ConnectNamedPipe,
// each with an OVERLAPPED of its own.
unsafe impl Send for Pipe {}
unsafe impl Sync for Pipe {}

impl Pipe {
    /// Wait for a client to connect.
    fn accept(&self) -> windows::core::Result<()> {
        self.wait(|ov| unsafe { ConnectNamedPipe(self.0, Some(ov)) }).map(|_| ())
    }

    /// Run one overlapped operation and wait for it: bytes moved.
    fn wait(&self, start: impl FnOnce(*mut OVERLAPPED) -> windows::core::Result<()>) -> windows::core::Result<u32> {
        unsafe {
            let event = CreateEventW(None, true, false, PCWSTR::null())?;
            let mut ov = OVERLAPPED { hEvent: event, ..Default::default() };
            let mut n = 0u32;
            let result = match start(&mut ov) {
                Ok(()) => GetOverlappedResult(self.0, &ov, &mut n, false),
                Err(e) if e.code() == ERROR_IO_PENDING.to_hresult() => GetOverlappedResult(self.0, &ov, &mut n, true),
                // A client that connected between CreateNamedPipe and ConnectNamedPipe.
                Err(e) if e.code() == ERROR_PIPE_CONNECTED.to_hresult() => Ok(()),
                Err(e) => Err(e),
            };
            let _ = CloseHandle(event);
            result.map(|()| n)
        }
    }

    fn read(&self, buf: &mut [u8]) -> std::io::Result<usize> {
        match self.wait(|ov| unsafe { ReadFile(self.0, Some(buf), None, Some(ov)) }) {
            Ok(n) => Ok(n as usize),
            // The client went away.
            Err(e) if e.code() == ERROR_BROKEN_PIPE.to_hresult() || e.code() == ERROR_PIPE_NOT_CONNECTED.to_hresult() => Ok(0),
            Err(e) => Err(std::io::Error::other(e)),
        }
    }

    /// Write all of `bytes`.
    pub fn write_all(&self, mut bytes: &[u8]) -> std::io::Result<()> {
        while !bytes.is_empty() {
            let n = self.wait(|ov| unsafe { WriteFile(self.0, Some(bytes), None, Some(ov)) }).map_err(std::io::Error::other)?;
            if n == 0 {
                return Err(std::io::ErrorKind::WriteZero.into());
            }
            bytes = &bytes[n as usize..];
        }
        Ok(())
    }
}

impl Drop for Pipe {
    fn drop(&mut self) {
        unsafe {
            let _ = DisconnectNamedPipe(self.0);
            let _ = CloseHandle(self.0);
        }
    }
}

struct Reader(Arc<Pipe>);

impl Read for Reader {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.0.read(buf)
    }
}

fn serve_connection(pipe: Arc<Pipe>) {
    let conn = Conn::new(pipe.clone());
    let reader = BufReader::new(Reader(pipe));
    for line in reader.lines() {
        let Ok(line) = line else { break };
        if line.trim().is_empty() {
            continue;
        }
        let request = match serde_json::from_str::<Value>(&line) {
            Ok(Value::Object(v)) => v,
            _ => {
                conn.send(&json!({"id": Value::Null, "ok": false, "error": "bad request"}));
                continue;
            }
        };
        let id = request.get("id").cloned().unwrap_or(Value::Null);
        // A host's request: answered here, in order with this connection's other lines.
        if let Some(op) = request.get("op").and_then(Value::as_str) {
            let mut reply = host::handle(&conn, op, &request);
            reply["id"] = id;
            conn.send(&reply);
            continue;
        }
        let tool = request.get("tool").and_then(Value::as_str).unwrap_or("").to_string();
        let args: Map<String, Value> = request.get("args").and_then(Value::as_object).cloned().unwrap_or_default();
        let (tx, rx) = mpsc::channel();
        engine::submit(Request { tool, args, reply: tx });
        let result = rx.recv().unwrap_or_else(|_| ToolResult::error("the app is shutting down"));
        let out = if result.is_error {
            json!({"id": id, "ok": false, "error": result.text})
        } else {
            let mut o = json!({"id": id, "ok": true, "text": result.text});
            if !result.images.is_empty() {
                o["images"] = result.images.iter().map(|i| json!({"mime": i.mime, "data": i.data})).collect();
            }
            o
        };
        conn.send(&out);
    }
    host::closed(&conn);
}

// ---------- as a client: is an engine there, and what does it say ----------

const ERROR_PIPE_BUSY_CODE: i32 = 231;

/// Whether an engine serves the pipe (all its instances busy counts).
pub fn engine_running() -> bool {
    match std::fs::OpenOptions::new().read(true).write(true).open(pipe_name()) {
        Ok(_) => true,
        Err(e) => e.raw_os_error() == Some(ERROR_PIPE_BUSY_CODE),
    }
}

/// Send one request line to the engine and wait up to `timeout` for the reply.
pub fn request(req: &Value, timeout: std::time::Duration) -> Result<Value, String> {
    let deadline = std::time::Instant::now() + timeout;
    let file = loop {
        match std::fs::OpenOptions::new().read(true).write(true).open(pipe_name()) {
            Ok(f) => break f,
            Err(e) if e.raw_os_error() == Some(ERROR_PIPE_BUSY_CODE) && std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50));
            }
            Err(e) => return Err(e.to_string()),
        }
    };
    let mut line = serde_json::to_vec(req).map_err(|e| e.to_string())?;
    line.push(b'\n');
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        use std::io::Write;
        let mut writer = &file;
        let result = writer.write_all(&line).map_err(|e| e.to_string()).and_then(|()| {
            let mut reply = String::new();
            BufReader::new(&file).read_line(&mut reply).map_err(|e| e.to_string())?;
            serde_json::from_str::<Value>(&reply).map_err(|_| "no answer".to_string())
        });
        let _ = tx.send(result);
    });
    rx.recv_timeout(deadline.saturating_duration_since(std::time::Instant::now())).map_err(|_| "no answer".to_string())?
}
