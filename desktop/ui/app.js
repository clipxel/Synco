// Synco for Windows and Linux: the same flow as the macOS app (engine/Sources/SyncApp),
// talking to the same engine (synccli serve) through backend.js.
"use strict";

const $ = (id) => document.getElementById(id);
const B = window.backend;

// MARK: Settings (kept in this computer's app storage)

const defaults = {
  sync: { strictness: "normal", window: 20, band: "voice" },
  export: { syncedLabel: "Blue", approxLabel: "Yellow", unsyncedLabel: "Rose", disableUnsynced: false, sequenceSuffix: " - sincronizado", writeReport: true },
  sound: true, cacheDays: 60, recents: [],
};
function loadPrefs() {
  try {
    const p = JSON.parse(localStorage.getItem("prefs") || "{}");
    return { ...defaults, ...p, sync: { ...defaults.sync, ...p.sync }, export: { ...defaults.export, ...p.export } };
  } catch { return structuredClone(defaults); }
}
let prefs = loadPrefs();
const savePrefs = () => { try { localStorage.setItem("prefs", JSON.stringify(prefs)); } catch {} };

// MARK: State

const S = {
  phase: "empty",          // empty, reading, ready, matching, done, stopped, failed
  project: null, path: null, tracks: [], peaks: {}, durations: {}, problems: {},
  placements: {}, starts: null, report: "", ignored: new Set(), selected: null,
  readDone: 0, readTotal: 0,
};
const busy = () => S.phase === "reading" || S.phase === "matching";
const clipById = (id) => S.project?.clips.find((c) => c.id === id);
const duration = (c) => S.durations[c.id] ?? c.frames / (S.project?.fps || 25);
const quality = (id) => S.placements[id]?.quality;

function message(text, isError = false) {
  $("message").textContent = text;
  $("message").classList.toggle("err", isError);
}

// MARK: Open and read

async function chooseFile() {
  const path = await B.openXML();
  if (path) open(path);
}

async function open(path) {
  if (busy()) await B.send("cancel").catch(() => {});
  try {
    const project = await B.send("open", { path });
    Object.assign(S, { project, path, peaks: {}, durations: {}, problems: {}, placements: {}, starts: null, report: "", ignored: new Set(), selected: null });
    buildTracks();
    prefs.recents = [path, ...prefs.recents.filter((p) => p !== path)].slice(0, 8);
    savePrefs();
    view.fit = true;
    render();
    const missing = project.clips.filter((c) => !c.exists);
    if (missing.length) showPathFixer();
    await read();
  } catch (e) {
    S.phase = "failed";
    message(`No se pudo abrir ${path.split(/[\\/]/).pop()}. ¿Es un XML de Premiere (Final Cut Pro 7 XML)?`, true);
    render();
  }
}

function buildTracks() {
  const order = [], byDevice = {};
  for (const c of S.project.clips) {
    if (!byDevice[c.device]) { order.push(c.device); byDevice[c.device] = []; }
    byDevice[c.device].push(c);
  }
  let cams = 0, recs = 0;
  const rows = order.map((device) => {
    const clips = byDevice[device].sort((a, b) => (a.recordedAt || "").localeCompare(b.recordedAt || "") || a.name.localeCompare(b.name));
    const video = clips.some((c) => c.hasVideo);
    const name = video ? `CÁMARA ${++cams}` : `GRABADOR ${++recs}`;
    return { id: device, kind: video ? "camera" : "recorder", name, folder: `${clips[0].track} · ${clips[0].folder}`, clips };
  });
  S.tracks = [...rows.filter((r) => r.kind === "camera"), ...rows.filter((r) => r.kind === "recorder")];
}

B.on("read", (e) => { S.readDone = e.done; S.readTotal = e.total; renderStatus(); });
B.on("log", (e) => { if (S.phase === "matching") message(e.line.charAt(0).toUpperCase() + e.line.slice(1)); });
// The slow search runs on its own after reading; while the project just sits there, say how it goes.
B.on("ahead", (e) => {
  if (S.phase !== "ready") return;
  const n = e.line && e.line.match(/(\d+)\/(\d+)/);
  if (e.done) message("Listo para sincronizar: el audio ya está analizado.");
  else if (n) message(`Listo para sincronizar. Analizando el audio de fondo: ${n[1]} de ${n[2]}…`);
});

async function read() {
  S.phase = "reading"; S.readDone = 0; S.readTotal = S.project.clips.length;
  message("Leyendo el audio de los archivos…");
  render();
  try {
    const r = await B.send("read");
    S.durations = r.durations; S.problems = r.problems;
    S.peaks = {};
    for (const [id, b64] of Object.entries(r.peaks)) S.peaks[id] = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
    S.phase = "ready";
    const failed = Object.keys(r.problems).length, images = S.project.skippedImages.length;
    let m = failed ? `Listo. ${failed} archivo(s) sin audio legible: se van a ubicar por su hora.` : "Listo para sincronizar.";
    if (images) m += ` ${images} imagen(es) quedan como están: no tienen sonido.`;
    message(m);
    return true;
  } catch (e) {
    S.phase = "stopped";
    message("Lectura detenida.");
    return false;
  } finally { render(); }
}

