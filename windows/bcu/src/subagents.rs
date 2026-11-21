//! Tells which Claude Code subagent made a tool call (the Mac's
//! SubagentLookup.swift).
//!
//! Subagents run inside their parent's process and share its MCP connection,
//! so every call arrives on the same `bcu mcp`. Claude Code doesn't say which
//! agent a call is from, but it tags each call with its tool-use ID
//! (`_meta["claudecode/toolUseId"]`), and writes that ID to the calling
//! agent's transcript before the call is made: the main agent's at
//! `projects\<dir>\<session>.jsonl`, each subagent's at
//! `projects\<dir>\<session>\subagents\agent-<id>.jsonl`. This reads only what
//! was added to those files since the last call and remembers which file
//! every tool-use ID showed up in.
//!
//! If anything about that layout changes, lookups find nothing and every
//! call counts as the main agent's.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct SubagentLookup {
    projects: PathBuf,
    session: String,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    offsets: HashMap<PathBuf, u64>,
    /// Tool-use ID to subagent ID, or "" for the main agent.
    owners: HashMap<String, String>,
    session_dirs: Vec<PathBuf>,
    last_dir_scan: Option<Instant>,
}

impl SubagentLookup {
    /// None outside Claude Code.
    pub fn from_env() -> Option<SubagentLookup> {
        let session = std::env::var("CLAUDE_CODE_SESSION_ID").ok().filter(|s| !s.is_empty())?;
        let config = std::env::var_os("CLAUDE_CONFIG_DIR")
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("USERPROFILE").map(|h| PathBuf::from(h).join(".claude")))?;
        Some(SubagentLookup { projects: config.join("projects"), session, state: Mutex::new(State::default()) })
    }

    /// The subagent that made the call with this tool-use ID, or None for
    /// the main agent (or when it can't be told). Waits up to `wait` for the
    /// transcript write to land.
    pub fn agent(&self, tool_use: &str, wait: Duration) -> Option<String> {
        let deadline = Instant::now() + wait;
        loop {
            {
                let mut s = self.state.lock().unwrap_or_else(|e| e.into_inner());
                if !s.owners.contains_key(tool_use) {
                    self.scan(&mut s);
                }
                if let Some(owner) = s.owners.get(tool_use) {
                    return (!owner.is_empty()).then(|| owner.clone());
                }
            }
            if Instant::now() >= deadline {
                return None;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn scan(&self, s: &mut State) {
        // The project folder is named after the working directory, mangled;
        // find the one holding this session rather than guess the mangling.
        if s.session_dirs.is_empty() || s.last_dir_scan.is_none_or(|t| t.elapsed() > Duration::from_secs(5)) {
            s.last_dir_scan = Some(Instant::now());
            let main = format!("{}.jsonl", self.session);
            s.session_dirs = std::fs::read_dir(&self.projects)
                .map(|it| it.filter_map(|e| e.ok().map(|e| e.path())).filter(|d| d.join(&main).exists()).collect())
                .unwrap_or_default();
        }
        for dir in s.session_dirs.clone() {
            // Subagents first: their IDs never appear in the main transcript,
            // but read them first anyway so a stray mention can't win.
            if let Ok(files) = std::fs::read_dir(dir.join(&self.session).join("subagents")) {
                for f in files.filter_map(|e| e.ok().map(|e| e.path())) {
                    let name = f.file_name().and_then(|n| n.to_str()).unwrap_or("");
                    if let Some(agent) = name.strip_prefix("agent-").and_then(|n| n.strip_suffix(".jsonl")) {
                        let agent = agent.to_string();
                        read(s, &f, &agent);
                    }
                }
            }
            read(s, &dir.join(format!("{}.jsonl", self.session)), "");
        }
    }
}

/// Note every tool-use ID added to `file` since the last read.
fn read(s: &mut State, file: &Path, owner: &str) {
    let Ok(size) = std::fs::metadata(file).map(|m| m.len()) else { return };
    // A long main transcript: only its recent end can hold a live call.
    let mut offset = s.offsets.get(file).copied().unwrap_or(size.saturating_sub(512_000));
    if offset > size {
        offset = 0;
    }
    if size <= offset {
        return;
    }
    let Ok(mut f) = std::fs::File::open(file) else { return };
    if f.seek(SeekFrom::Start(offset)).is_err() {
        return;
    }
    let mut data = Vec::new();
    if f.take(size - offset).read_to_end(&mut data).is_err() {
        return;
    }
    // Only whole lines; a line still being written is read next time.
    let Some(last) = data.iter().rposition(|&b| b == b'\n') else { return };
    let chunk = &data[..=last];
    s.offsets.insert(file.to_path_buf(), offset + chunk.len() as u64);
    for id in tool_use_ids(chunk) {
        s.owners.entry(id).or_insert_with(|| owner.to_string());
    }
}

/// Every `toolu_…` token in the bytes.
pub fn tool_use_ids(data: &[u8]) -> Vec<String> {
    const PREFIX: &[u8] = b"toolu_";
    let is_id = |b: u8| b.is_ascii_alphanumeric() || b == b'_' || b == b'-';
    let mut ids = Vec::new();
    let mut i = 0;
    while i + PREFIX.len() < data.len() {
        if data[i..].starts_with(PREFIX) {
            let mut j = i + PREFIX.len();
            while j < data.len() && is_id(data[j]) {
                j += 1;
            }
            if j - i > PREFIX.len() + 8
                && let Ok(s) = std::str::from_utf8(&data[i..j])
            {
                ids.push(s.to_string());
            }
            i = j;
        } else {
            i += 1;
        }
    }
    ids
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_tool_use_ids() {
        let ids = tool_use_ids(br#"{"id":"toolu_01ABCdef234567","x":"toolu_short"} toolu_09zz-yy_xx1234"#);
        assert_eq!(ids, vec!["toolu_01ABCdef234567", "toolu_09zz-yy_xx1234"]);
    }

    #[test]
    fn tells_subagents_apart() {
        let root = std::env::temp_dir().join(format!("bcu-subagents-{}", std::process::id()));
        let dir = root.join("projects").join("C--work");
        std::fs::create_dir_all(dir.join("sess").join("subagents")).unwrap();
        std::fs::write(dir.join("sess.jsonl"), "{\"id\":\"toolu_main00000001\"}\n").unwrap();
        std::fs::write(dir.join("sess").join("subagents").join("agent-a1.jsonl"), "{\"id\":\"toolu_sub000000001\"}\n").unwrap();
        let l = SubagentLookup { projects: root.join("projects"), session: "sess".into(), state: Mutex::new(State::default()) };
        assert_eq!(l.agent("toolu_main00000001", Duration::ZERO), None);
        assert_eq!(l.agent("toolu_sub000000001", Duration::ZERO).as_deref(), Some("a1"));
        assert_eq!(l.agent("toolu_unknown00001", Duration::ZERO), None);
        let _ = std::fs::remove_dir_all(root);
    }
}
