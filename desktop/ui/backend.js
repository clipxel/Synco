// What the interface needs from the system, in one place. Inside the Tauri app (Windows,
// Linux) the Rust side runs the engine and Tauri's plugins do dialogs and links; in a plain
// browser (desktop/dev_server.py) it talks to the same engine through a small bridge.
"use strict";

const T = window.__TAURI__;
const inTauri = !!T;

const listeners = {};
let nextId = 1;
const pending = new Map();

function dispatch(line) {
  let msg;
  try { msg = JSON.parse(line); } catch { return; }
  if (msg.id !== undefined && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.ok ? resolve(msg.result) : reject(new Error(msg.error));
  } else if (msg.event) {
    (listeners[msg.event] || []).forEach((fn) => fn(msg));
  }
}

let writeLine;
let ready;

if (inTauri) {
  // The Rust side runs the engine (resources/engine) and relays its lines.
  ready = (async () => {
    await T.event.listen("engine-line", (e) => dispatch(e.payload));
    await T.event.listen("engine-closed", () => (listeners.closed || []).forEach((fn) => fn()));
    await T.core.invoke("engine_start");
    writeLine = (s) => T.core.invoke("engine_write", { line: s });
  })();
} else {
  const source = new EventSource("/events");
  source.onmessage = (e) => dispatch(e.data);
  writeLine = (s) => fetch("/cmd", { method: "POST", body: s });
  ready = Promise.resolve();
}

const backend = {
  inTauri,

  async send(cmd, args = {}) {
    await ready;
    const id = nextId++;
    return new Promise((resolve, reject) => {
      pending.set(id, { resolve, reject });
      writeLine(JSON.stringify({ id, cmd, ...args }));
    });
  },

  on(event, fn) { (listeners[event] ||= []).push(fn); },

  async openXML() {
    if (inTauri) return T.dialog.open({ multiple: false, filters: [{ name: "XML de línea de tiempo", extensions: ["xml"] }] });
    return devDialog("open");
  },
  async saveXML(defaultPath) {
    if (inTauri) return T.dialog.save({ defaultPath, filters: [{ name: "XML", extensions: ["xml"] }] });
    return devDialog("save", { defaultPath });
  },
  async chooseFolder() {
    if (inTauri) return T.dialog.open({ directory: true });
    return devDialog("folder");
  },
  openURL(url) { inTauri ? T.opener.openUrl(url) : window.open(url, "_blank"); },
  reveal(path) { if (inTauri) T.opener.revealItemInDir(path); },

  async version() { return inTauri ? T.app.getVersion() : "dev"; },
  async platform() { return inTauri ? T.core.invoke("platform") : "dev"; },
  /** The running AppImage on Linux, which an update replaces; empty elsewhere. */
  async appImage() { return inTauri ? (await T.core.invoke("app_image").catch(() => "")) : ""; },
  async appPath() { return inTauri ? (await T.core.invoke("app_path").catch(() => "")) : ""; },
  async pid() { return inTauri ? (await T.core.invoke("app_pid").catch(() => 0)) : 0; },
  quit() { if (inTauri) T.process.exit(0); },

  /** Files dropped on the window (Tauri gives their paths). */
  onDrop(fn) {
    if (inTauri && T.webview) {
      T.webview.getCurrentWebview().onDragDropEvent((e) => {
        if (e.payload.type === "drop") fn(e.payload.paths || []);
        if (e.payload.type === "enter" || e.payload.type === "over") document.body.classList.add("dropping");
        if (e.payload.type === "leave" || e.payload.type === "drop") document.body.classList.remove("dropping");
      });
    }
  },
};

async function devDialog(kind, extra = {}) {
  const r = await fetch("/dialog", { method: "POST", body: JSON.stringify({ kind, ...extra }) });
  return (await r.json()).path;
}

window.backend = backend;