// MARK: Sync

async function synchronize() {
  if (!S.project || busy()) return;
  if (S.phase === "stopped" || Object.keys(S.durations).length + Object.keys(S.problems).length < S.project.clips.length) {
    if (!(await read())) return;
  }
  S.phase = "matching";
  message("Buscando coincidencias de audio…");
  render();
  try {
    const r = await B.send("sync", { options: prefs.sync, ignoring: [...S.ignored] });
    S.placements = Object.fromEntries(r.placements.map((p) => [p.id, p]));
    S.starts = r.starts;
    S.report = r.report;
    S.phase = "done";
    let m = `${r.synced} de ${r.placements.length} clips sincronizados por audio en ${Math.round(r.seconds)} s. Verificación: ${r.agreed} de ${r.checks} pares a 1 cuadro o menos.`;
    if (r.overlaps) m += ` ${r.overlaps} solape(s) a revisar.`;
    if (r.warnings?.length) m = "⚠️ " + r.warnings[0] + " · " + m;
    message(m);
    if (prefs.sound) beep();
  } catch (e) {
    const stopped = /detenida/.test(e.message);
    S.phase = stopped ? "stopped" : "failed";
    message(stopped ? "Sincronización detenida. Podés volver a empezar cuando quieras." : `Falló la sincronización: ${e.message}`, !stopped);
  }
  render();
}

function stop() { B.send("cancel"); }

function beep() {
  try {
    const ctx = new AudioContext(), o = ctx.createOscillator(), g = ctx.createGain();
    o.frequency.value = 880; g.gain.setValueAtTime(0.15, ctx.currentTime); g.gain.exponentialRampToValueAtTime(0.001, ctx.currentTime + 0.5);
    o.connect(g).connect(ctx.destination); o.start(); o.stop(ctx.currentTime + 0.5);
  } catch {}
}

// MARK: Export

async function exportXML(chosen) {
  if (S.phase !== "done") return;
  const base = S.path.replace(/\.xml$/i, "");
  const path = chosen || (await B.saveXML(`${base} - sincronizado.xml`));
  if (!path) return;
  try {
    await B.send("export", { path, options: prefs.export });
    message(`Exportado: ${path.split(/[\\/]/).pop()}. En el editor: Archivo › Importar.`);
    if (!chosen) B.reveal(path);
    return true;
  } catch (e) { message(`No se pudo exportar: ${e.message}`, true); return false; }
}

// MARK: Rendering

const fmtLen = (s) => { const m = Math.floor(s / 60); return m >= 60 ? `${Math.floor(m / 60)} h ${m % 60} min` : m > 0 ? `${m} min ${Math.floor(s) % 60} s` : `${Math.floor(s)} s`; };
const fmtTC = (s) => `${String(Math.floor(s / 3600)).padStart(2, "0")}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${(s % 60).toFixed(2).padStart(5, "0")}`;
const colors = { exact: "#2f6fd6", approximate: "#d9b532", guessed: "#c23b3b" };

function setCounter(id, value, tint) {
  const el = $(id);
  el.querySelector("b").textContent = value;
  el.classList.toggle("zero", !value);
  el.querySelector("b").style.color = value && tint ? tint : "";
}

function render() {
  const p = S.project;
  const has = !!p;
  $("empty").hidden = has;
  $("timeline").hidden = $("zoombar").hidden = $("overview").hidden = !has;
  // Header
  if (has) {
    const badge = { reading: ["leyendo audio", "var(--accent)"], ready: ["sin sincronizar", "var(--muted)"], matching: ["sincronizando", "var(--accent)"],
      done: ["sincronizado", "var(--success)"], stopped: ["detenido", "var(--warning)"], failed: ["error", "var(--danger)"] }[S.phase] || ["", ""];
    $("title").innerHTML = "";
    const parts = [["file", S.path.split(/[\\/]/).pop()], ["meta", "›"], ["meta", p.sequence], ["meta", fmtLen(totalDuration())], ["meta", `${p.fps} cps`]];
    for (const [cls, text] of parts) { const s = document.createElement("span"); s.className = cls; s.textContent = text + " "; $("title").append(s); }
    $("title").className = "";
    $("title").style.cssText = "display:flex;gap:10px;align-items:center;min-width:0";
    const b = document.createElement("span"); b.className = "badge"; b.textContent = badge[0]; b.style.color = badge[1];
    if (badge[0]) $("title").append(b);
  }
  // Counters
  setCounter("c-cams", S.tracks.filter((t) => t.kind === "camera").length);
  setCounter("c-recs", S.tracks.filter((t) => t.kind === "recorder").length);
  setCounter("c-clips", p ? p.clips.length : 0);
  const q = (k) => Object.values(S.placements).filter((x) => x.quality === k).length;
  setCounter("c-exact", q("exact"), colors.exact);
  setCounter("c-approx", q("approximate"), colors.approximate);
  setCounter("c-guessed", S.phase === "done" ? q("guessed") : p ? p.clips.length - q("exact") - q("approximate") : 0, S.phase === "done" ? colors.guessed : null);
  // Buttons
  $("open").classList.toggle("primary", !has);
  $("open").disabled = busy();
  const syncBtn = $("sync");
  syncBtn.disabled = !has;
  syncBtn.querySelector("span").textContent = busy() ? "Detener" : "Sincronizar";
  syncBtn.classList.toggle("primary", has && !busy() && S.phase !== "done");
  $("export").disabled = S.phase !== "done";
  $("export").classList.toggle("primary", S.phase === "done");
  $("report").hidden = S.phase !== "done";
  const missing = p ? p.clips.filter((c) => !c.exists).length : 0;
  $("missing").hidden = !missing;
  $("missing").textContent = `⚠ ${missing} archivo(s) no encontrados`;
  renderStatus();
  renderHeads();
  renderRecents();
  renderInspector();
  draw();
}

