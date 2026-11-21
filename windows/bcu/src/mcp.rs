//! Minimal MCP server over stdio (newline-delimited JSON-RPC 2.0). Tool calls
//! are forwarded to the running engine (the app's, or a host app's `bcu
//! serve`), which owns the monitor and the windows.
//!
//! Each agent gets a session of its own, subagents included: a Claude Code
//! subagent's or another Codex thread's session is this one's with its ID
//! added (`<session>/<agent>`). Each session's calls run in order on a
//! connection of their own, so one agent waiting never holds up another.

use std::collections::HashMap;
use std::io::{BufRead, Write};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use background_computer_use::tools;
use serde_json::{Map, Value, json};

use crate::pipe::{self, APP_NAME, Client, ToolResult};
use crate::subagents::SubagentLookup;

/// A subagent's or other Codex thread's connection closes after this long
/// without a call. Nothing says when a subagent is done; a call after the
/// close connects again.
const LANE_IDLE: Duration = Duration::from_secs(15 * 60);

pub struct Options {
    /// The host app that shows this session (`--host`).
    pub host: Option<String>,
    /// This agent's session (`--session`), or a random one.
    pub session: Option<String>,
    /// The session's name in the UI (`--label`), instead of the client's.
    pub label: Option<String>,
}

pub struct Server(Arc<Inner>);

struct Inner {
    session_id: String,
    host: Option<String>,
    label: Option<String>,
    /// The agent's name from `initialize` (e.g. "claude-code"), for the tray.
    client_name: Mutex<Option<String>>,
    /// The engine's own tools and instructions, when it has them: a host
    /// app's `bcu` may talk to an engine of another version.
    catalog: Mutex<Option<(Vec<Value>, String)>>,
    lanes: Mutex<HashMap<String, mpsc::Sender<Call>>>,
    /// The lanes' threads, to let their calls finish when stdin closes.
    threads: Mutex<Vec<std::thread::JoinHandle<()>>>,
    subagents: Option<SubagentLookup>,
    /// The first Codex thread seen: the main agent's.
    main_thread: Mutex<Option<String>>,
    out: Mutex<()>,
}

struct Call {
    id: Value,
    name: String,
    args: Map<String, Value>,
}

impl Server {
    pub fn new(o: Options) -> Self {
        Server(Arc::new(Inner {
            session_id: o.session.filter(|s| !s.is_empty()).unwrap_or_else(new_session_id),
            host: o.host.filter(|h| !h.is_empty()),
            label: o.label.filter(|l| !l.trim().is_empty()),
            client_name: Mutex::new(None),
            catalog: Mutex::new(None),
            lanes: Mutex::new(HashMap::new()),
            threads: Mutex::new(Vec::new()),
            subagents: SubagentLookup::from_env(),
            main_thread: Mutex::new(None),
            out: Mutex::new(()),
        }))
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
            if let Some(reply) = self.0.handle(&message) {
                self.0.send(&reply);
            }
        }
        // The client is done sending: answer what it already asked.
        lock(&self.0.lanes).clear();
        for t in std::mem::take(&mut *lock(&self.0.threads)) {
            let _ = t.join();
        }
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

impl Inner {
    fn send(&self, v: &Value) {
        let _one_at_a_time = lock(&self.out);
        let mut out = std::io::stdout().lock();
        let _ = serde_json::to_writer(&mut out, v);
        let _ = out.write_all(b"\n");
        let _ = out.flush();
    }

    fn tools(&self) -> Vec<Value> {
        lock(&self.catalog).as_ref().map(|c| c.0.clone()).unwrap_or_else(tools::tools)
    }

    /// Replies to everything but tool calls, which reply from their session's lane.
    fn handle(self: &Arc<Self>, message: &Map<String, Value>) -> Option<Value> {
        let id = message.get("id")?.clone(); // notifications need no reply
        let method = message.get("method").and_then(Value::as_str).unwrap_or("");
        let params = message.get("params").cloned().unwrap_or(json!({}));
        let result = match method {
            "initialize" => {
                *lock(&self.client_name) = params["clientInfo"]["name"].as_str().map(String::from);
                let version = params["protocolVersion"].as_str().unwrap_or("2025-06-18");
                *lock(&self.catalog) = engine_catalog();
                let instructions = lock(&self.catalog).as_ref().map(|c| c.1.clone()).unwrap_or_else(tools::server_instructions);
                json!({
                    "protocolVersion": version,
                    "capabilities": {"tools": {"listChanged": true}},
                    "serverInfo": {"name": "background-computer-use", "version": background_computer_use::host::version()},
                    "instructions": instructions,
                })
            }
            "ping" => json!({}),
            "tools/list" => json!({"tools": self.tools()}),
            "tools/call" => {
                let name = params["name"].as_str().unwrap_or("").to_string();
                let args = params["arguments"].as_object().cloned().unwrap_or_default();
                // Only the tools this server lists: anything else is answered
                // here, without waiting for the engine.
                if name.starts_with("admin_") || !self.tools().iter().any(|t| t["name"] == json!(name)) {
                    return Some(reply(&id, error_result(&format!("unknown tool {name}"))));
                }
                let session = self.caller(params.get("_meta").and_then(Value::as_object));
                self.lane(&session).send(Call { id, name, args }).ok();
                return None;
            }
            _ => {
                return Some(json!({
                    "jsonrpc": "2.0", "id": id,
                    "error": {"code": -32601, "message": format!("method not found: {method}")},
                }));
            }
        };
        Some(reply(&id, result))
    }

