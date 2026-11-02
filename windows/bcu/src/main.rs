//! bcu: command-line front end for Background Computer Use on Windows.
//!   bcu mcp                      stdio MCP server (what agents run)
//!   bcu call <tool> ['<json>']   call one tool and print the result
//!   bcu status                   same as `bcu call status`
//!   bcu tools                    list tool names
//!   bcu connect                  add the MCP server and skill to Claude Code and Codex
//!   bcu install-skill            copy the skill into Claude Code and Codex

mod mcp;
mod pipe;
mod setup;
mod tools;

use serde_json::{Map, Value};

const USAGE: &str = "\
usage:
  bcu mcp                       run the MCP server on stdin/stdout
  bcu call <tool> ['{json}' | key=value ...]
                                call one tool (images are saved to %TEMP%\\bcu-*.png)
  bcu status                    show the app's status
  bcu tools                     list tool names
  bcu connect                   add the MCP server and the skill to Claude Code and Codex
  bcu install-skill             install the skill for Claude Code (~\\.claude\\skills) and Codex (~\\.codex\\skills)
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("mcp") => {
            mcp::Server::new().run();
            0
        }
        Some("call") if args.len() >= 2 => match parse_args(&args[2..]) {
            Ok(tool_args) => call_and_print(&args[1], tool_args),
            Err(e) => {
                eprintln!("bcu: {e}");
                1
            }
        },
        Some("status") => call_and_print("status", Map::new()),
        Some("tools") => {
            for tool in tools::tools() {
                println!("{}", tool["name"].as_str().unwrap_or(""));
            }
            0
        }
        Some("connect") => {
            for line in setup::connect() {
                println!("{line}");
            }
            0
        }
        Some("install-skill") => match setup::install_skill() {
            Ok(paths) => {
                for p in paths {
                    println!("installed {}", p.display());
                }
                0
            }
            Err(e) => {
                eprintln!("bcu: {e}");
                1
            }
        },
        _ => {
            print!("{USAGE}");
            1
        }
    };
    std::process::exit(code);
}

/// Tool arguments: one JSON object, or key=value pairs (a value that parses as
/// JSON, like 5, true or ["ctrl"], is used as JSON; anything else is a string).
/// key=value is easier from PowerShell, which mangles quotes in native arguments.
fn parse_args(rest: &[String]) -> Result<Map<String, Value>, String> {
    if let [one] = rest
        && one.trim_start().starts_with('{')
    {
        return match serde_json::from_str::<Value>(one) {
            Ok(Value::Object(m)) => Ok(m),
            _ => Err("arguments must be a JSON object".into()),
        };
    }
    let mut map = Map::new();
    for pair in rest {
        let (k, v) = pair.split_once('=').ok_or_else(|| format!("expected key=value, got {pair:?}"))?;
        let value = serde_json::from_str::<Value>(v).unwrap_or_else(|_| Value::String(v.to_string()));
        map.insert(k.to_string(), value);
    }
    Ok(map)
}

fn call_and_print(tool: &str, mut args: Map<String, Value>) -> i32 {
    // For scripts that act as more than one agent: BCU_SESSION names the
    // session (its own monitor and windows), BCU_CLIENT the agent.
    for (var, key) in [("BCU_SESSION", "_session"), ("BCU_CLIENT", "_client")] {
        if let Ok(v) = std::env::var(var)
            && !v.is_empty()
        {
            args.entry(key).or_insert(Value::String(v));
        }
    }
    let result = pipe::connect_or_launch().and_then(|mut c| c.call(tool, args));
    match result {
        Ok(r) => {
            println!("{}", r.text);
            for (i, image) in r.images.iter().enumerate() {
                let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
                let path = std::env::temp_dir().join(format!("bcu-{stamp}-{i}.png"));
                if let Some(bytes) = base64_decode(&image.data) {
                    if std::fs::write(&path, bytes).is_ok() {
                        println!("[image saved to {}]", path.display());
                    }
                }
            }
            if r.is_error { 2 } else { 0 }
        }
        Err(e) => {
            eprintln!("bcu: {e}");
            1
        }
    }
}


fn base64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        } as u32)
    }
    let bytes: Vec<u8> = s.bytes().filter(|b| !b.is_ascii_whitespace() && *b != b'=').collect();
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    for chunk in bytes.chunks(4) {
        let mut n = 0u32;
        for (i, &c) in chunk.iter().enumerate() {
            n |= val(c)? << (18 - 6 * i);
        }
        out.push((n >> 16) as u8);
        if chunk.len() > 2 {
            out.push((n >> 8) as u8);
        }
        if chunk.len() > 3 {
            out.push(n as u8);
        }
    }
    Some(out)
}
