//! Embeds the app's files: every file under $BCU_PAYLOAD (the release build
//! puts the signed binaries, install-monitor.ps1 and the skill there). Without
//! it the installer builds empty and refuses to run.
use std::path::{Path, PathBuf};

fn walk(dir: &Path, base: &Path, out: &mut Vec<(String, PathBuf)>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let mut entries: Vec<_> = entries.flatten().collect();
    entries.sort_by_key(|e| e.file_name());
    for e in entries {
        let path = e.path();
        if path.is_dir() {
            walk(&path, base, out);
        } else {
            let rel = path.strip_prefix(base).unwrap().to_string_lossy().replace('/', "\\");
            out.push((rel, path.canonicalize().unwrap()));
        }
    }
}

fn main() {
    println!("cargo:rerun-if-env-changed=BCU_PAYLOAD");
    println!("cargo:rerun-if-env-changed=BCU_VERSION");
    let mut files = Vec::new();
    if let Ok(dir) = std::env::var("BCU_PAYLOAD") {
        let dir = PathBuf::from(dir);
        println!("cargo:rerun-if-changed={}", dir.display());
        walk(&dir, &dir, &mut files);
    }
    let mut code = String::from("pub static FILES: &[(&str, &[u8])] = &[\n");
    for (rel, abs) in &files {
        println!("cargo:rerun-if-changed={}", abs.display());
        code += &format!("    ({rel:?}, include_bytes!({:?})),\n", abs.to_string_lossy());
    }
    code += "];\n";
    std::fs::write(PathBuf::from(std::env::var("OUT_DIR").unwrap()).join("payload.rs"), code).unwrap();
}
