//! Client for the app's named pipe. One JSON request or response per line, the
//! same format as the Mac app's unix socket:
//!   request:  {"id": 1, "tool": "click", "args": {...}}
//!   response: {"id": 1, "ok": true, "text": "...", "images": [{"mime": "image/png", "data": "<base64>"}]}
//!             {"id": 1, "ok": false, "error": "..."}

use std::io::{BufRead, BufReader, Write};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

pub const APP_NAME: &str = "Background Computer Use";
pub const APP_EXE: &str = "BackgroundComputerUse.exe";

/// Per user, so two people signed in to the same PC each get their own app.
pub fn pipe_name() -> String {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "user".into());
    format!(r"\\.\pipe\BackgroundComputerUse-{user}")
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
    pub fn connect() -> Result<Client, String> {
        let file = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .open(pipe_name())
            .map_err(|_| format!("{APP_NAME} is not running"))?;
        let writer = file.try_clone().map_err(|e| e.to_string())?;
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
    if let Ok(c) = Client::connect() {
        return Ok(c);
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let app = exe.with_file_name(APP_EXE);
    if !app.exists() {
        return Err(format!("can't find {}", app.display()));
    }
    std::process::Command::new(&app).spawn().map_err(|e| format!("couldn't start {APP_NAME}: {e}"))?;
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if let Ok(c) = Client::connect() {
            return Ok(c);
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    Err(format!("{APP_NAME} is not running"))
}