function renderStatus() {
  $("l-read").classList.toggle("on", S.phase === "reading");
  $("l-match").classList.toggle("on", S.phase === "matching");
  const pr = $("progress");
  pr.hidden = !busy();
  if (S.phase === "reading" && S.readTotal) { pr.max = S.readTotal; pr.value = S.readDone; } else pr.removeAttribute("value");
}

function renderRecents() {
  const box = $("recents");
  box.innerHTML = "";
  if (!prefs.recents.length) return;
  const t = document.createElement("small"); t.textContent = "Recientes"; box.append(t);
  for (const path of prefs.recents) {
    const b = document.createElement("button");
    const name = path.split(/[\\/]/).pop();
    b.innerHTML = `<b></b><span></span>`;
    b.querySelector("b").textContent = name;
    b.querySelector("span").textContent = path.slice(0, path.length - name.length);
    b.onclick = () => open(path);
    box.append(b);
  }
}

// MARK: Timeline

const view = { start: 0, pps: 0, fit: true, hover: null, rowH: 70 };

function startOf(c, track) {
  if (S.starts && S.starts[c.id] !== undefined) return S.starts[c.id] / S.project.fps;
  let t = 0;
  for (const x of track.clips) { if (x === c) return t; t += duration(x); }
  return t;
}
function totalDuration() {
  let end = 0;
  for (const t of S.tracks) for (const c of t.clips) end = Math.max(end, startOf(c, t) + duration(c));
  return end;
}
function lanesWidth() { return $("lanes").clientWidth; }
function fitPPS() { return lanesWidth() / Math.max(totalDuration(), 1); }

function renderHeads() {
  const heads = $("heads");
  heads.innerHTML = "";
  const h = $("lanes").clientHeight || 300;
  view.rowH = Math.max(56, h / Math.max(S.tracks.length, 1));
  for (const t of S.tracks) {
    const d = document.createElement("div");
    d.className = "head"; d.style.height = view.rowH + "px";
    d.title = `${t.clips.length} clips en ${t.clips[0].folderPath}`;
    d.innerHTML = `<div>${t.kind === "camera" ? "🎥" : "🎙"}</div><b></b><span></span>`;
    d.querySelector("b").textContent = t.name;
    d.querySelector("span").textContent = t.folder;
    heads.append(d);
  }
}