    /// The session a call belongs to: this connection's, or a subagent's.
    fn caller(&self, meta: Option<&Map<String, Value>>) -> String {
        let meta = meta.cloned().unwrap_or_default();
        if let (Some(lookup), Some(tool_use)) = (&self.subagents, meta.get("claudecode/toolUseId").and_then(Value::as_str))
            && let Some(agent) = lookup.agent(tool_use, Duration::from_millis(400))
        {
            return format!("{}/{agent}", self.session_id);
        }
        if let Some(thread) = meta.get("threadId").and_then(Value::as_str) {
            let mut main = lock(&self.main_thread);
            let main = main.get_or_insert_with(|| thread.to_string());
            if thread != main {
                return format!("{}/{thread}", self.session_id);
            }
        }
        self.session_id.clone()
    }

    /// The queue of `session`'s calls, started the first time.
    fn lane(self: &Arc<Self>, session: &str) -> mpsc::Sender<Call> {
        let mut lanes = lock(&self.lanes);
        if let Some(tx) = lanes.get(session) {
            return tx.clone();
        }
        let (tx, rx) = mpsc::channel::<Call>();
        lanes.insert(session.to_string(), tx.clone());
        let me = self.clone();
        let session = session.to_string();
        lock(&self.threads).push(std::thread::spawn(move || me.run_lane(session, rx)));
        tx
    }

    fn run_lane(self: Arc<Self>, session: String, rx: mpsc::Receiver<Call>) {
        let mut client: Option<Client> = None;
        let main = session == self.session_id;
        loop {
            let call = if main {
                match rx.recv() {
                    Ok(c) => c,
                    Err(_) => return,
                }
            } else {
                match rx.recv_timeout(LANE_IDLE) {
                    Ok(c) => c,
                    // Let the connection go; a later call connects again.
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        client = None;
                        continue;
                    }
                    Err(_) => return,
                }
            };
            let result = self.call_with_reconnect(&mut client, &session, &call.name, call.args).unwrap_or_else(|e| {
                ToolResult::error(if self.host.is_some() {
                    format!("{e}. Try again in a moment.")
                } else {
                    format!("{e}. Open {APP_NAME} from the Start menu and finish its setup.")
                })
            });
            let mut content = vec![json!({"type": "text", "text": result.text})];
            for image in result.images {
                content.push(json!({"type": "image", "data": image.data, "mimeType": image.mime}));
            }
            self.send(&reply(&call.id, json!({"content": content, "isError": result.is_error})));
        }
    }

    /// If the engine restarted, the old pipe is dead: reconnect once and retry.
    fn call_with_reconnect(&self, client: &mut Option<Client>, session: &str, name: &str, mut args: Map<String, Value>) -> Result<ToolResult, String> {
        args.insert("_session".into(), json!(session));
        if session != self.session_id {
            args.insert("_parent".into(), json!(self.session_id));
        }
        if let Some(c) = lock(&self.client_name).as_ref() {
            args.insert("_client".into(), json!(c));
        }
        if let Some(h) = &self.host {
            args.insert("_host".into(), json!(h));
        }
        if let Some(l) = &self.label {
            args.insert("_label".into(), json!(l));
        }
        let mut last = String::new();
        for _ in 0..2 {
            if client.is_none() {
                match pipe::connect_or_launch(self.host.is_none()) {
                    Ok(c) => {
                        *client = Some(c);
                        self.refresh_catalog();
                    }
                    Err(e) => {
                        last = e;
                        continue;
                    }
                }
            }
            match client.as_mut().unwrap().call(name, args.clone()) {
                Ok(r) => return Ok(r),
                Err(e) => {
                    *client = None;
                    last = e;
                }
            }
        }
        Err(last)
    }

    /// The engine was down at `initialize`, so the agent got this `bcu`'s own
    /// tool list. Now it's up: fetch the engine's, and tell the client to list
    /// the tools again if they differ.
    fn refresh_catalog(&self) {
        if lock(&self.catalog).is_some() {
            return;
        }
        let Some(fresh) = engine_catalog() else { return };
        let differs = fresh.0 != tools::tools();
        *lock(&self.catalog) = Some(fresh);
        if differs {
            self.send(&json!({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}));
        }
    }
}

fn reply(id: &Value, result: Value) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "result": result})
}

fn error_result(text: &str) -> Value {
    json!({"content": [{"type": "text", "text": text}], "isError": true})
}

/// The running engine's tools and instructions, if it's up and new enough to say.
fn engine_catalog() -> Option<(Vec<Value>, String)> {
    let mut c = Client::connect().ok()?;
    let reply = c.request(json!({"op": "catalog"})).ok()?;
    if reply["ok"] != json!(true) {
        return None;
    }
    Some((reply["tools"].as_array()?.clone(), reply["instructions"].as_str()?.to_string()))
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
