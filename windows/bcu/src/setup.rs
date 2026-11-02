//! Adds the MCP server and the skill to Claude Code and Codex, like the Mac
//! app's setup (Sources/BCUShared/AgentSetup.swift).

use std::path::{Path, PathBuf};
use std::process::Command;

pub const SERVER_NAME: &str = "background-computer-use";
const SKILL_NAME: &str = "background-computer-use";

fn home() -> Result<PathBuf, String> {
    std::env::var_os("USERPROFILE").map(PathBuf::from).ok_or_else(|| "USERPROFILE is not set".into())
}

/// Run every step and describe each one; an agent that isn't installed is skipped.
pub fn connect() -> Vec<String> {
    let mut out = Vec::new();
    let bcu = match std::env::current_exe() {
        Ok(p) => p,
        Err(e) => return vec![format!("can't find bcu.exe: {e}")],
    };
    match add_claude_server(&bcu) {
        Ok(msg) => out.push(msg),
        Err(e) => out.push(format!("Claude Code: {e}")),
    }
    match add_codex_server(&bcu) {
        Ok(msg) => out.push(msg),
        Err(e) => out.push(format!("Codex: {e}")),
    }
    match install_skill() {
        Ok(paths) => out.extend(paths.into_iter().map(|p| format!("installed the skill in {}", p.display()))),
        Err(e) => out.push(format!("skill: {e}")),
    }
    out
}

/// Claude Code rewrites ~/.claude.json while it runs, so the entry is changed through its CLI.
fn add_claude_server(bcu: &Path) -> Result<String, String> {
    // `claude` may be claude.exe or an npm claude.cmd shim, so go through cmd.
    let run = |args: &[&str]| Command::new("cmd").arg("/c").arg("claude").args(args).output();
    match run(&["--version"]) {
        Ok(o) if o.status.success() => {}
        _ => return Err("the claude command isn't installed (skipped)".into()),
    }
    let _ = run(&["mcp", "remove", "--scope", "user", SERVER_NAME]);
    let bcu = bcu.to_string_lossy();
    let o = run(&["mcp", "add", "--scope", "user", SERVER_NAME, "--", &bcu, "mcp"]).map_err(|e| e.to_string())?;
    if !o.status.success() {
        let text = String::from_utf8_lossy(&o.stderr).trim().to_string();
        return Err(if text.is_empty() { format!("claude mcp add failed ({})", o.status) } else { text });
    }
    Ok("added the MCP server to Claude Code".into())
}

fn toml_quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

/// Replace our table in ~/.codex/config.toml, or append it. Other tables are kept.
fn add_codex_server(bcu: &Path) -> Result<String, String> {
    let dir = home()?.join(".codex");
    if !dir.exists() {
        return Err("Codex isn't set up on this PC (no ~/.codex; skipped)".into());
    }
    let path = dir.join("config.toml");
    let text = std::fs::read_to_string(&path).unwrap_or_default();
    let headers = [format!("[mcp_servers.{SERVER_NAME}]"), format!("[mcp_servers.\"{SERVER_NAME}\"]")];
    let table = vec![headers[0].clone(), format!("command = {}", toml_quote(&bcu.to_string_lossy())), "args = [\"mcp\"]".to_string()];
    let mut lines: Vec<String> = if text.is_empty() { Vec::new() } else { text.lines().map(String::from).collect() };
    if let Some(start) = lines.iter().position(|l| headers.contains(&l.trim().to_string())) {
        let mut end = start + 1;
        while end < lines.len() && !lines[end].trim().starts_with('[') {
            end += 1;
        }
        while end > start + 1 && lines[end - 1].trim().is_empty() {
            end -= 1;
        }
        lines.splice(start..end, table);
    } else {
        while lines.last().is_some_and(|l| l.trim().is_empty()) {
            lines.pop();
        }
        if !lines.is_empty() {
            lines.push(String::new());
        }
        lines.extend(table);
    }
    std::fs::write(&path, lines.join("\n") + "\n").map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(format!("added the MCP server to Codex ({})", path.display()))
}

/// The skill ships next to bcu.exe (skills\background-computer-use), or in the repo when run from a checkout.
pub fn install_skill() -> Result<Vec<PathBuf>, String> {
    let exe_dir = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf));
    let cwd = std::env::current_dir().unwrap_or_default();
    let candidates = [
        exe_dir.map(|d| d.join("skills").join(SKILL_NAME)),
        Some(cwd.join("skills").join(SKILL_NAME)),
        Some(cwd.join("..").join("skills").join(SKILL_NAME)),
    ];
    let source = candidates
        .into_iter()
        .flatten()
        .find(|d| d.join("SKILL.md").exists())
        .ok_or("can't find the skill next to this bcu")?;
    let home = home()?;
    let mut out = Vec::new();
    for root in [".claude", ".codex"] {
        if !home.join(root).exists() {
            continue;
        }
        let dest = home.join(root).join("skills").join(SKILL_NAME);
        let _ = std::fs::remove_dir_all(&dest);
        copy_dir(&source, &dest).map_err(|e| format!("{}: {e}", dest.display()))?;
        out.push(dest);
    }
    Ok(out)
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)? {
        let entry = entry?;
        let target = to.join(entry.file_name());
        if entry.file_type()?.is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            std::fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}