function draw() {
  const canvas = $("canvas"), lanes = $("lanes");
  if (!S.project || lanes.hidden) return;
  const dpr = window.devicePixelRatio || 1;
  const W = lanes.clientWidth, H = lanes.clientHeight;
  canvas.width = W * dpr; canvas.height = H * dpr;
  canvas.style.width = W + "px"; canvas.style.height = H + "px";
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  if (view.fit) { view.pps = fitPPS(); view.start = 0; }
  const pps = view.pps, rowH = view.rowH;
  S.tracks.forEach((track, row) => {
    const y0 = row * rowH;
    ctx.fillStyle = row % 2 ? "#121417" : "#0b0c0e";
    ctx.fillRect(0, y0, W, rowH);
    ctx.fillStyle = "#30353d"; ctx.fillRect(0, y0 + rowH - 1, W, 1);
    for (const c of track.clips) {
      const x = (startOf(c, track) - view.start) * pps, w = Math.max(1, duration(c) * pps);
      if (x + w < 0 || x > W) continue;
      const q = quality(c.id);
      let fill = !c.exists ? "#b33a3a" : q ? colors[q] : "#5b626d";
      ctx.globalAlpha = S.ignored.has(c.id) ? 0.45 : 1;
      ctx.fillStyle = fill;
      roundRect(ctx, x, y0 + 4, w, rowH - 9, 4); ctx.fill();
      ctx.globalAlpha = 1;
      const ink = q === "approximate" && c.exists ? "#1c1f22" : "#ffffff";
      const peaks = S.peaks[c.id];
      if (peaks && w > 4) {
        const mid = y0 + 4 + (rowH - 9) / 2, half = (rowH - 9) / 2 - 3;
        ctx.fillStyle = ink; ctx.globalAlpha = 0.55;
        for (let px = Math.max(x, 0); px < Math.min(x + w, W); px++) {
          const a = Math.floor(((px - x) / pps) * 10), b = Math.min(peaks.length, Math.max(a + 1, Math.ceil(((px + 1 - x) / pps) * 10)));
          let m = 0; for (let i = a; i < b; i++) m = Math.max(m, peaks[i]);
          const h = (m / 255) * half;
          ctx.fillRect(px, mid - h, 1, Math.max(0.5, 2 * h));
        }
        ctx.globalAlpha = 1;
      }
      const hovered = view.hover && view.hover.id === c.id, selected = S.selected === c.id;
      if (hovered || selected) { ctx.strokeStyle = "#adf802"; ctx.lineWidth = selected ? 2 : 1; roundRect(ctx, x, y0 + 4, w, rowH - 9, 4); ctx.stroke(); }
      if (w > 70) {
        ctx.font = "500 11px " + getComputedStyle(document.body).fontFamily;
        const tw = ctx.measureText(c.name).width;
        if (tw + 8 < w) {
          const cx = Math.min(Math.max(x + w / 2, tw / 2 + 6), W - tw / 2 - 6);
          ctx.fillStyle = ink; ctx.textAlign = "center";
          ctx.fillText(c.name, Math.min(Math.max(cx, x + tw / 2 + 4), x + w - tw / 2 - 4), y0 + 17);
        }
      }
    }
  });
  // Overview and scale
  const total = Math.max(totalDuration(), 1), visible = W / pps;
  const ov = $("overview").clientWidth;
  $("overview-thumb").style.left = (view.start / total) * ov + "px";
  $("overview-thumb").style.width = Math.max(8, Math.min(1, visible / total) * ov) + "px";
  $("scale").textContent = pps >= 1 ? `${Math.round(pps)} px/s` : `${Math.round(1 / pps)} s por punto`;
}

function roundRect(ctx, x, y, w, h, r) {
  r = Math.min(r, w / 2, h / 2);
  ctx.beginPath(); ctx.moveTo(x + r, y); ctx.arcTo(x + w, y, x + w, y + h, r); ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r); ctx.arcTo(x, y, x + w, y, r); ctx.closePath();
}

function clipAt(px, py) {
  const row = Math.floor(py / view.rowH), track = S.tracks[row];
  if (!track) return null;
  const t = view.start + px / view.pps;
  return track.clips.find((c) => { const s = startOf(c, track); return t >= s && t <= s + duration(c); }) || null;
}

function setZoom(pps) {
  const fit = fitPPS(), W = lanesWidth();
  const center = view.start + W / 2 / view.pps;
  const next = Math.min(200, Math.max(fit, pps));
  view.fit = next <= fit * 1.001;
  view.pps = view.fit ? fit : next;
  view.start = view.fit ? 0 : Math.max(0, center - W / 2 / next);
  draw();
}

function methodText(p) {
  switch (p.method) {
    case "reference": return "referencia (grabador principal)";
    case "audio": return `por audio · z ${p.z.toFixed(1)}`;
    case "audioNear": return `${p.note === "entre sus vecinos" ? "por audio, entre sus vecinos" : "por audio, cerca de su hora"} · z ${p.z.toFixed(1)}`;
    case "clock": return p.note.includes("orden") ? "sin audio en común: entre sus vecinos, por fecha y hora" : "sin audio en común: por la hora del archivo";
    default: return "sin ubicar: al final";
  }
}

function showTip(c, x, y) {
  const tip = $("tip");
  const p = S.placements[c.id];
  const lines = [`<b></b>`];
  tip.innerHTML = "";
  const title = document.createElement("b"); title.textContent = c.name; tip.append(title);
  const add = (t, color) => { const d = document.createElement("div"); d.textContent = t; if (color) d.style.color = color; tip.append(d); };
  if (c.recordedAt) add(new Date(c.recordedAt).toLocaleString());
  add(fmtLen(duration(c)));
  if (p) { add(methodText(p), colors[p.quality]); if (p.clockError !== undefined) add(`${p.clockError >= 0 ? "+" : ""}${p.clockError.toFixed(2)} s respecto de su hora`); }
  if (!c.exists) add("archivo no encontrado", "var(--danger)");
  if (S.ignored.has(c.id)) add("marcado como mal sincronizado", "var(--warning)");
  tip.hidden = false;
  tip.style.left = Math.min(x + 12, lanesWidth() - 280) + "px";
  tip.style.top = y + 14 + "px";
}

