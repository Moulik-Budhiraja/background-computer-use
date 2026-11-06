//! Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Tool calls
//! are forwarded to the running app, which owns the monitor and the windows.

use std::io::{BufRead, Write};

use serde_json::{Map, Value, json};

use crate::pipe::{self, APP_NAME, Client, ToolResult};
use crate::tools;

pub struct Server {
    client: Option<Client>,
    /// This agent's session: its own monitor and windows in the app.
    session_id: String,
    /// The agent's name from `initialize` (e.g. "claude-code"), for the tray.
    client_name: Option<String>,
}

impl Server {
    pub fn new() -> Self {
        Server { client: None, session_id: new_session_id(), client_name: None }
    }

    pub fn run(&mut self) {
        let stdin = std::io::stdin();
        for line in stdin.lock().lines() {
            let Ok(line) = line else { break };
            // Some shells (Windows PowerShell) put a byte-order mark before the first line.
            let line = line.trim_start_matches('\u{feff}');
            if line.trim().is_empty() {
                continue;
            }
            let Ok(Value::Object(message)) = serde_json::from_str::<Value>(line) else { continue };
            if let Some(reply) = self.handle(&message) {
                let mut out = std::io::stdout().lock();
                let _ = serde_json::to_writer(&mut out, &reply);
                let _ = out.write_all(b"\n");
                let _ = out.flush();
            }
        }
    }

    fn handle(&mut self, message: &Map<String, Value>) -> Option<Value> {
        let id = message.get("id")?.clone(); // notifications need no reply
        let method = message.get("method").and_then(Value::as_str).unwrap_or("");
        let params = message.get("params").cloned().unwrap_or(json!({}));
        let result = match method {
            "initialize" => {
                self.client_name = params["clientInfo"]["name"].as_str().map(String::from);
                let version = params["protocolVersion"].as_str().unwrap_or("2025-06-18");
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": false}},
                    "serverInfo": {"name": "background-computer-use", "version": env!("CARGO_PKG_VERSION")},
                    "instructions": tools::server_instructions(),
                })
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": tools::tools()}),
            "tools/call" => {
                let name = params["name"].as_str().unwrap_or("");
                let args = params["arguments"].as_object().cloned().unwrap_or_default();
                self.call_tool(name, args)
            }
            _ => {
                return Some(json!({
                    "jsonrpc": "2.0", "id": id,
                    "error": {"code": -32601, "message": format!("method not found: {method}")},
                }));
            }
        };
        Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
    }

    fn call_tool(&mut self, name: &str, args: Map<String, Value>) -> Value {
        let result = self.call_with_reconnect(name, args).unwrap_or_else(|e| {
            ToolResult::error(format!("{e}. Open {APP_NAME} from the Start menu and finish its setup."))
        });
        let mut content = vec![json!({"type": "text", "text": result.text})];
        for image in result.images {
            content.push(json!({"type": "image", "data": image.data, "mimeType": image.mime}));
        }
        json!({"content": content, "isError": result.is_error})
    }

    /// If the app restarted, the old pipe is dead: reconnect once and retry.
    fn call_with_reconnect(&mut self, name: &str, mut args: Map<String, Value>) -> Result<ToolResult, String> {
        args.insert("_session".into(), json!(self.session_id));
        if let Some(c) = &self.client_name {
            args.insert("_client".into(), json!(c));
        }
        let mut last = String::new();
        for _ in 0..2 {
            if self.client.is_none() {
                match pipe::connect_or_launch() {
                    Ok(c) => self.client = Some(c),
                    Err(e) => {
                        last = e;
                        continue;
                    }
                }
            }
            match self.client.as_mut().unwrap().call(name, args.clone()) {
                Ok(r) => return Ok(r),
                Err(e) => {
                    self.client = None;
                    last = e;
                }
            }
        }
        Err(last)
    }
}

/// Random enough to tell sessions apart; formatted like a UUID for the logs.
fn new_session_id() -> String {
    use std::hash::{BuildHasher, Hasher};
    let mut a = std::collections::hash_map::RandomState::new().build_hasher();
    a.write_u128(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0));
    a.write_u32(std::process::id());
    let mut b = std::collections::hash_map::RandomState::new().build_hasher();
    b.write_u64(a.finish());
    let (x, y) = (a.finish(), b.finish());
    format!(
        "{:08X}-{:04X}-{:04X}-{:04X}-{:012X}",
        x >> 32,
        (x >> 16) & 0xffff,
        x & 0xffff,
        y >> 48,
        y & 0xffff_ffff_ffff
    )
}
