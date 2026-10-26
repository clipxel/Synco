// Synco for Windows and Linux: a window for the interface (../ui) and the engine
// (resources/engine/synccli, the same Swift engine as the macOS app) running beside it.
// The interface sends the engine one JSON command per line; every line the engine prints
// comes back to the interface as an "engine-line" event.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::Mutex;
use tauri::{AppHandle, Emitter, Manager, RunEvent, State};

#[derive(Default)]
struct Engine {
    stdin: Mutex<Option<ChildStdin>>,
    child: Mutex<Option<Child>>,
}

#[tauri::command]
fn engine_start(app: AppHandle, engine: State<Engine>) -> Result<(), String> {
    let mut stdin = engine.stdin.lock().unwrap();
    if stdin.is_some() {
        return Ok(());
    }
    let dir = app.path().resource_dir().map_err(|e| e.to_string())?.join("engine");
    let (exe, ffmpeg) = if cfg!(windows) { ("synccli.exe", "ffmpeg.exe") } else { ("synccli", "ffmpeg") };
    let mut cmd = Command::new(dir.join(exe));
    cmd.arg("serve")
        .env("SYNCO_FFMPEG", dir.join(ffmpeg))
        .current_dir(&dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit());
    #[cfg(windows)]
    {
        // A console that is never shown: the engine and the ffmpeg it starts open no windows.
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(0x0800_0000);
    }
    let mut child = cmd.spawn().map_err(|e| format!("no se pudo iniciar el motor: {e}"))?;
    let out = child.stdout.take().unwrap();
    *stdin = child.stdin.take();
    *engine.child.lock().unwrap() = Some(child);
    let app2 = app.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            let _ = app2.emit("engine-line", line);
        }
        let _ = app2.emit("engine-closed", ());
    });
    Ok(())
}

#[tauri::command]
fn engine_write(engine: State<Engine>, line: String) -> Result<(), String> {
    let mut stdin = engine.stdin.lock().unwrap();
    let pipe = stdin.as_mut().ok_or("el motor no está en marcha")?;
    pipe.write_all(line.as_bytes()).and_then(|_| pipe.write_all(b"\n")).and_then(|_| pipe.flush()).map_err(|e| e.to_string())
}

#[tauri::command]
fn platform() -> &'static str {
    if cfg!(windows) { "windows" } else { "linux" }
}

/// The running AppImage (Linux), which an update replaces; empty for other installs.
#[tauri::command]
fn app_image() -> String {
    std::env::var("APPIMAGE").unwrap_or_default()
}

#[tauri::command]
fn app_path() -> String {
    std::env::current_exe().map(|p| p.display().to_string()).unwrap_or_default()
}

#[tauri::command]
fn app_pid() -> u32 {
    std::process::id()
}

/// Automatic test: SYNCO_SMOKE=<project.xml> opens it, syncs and exports, then
/// smoke_done writes the summary to SYNCO_SMOKE_OUT and quits (exit code 1 if it failed).
#[tauri::command]
fn smoke_xml() -> String {
    std::env::var("SYNCO_SMOKE").unwrap_or_default()
}

#[tauri::command]
fn smoke_done(app: AppHandle, summary: String) {
    if let Ok(path) = std::env::var("SYNCO_SMOKE_OUT") {
        let _ = std::fs::write(path, &summary);
    }
    let ok = summary.contains("\"ok\":true");
    app.exit(if ok { 0 } else { 1 });
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_process::init())
        .manage(Engine::default())
        .invoke_handler(tauri::generate_handler![
            engine_start, engine_write, platform, app_image, app_path, app_pid, smoke_xml, smoke_done
        ])
        .build(tauri::generate_context!())
        .expect("no se pudo abrir Synco")
        .run(|app, event| {
            if let RunEvent::Exit = event {
                if let Some(mut child) = app.state::<Engine>().child.lock().unwrap().take() {
                    let _ = child.kill();
                }
            }
        });
}