function renderInspector() {
  const box = $("inspector");
  box.innerHTML = "";
  const c = S.selected && clipById(S.selected);
  if (!c) {
    const s = document.createElement("span"); s.className = "muted";
    s.textContent = S.project ? "Hacé clic en un clip para ver cómo se ubicó. Arrastrá para moverte; Ctrl + rueda o los botones para acercar." : "";
    box.append(s);
    return;
  }
  const p = S.placements[c.id];
  const add = (text, cls, color) => { const s = document.createElement(cls === "b" ? "b" : "span"); if (cls && cls !== "b") s.className = cls; s.textContent = text; if (color) s.style.color = color; box.append(s); };
  add(c.hasVideo ? "🎥" : "🎙");
  add(c.name, "b");
  add(`${c.track} · ${c.folder}`, "muted");
  add(fmtLen(duration(c)), "muted");
  if (p) add(methodText(p), "", colors[p.quality]);
  if (p && S.starts && S.starts[c.id] !== undefined) add(`en ${fmtTC(S.starts[c.id] / S.project.fps)}`, "muted");
  if (!c.exists) add("archivo no encontrado", "", "var(--danger)");
  const sp = document.createElement("div"); sp.className = "spacer"; box.append(sp);
  const fix = document.createElement("button"); fix.className = "small-btn";
  fix.textContent = S.ignored.has(c.id) ? "Deshacer corrección" : "Está mal: ubicarlo por su hora";
  fix.title = "Deja de usar el audio de este clip y lo ubica por la hora del archivo. Se aplica al volver a sincronizar.";
  fix.disabled = busy();
  fix.onclick = () => { S.ignored.has(c.id) ? S.ignored.delete(c.id) : S.ignored.add(c.id); render(); };
  box.append(fix);
  if (B.inTauri) {
    const reveal = document.createElement("button"); reveal.className = "small-btn"; reveal.textContent = "Mostrar en la carpeta";
    reveal.disabled = !c.exists; reveal.onclick = () => B.reveal(c.path); box.append(reveal);
  }
}

// Mouse: drag pans, Ctrl + wheel zooms, wheel scrolls sideways, click selects.
let drag = null;
$("lanes").addEventListener("mousedown", (e) => { drag = { x: e.offsetX, start: view.start, moved: false }; });
window.addEventListener("mouseup", (e) => {
  if (drag && !drag.moved && e.target === $("canvas")) { S.selected = clipAt(e.offsetX, e.offsetY)?.id || null; renderInspector(); draw(); }
  drag = null;
});
$("lanes").addEventListener("mousemove", (e) => {
  if (drag) {
    if (Math.abs(e.offsetX - drag.x) > 3) drag.moved = true;
    if (!view.fit && drag.moved) { view.start = Math.max(0, drag.start - (e.offsetX - drag.x) / view.pps); draw(); }
  }
  const c = clipAt(e.offsetX, e.offsetY);
  view.hover = c;
  c ? showTip(c, e.offsetX, e.offsetY) : ($("tip").hidden = true);
  draw();
});
$("lanes").addEventListener("mouseleave", () => { view.hover = null; $("tip").hidden = true; draw(); });
$("lanes").addEventListener("wheel", (e) => {
  e.preventDefault();
  if (e.ctrlKey || e.metaKey) { setZoom(view.pps * (e.deltaY < 0 ? 1.25 : 0.8)); return; }
  if (view.fit) return;
  const delta = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.deltaY;
  const max = Math.max(0, totalDuration() - lanesWidth() / view.pps);
  view.start = Math.min(max, Math.max(0, view.start + delta / view.pps));
  draw();
}, { passive: false });
$("overview").addEventListener("mousedown", (e) => {
  const move = (ev) => {
    const rect = $("overview").getBoundingClientRect(), total = Math.max(totalDuration(), 1), visible = lanesWidth() / view.pps;
    const center = ((ev.clientX - rect.left) / rect.width) * total;
    view.start = Math.min(Math.max(0, total - visible), Math.max(0, center - visible / 2));
    draw();
  };
  move(e);
  window.addEventListener("mousemove", move);
  window.addEventListener("mouseup", () => window.removeEventListener("mousemove", move), { once: true });
});
window.addEventListener("resize", () => { renderHeads(); draw(); });

// MARK: Sheets

function sheet(title, build, onSave) {
  const veil = $("veil");
  veil.innerHTML = "";
  const s = document.createElement("div"); s.className = "sheet";
  const h = document.createElement("h3"); h.textContent = title; s.append(h);
  build(s);
  const row = document.createElement("div"); row.className = "row";
  const close = () => { veil.hidden = true; veil.innerHTML = ""; };
  if (onSave) {
    const cancel = button("Cancelar", close);
    const ok = button("Aceptar", () => { onSave(); close(); render(); }, true);
    row.append(cancel, ok);
  } else row.append(button("Cerrar", close));
  s.append(row);
  veil.append(s);
  veil.hidden = false;
  veil.onclick = (e) => { if (e.target === veil) close(); };
  return { close, el: s };
}
function button(text, fn, primary) { const b = document.createElement("button"); b.className = "btn" + (primary ? " primary" : ""); b.textContent = text; b.onclick = fn; return b; }
function select(parent, label, options, value) {
  const l = document.createElement("label"); l.textContent = label; parent.append(l);
  const s = document.createElement("select");
  for (const [v, t] of options) { const o = document.createElement("option"); o.value = v; o.textContent = t; s.append(o); }
  s.value = String(value); parent.append(s); return s;
}
function check(parent, label, value) {
  const l = document.createElement("label"); l.className = "check";
  const c = document.createElement("input"); c.type = "checkbox"; c.checked = value;
  l.append(c, document.createTextNode(label)); parent.append(l); return c;
}
function note(parent, text) { const p = document.createElement("div"); p.className = "note"; p.textContent = text; parent.append(p); }

function showSyncSettings() {
  let st, band, win;
  sheet("Ajustes de sincronización", (s) => {
    st = select(s, "Exigencia de coincidencia", [["permissive", "Permisiva (más clips, más riesgo de errores)"], ["normal", "Normal"], ["strict", "Estricta (menos clips, casi sin errores)"]], prefs.sync.strictness);
    band = select(s, "Frecuencias que compara", [["voice", "Voz y ambiente (100–1900 Hz)"], ["wide", "Amplia (60–1900 Hz), para música con graves"]], prefs.sync.band);
    win = select(s, "Búsqueda cerca de la hora del archivo", [["10", "±10 s (relojes bien puestos)"], ["20", "±20 s"], ["60", "±60 s (relojes desajustados)"]], prefs.sync.window);
    note(s, "El grabador con más audio se usa de referencia. Cada clip se busca primero en todo el audio, después cerca de donde lo pone la hora de su archivo y entre sus vecinos. Lo que no coincide con nada se ubica por fecha y hora y queda en rojo.");
  }, () => { prefs.sync = { strictness: st.value, band: band.value, window: Number(win.value) }; savePrefs(); });
}

const labels = [["", "sin cambiar"], ["Blue", "azul"], ["Yellow", "amarillo"], ["Rose", "rosa (rojo)"], ["Violet", "violeta"], ["Iris", "lirio"], ["Caribbean", "caribe"],
  ["Lavender", "lavanda"], ["Cerulean", "celeste"], ["Forest", "verde bosque"], ["Mango", "mango"], ["Purple", "púrpura"], ["Teal", "verde azulado"],
  ["Magenta", "magenta"], ["Tan", "beige"], ["Green", "verde"], ["Brown", "marrón"]];

function showExportSettings() {
  let suffix, report, exact, approx, guessed, disable;
  sheet("Ajustes de exportación", (s) => {
    const l = document.createElement("label"); l.textContent = "Agregar al nombre de la secuencia"; s.append(l);
    suffix = document.createElement("input"); suffix.type = "text"; suffix.value = prefs.export.sequenceSuffix; s.append(suffix);
    report = check(s, "Guardar un informe (.md) junto al XML", prefs.export.writeReport);
    exact = select(s, "Exactos: encontrados por su audio", labels, prefs.export.syncedLabel);
    approx = select(s, "Aproximados: por audio, buscando cerca de su fecha y sus vecinos", labels, prefs.export.approxLabel);
    guessed = select(s, "No encontrados: ubicados por fecha, hora y vecinos", labels, prefs.export.unsyncedLabel);
    disable = check(s, "Deshabilitar los no encontrados en la línea de tiempo", prefs.export.disableUnsynced);
    note(s, "Apagado (lo normal): quedan habilitados, marcados solo con su color.");
  }, () => {
    prefs.export = { sequenceSuffix: suffix.value, writeReport: report.checked, syncedLabel: exact.value, approxLabel: approx.value, unsyncedLabel: guessed.value, disableUnsynced: disable.checked };
    savePrefs();
  });
}

function showPathFixer() {
  const missing = S.project.clips.filter((c) => !c.exists);
  sheet("Archivos no encontrados", (s) => {
    if (!missing.length) { note(s, "Todos los archivos del proyecto están en su lugar."); return; }
    note(s, "Elegí la carpeta donde están ahora: se buscan por nombre en ella y en sus subcarpetas, y se corrigen todos los que aparezcan.");
    const ul = document.createElement("ul"); ul.className = "files";
    for (const c of missing) { const li = document.createElement("li"); li.textContent = c.name; const sm = document.createElement("small"); sm.textContent = c.folderPath; li.append(sm); ul.append(li); }
    s.append(ul);
    const result = document.createElement("div"); result.className = "note";
    s.append(button("Buscar en una carpeta…", async () => {
      const folder = await B.chooseFolder();
      if (!folder) return;
      const r = await B.send("relink", { folder });
      result.textContent = r.found ? `Se encontraron ${r.found}.` : "No apareció ninguno en esa carpeta.";
      if (r.found) { S.project = r.project; buildTracks(); S.placements = {}; S.starts = null; render(); read(); }
    }), result);
    note(s, "Los faltantes igual se pueden sincronizar: quedan al final, marcados.");
  });
}

function showReport() {
  sheet("Informe de la sincronización", (s) => {
    const pre = document.createElement("pre"); pre.textContent = S.report; s.append(pre);
    s.append(button("Copiar", () => navigator.clipboard.writeText(S.report)));
  });
}

async function showGeneral() {
  let size = 0;
  try { size = (await B.send("cacheSize")).bytes; } catch {}
  const mb = (b) => b > 1e9 ? (b / 1e9).toFixed(1) + " GB" : Math.round(b / 1e6) + " MB";
  let sound, days, info;
  const version = await B.version();
  sheet(`Synco ${version}`, (s) => {
    note(s, "Synco es gratis y siempre lo va a ser. Tu aporte ayuda a seguir mejorándolo.");
    const r = document.createElement("div"); r.className = "row"; r.style.justifyContent = "flex-start";
    r.append(button("Donar", () => B.openURL(LINKS.donate), true), button("Instagram @nanobrunetti", () => B.openURL(LINKS.instagram)),
      button("Reportar un problema…", reportProblem), button("Buscar actualizaciones…", () => checkUpdate(false)));
    s.append(r);
    sound = check(s, "Hacer un sonido cuando termina la sincronización", prefs.sound);
    info = document.createElement("div"); info.className = "note";
    info.textContent = `El audio leído se guarda para que volver a sincronizar tarde segundos. Ocupa ${mb(size)}.`;
    s.append(info);
    days = select(s, "Borrar lo que no se use en", [["14", "14 días"], ["30", "30 días"], ["60", "60 días"], ["180", "180 días"]], prefs.cacheDays);
    const r2 = document.createElement("div"); r2.className = "row"; r2.style.justifyContent = "flex-start";
    r2.append(button("Borrar lo viejo ahora", async () => { const x = await B.send("clearCache", { days: Number(days.value) }); info.textContent = `Ahora ocupa ${mb(x.bytes)}.`; }),
      button("Borrar todo", async () => { const x = await B.send("clearCache", {}); info.textContent = `Ahora ocupa ${mb(x.bytes)}.`; }));
    s.append(r2);
  }, () => { prefs.sound = sound.checked; prefs.cacheDays = Number(days.value); savePrefs(); });
}

// MARK: Contact

const LINKS = {
  instagram: "https://www.instagram.com/nanobrunetti/",
  chat: "https://ig.me/m/nanobrunetti",
  donate: "https://onetouch.astropay.com/payment?external_reference_id=AERRP6sKfsrGdRunEEa6gJ7V5fQ1E0gO",
  site: "https://clipxel.github.io/Synco/",
};
async function reportProblem() {
  const text = `Synco\nSynco ${await B.version()} · ${await B.platform()}\n\nQué pasó / qué te gustaría:\n`;
  try { await navigator.clipboard.writeText(text); } catch {}
  B.openURL(LINKS.chat);
}

// MARK: Updates (the same update.json as the macOS app)

const U = { info: null, step: "", progress: 0 };
B.on("update", (e) => { U.step = e.step; U.progress = e.progress; renderUpdate(); });

async function checkUpdate(quiet) {
  try {
    const r = await B.send("checkUpdate", { current: await B.version() });
    if (r.available) { U.info = r; U.step = ""; renderUpdate(); }
    else if (!quiet) updateCard("Synco está al día", "Tenés la última versión.", (c) => {
      const chip = document.createElement("div"); chip.className = "notes"; chip.textContent = `✔ Versión ${"" }`; chip.textContent = "✔ Versión " + (r.version || "");
      c.append(chip);
      c.append(rowOf(button("Listo", closeVeil, true)));
    });
  } catch (e) { if (!quiet) updateCard("No se pudo buscar", "Revisá la conexión a internet.", (c) => c.append(rowOf(button("Cerrar", closeVeil)))); }
}
function closeVeil() { $("veil").hidden = true; $("veil").innerHTML = ""; }
function rowOf(...els) { const r = document.createElement("div"); r.className = "row"; r.style.justifyContent = "flex-end"; r.style.gap = "8px"; r.style.display = "flex"; r.append(...els); return r; }

function updateCard(title, subtitle, build) {
  const veil = $("veil");
  veil.innerHTML = "";
  const c = document.createElement("div"); c.className = "card";
  const top = document.createElement("div"); top.className = "top";
  top.innerHTML = `<img src="icon.png" alt=""><div><h4></h4><div class="sub"></div></div>`;
  top.querySelector("h4").textContent = title; top.querySelector(".sub").textContent = subtitle;
  c.append(top);
  build(c);
  veil.append(c);
  veil.hidden = false;
  veil.onclick = (e) => { if (e.target === veil && !U.step) closeVeil(); };
}

async function renderUpdate() {
  if (!U.info) return;
  const current = await B.version();
  updateCard("Hay una versión nueva", `Synco ${U.info.version} ya está lista para instalar.`, (c) => {
    const chips = document.createElement("div"); chips.className = "chips";
    chips.innerHTML = `<span class="chip"></span><span>→</span><span class="chip new"></span>`;
    chips.children[0].textContent = current; chips.children[2].textContent = U.info.version;
    c.append(chips);
    const lines = (U.info.notes || "").split("\n").map((l) => l.trim()).filter(Boolean);
    if (lines.length) {
      const n = document.createElement("div"); n.className = "notes";
      n.innerHTML = "<small>NOVEDADES</small><ul></ul>";
      for (const l of lines) { const li = document.createElement("li"); li.innerHTML = l.replace(/^[-*] /, "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/\*\*(.+?)\*\*/g, "<b>$1</b>"); n.querySelector("ul").append(li); }
      c.append(n);
    }
    if (U.step) {
      const bar = document.createElement("div"); bar.className = "bar"; bar.innerHTML = `<i style="width:${Math.max(4, U.progress * 100)}%"></i>`;
      const t = document.createElement("div");
      t.textContent = { downloading: "Descargando…", verifying: "Verificando que sea la versión publicada…", installing: "Instalando. Synco se vuelve a abrir sola." }[U.step] || "";
      c.append(bar, t);
    } else {
      const n = document.createElement("div"); n.className = "sub"; n.style.marginBottom = "12px";
      n.textContent = "Se descarga, se verifica y se instala sola en unos segundos. No hace falta reinstalar nada.";
      c.append(n, rowOf(button("Más tarde", () => { U.info = null; closeVeil(); }), button("Actualizar ahora", installUpdate, true)));
    }
  });
}

async function installUpdate() {
  try {
    U.step = "downloading"; U.progress = 0.05; renderUpdate();
    const { file } = await B.send("downloadUpdate");
    U.step = "installing"; U.progress = 1; renderUpdate();
    await B.send("installUpdate", { file, pid: await B.pid(), appImage: await B.appImage(), app: await B.appPath() });
    setTimeout(() => B.quit(), 700);
  } catch (e) {
    U.step = "";
    updateCard("No se pudo actualizar", "Tu versión sigue intacta.", (c) => {
      const n = document.createElement("div"); n.className = "notes"; n.textContent = "⚠ " + e.message; c.append(n);
      c.append(rowOf(button("Cerrar", closeVeil), button("Ir a la página", () => B.openURL(LINKS.site)), button("Reintentar", installUpdate, true)));
    });
  }
}

// MARK: Wiring

$("open").onclick = chooseFile;
$("open-empty").onclick = chooseFile;
$("sync").onclick = () => (busy() ? stop() : synchronize());
$("export").onclick = () => exportXML();
$("sync-settings").onclick = showSyncSettings;
$("export-settings").onclick = showExportSettings;
$("settings").onclick = showGeneral;
$("missing").onclick = showPathFixer;
$("report").onclick = showReport;
$("instagram").onclick = () => B.openURL(LINKS.instagram);
$("donate").onclick = () => B.openURL(LINKS.donate);
$("zoom-in").onclick = () => setZoom(view.pps * 2);
$("zoom-out").onclick = () => setZoom(view.pps / 2);
$("zoom-fit").onclick = () => { view.fit = true; draw(); };
B.onDrop((paths) => { const xml = paths.find((p) => /\.xml$/i.test(p)); if (xml) open(xml); });
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("veil").hidden && !U.step) { closeVeil(); return; }
  if (!(e.ctrlKey || e.metaKey)) return;
  const k = e.key.toLowerCase();
  if (k === "o") { e.preventDefault(); chooseFile(); }
  else if (k === "r") { e.preventDefault(); synchronize(); }
  else if (k === "e") { e.preventDefault(); exportXML(); }
  else if (k === ".") { e.preventDefault(); stop(); }
  else if (k === "+" || k === "=") { e.preventDefault(); setZoom(view.pps * 2); }
  else if (k === "-") { e.preventDefault(); setZoom(view.pps / 2); }
  else if (k === "0") { e.preventDefault(); view.fit = true; draw(); }
});

render();

// Automatic test (CI, dev): ?smoke=<xml> opens, syncs and exports next to it, then reports.
(async () => {
  let smoke = new URLSearchParams(location.search).get("smoke");
  if (!smoke && B.inTauri) smoke = await window.__TAURI__.core.invoke("smoke_xml").catch(() => "");
  if (smoke) {
    await open(smoke);
    await synchronize();
    const out = smoke.replace(/\.xml$/i, "") + " - smoke.xml";
    const ok = S.phase === "done" && (await exportXML(out));
    const summary = { ok: !!ok, phase: S.phase, message: $("message").textContent, out };
    document.title = "SMOKE " + JSON.stringify(summary);
    if (B.inTauri) await window.__TAURI__.core.invoke("smoke_done", { summary: JSON.stringify(summary) }).catch(() => {});
    return;
  }
  if (B.inTauri) setTimeout(() => checkUpdate(true), 3000);
})();
