// Synco for Windows and Linux: the same flow as the macOS app (engine/Sources/SyncApp),
// talking to the same engine (synccli serve) through backend.js.
"use strict";

const $ = (id) => document.getElementById(id);
const B = window.backend;

// MARK: Settings (kept in this computer's app storage)

const defaults = {
  sync: { strictness: "normal", window: 20, band: "voice", speed: "normal" },
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
  drones: [], addingDrone: false,   // drones added after the sync (the extra step)
  syncWhenRead: false,              // Sincronizar pressed while reading: it syncs as soon as that is done
  manual: {},                       // frames each clip was moved by hand after the sync
  playhead: null, playing: false,   // listening to the synced result
  muted: new Set(), solo: null,     // tracks switched off while listening
};
const busy = () => S.phase === "reading" || S.phase === "matching" || S.addingDrone;
/** Sincronizar can be pressed: with nothing running, or while it reads (it waits for it). */
const canSync = () => S.phase === "reading" ? !S.syncWhenRead && !S.addingDrone : !!S.project && !busy();
const droneClips = () => (S.drones || []).flatMap((d) => d.clips);
const clipById = (id) => S.project?.clips.find((c) => c.id === id) || droneClips().find((c) => c.id === id);
const duration = (c) => S.durations[c.id] ?? c.frames / (S.project?.fps || 25);
const quality = (id) => S.placements[id]?.quality;

function message(text, isError = false) {
  $("message").textContent = text;
  $("message").classList.toggle("err", isError);
  $("working-text").textContent = text;
}

// MARK: Open and read

async function chooseFile() {
  const path = await B.openXML();
  if (path) open(path);
}

async function open(path) {
  if (busy()) await B.send("cancel").catch(() => {});
  // A long event takes a while to open: say so right away.
  const name = path.split(/[\\/]/).pop();
  Object.assign(S, { phase: "reading", readDone: 0, readTotal: 0, opening: name });
  message(`Abriendo ${name}…`);
  render();
  try {
    loaded(await B.send("open", { path }));
    await read();
  } catch (e) {
    S.phase = "failed"; S.opening = null; S.syncWhenRead = false;
    message(`No se pudo abrir ${path.split(/[\\/]/).pop()}. ¿Es un XML de Premiere (Final Cut Pro 7 XML)?`, true);
    render();
  }
}

function loaded(project) {
  S.opening = null;
  const path = project.path;
  stopPlayback();
  Object.assign(S, { project, path, peaks: {}, durations: {}, problems: {}, placements: {}, starts: null, report: "", ignored: new Set(), selected: null, drones: [],
    manual: {}, playhead: null, muted: new Set(), solo: null });
  buildTracks();
  prefs.recents = [path, ...prefs.recents.filter((p) => p !== path)].slice(0, 8);
  savePrefs();
  view.fit = true;
  render();
  if (project.clips.some((c) => !c.exists)) showPathFixer();
}

// MARK: Folders dropped on the timeline

async function chooseFolders() {
  const folders = await B.chooseFolders();
  if (folders.length) drop(folders, null);
}

/** Folders and clips dropped on `track` go into it; with no track (below the tracks), each folder
 *  becomes a new track. An editor's XML opens. */
async function drop(paths, track) {
  if (!paths.length || S.phase === "matching") return;
  if (paths.length === 1 && /\.xml$/i.test(paths[0])) return open(paths[0]);
  if (busy()) await B.send("cancel").catch(() => {});
  S.phase = "reading"; S.readDone = 0; S.readTotal = 0;
  message("Armando las pistas…");
  render();
  try {
    const project = await B.send("drop", { paths: paths.filter((p) => !/\.xml$/i.test(p)), track: S.project?.built ? track?.deviceName : null });
    loaded(project);
    const ok = await read();
    if (ok && project.skipped?.length) {
      message(`${$("message").textContent} ${project.skipped.length} archivo(s) sin imagen ni sonido quedaron afuera: ${project.skipped.slice(0, 3).join(", ")}.`);
    }
  } catch (e) {
    S.phase = S.project ? "ready" : "empty";
    S.syncWhenRead = false;
    message(e.message, true);
    render();
  }
}

async function removeTrack(track) {
  if (busy() || !S.project?.built) return;
  const r = await B.send("removeTrack", { track: track.deviceName });
  if (r.closed) {
    Object.assign(S, { project: null, path: null, tracks: [], placements: {}, starts: null, phase: "empty" });
    render();
    return;
  }
  loaded(r);
  await read();
}

/** The track under a point of the page while dragging files: null for the strip below the tracks
 *  (or anywhere else), and always null when the project is an editor's (it takes no files). */
function dropTarget(at) {
  if (!at || !S.project?.built) return null;
  const lanes = $("lanes").getBoundingClientRect(), heads = $("heads").getBoundingClientRect();
  if (at.y < lanes.top || at.y > lanes.bottom || at.x < heads.left || at.x > lanes.right) return null;
  return S.tracks[Math.floor((at.y - lanes.top) / view.rowH)] || null;
}

function dropHover(at) {
  const track = at ? dropTarget(at) : null;
  const inside = at && S.project && document.elementFromPoint(at.x, at.y)?.closest("#timeline, #newtrack");
  view.dropRow = track ? S.tracks.indexOf(track) : null;
  $("newtrack").classList.toggle("target", !!(inside && !track));
  draw();
}

B.on("opening", (e) => {
  if (!S.opening) return;
  S.readDone = e.done; S.readTotal = e.total;
  message(`Abriendo ${S.opening}: ${e.done} de ${e.total} archivos…`);
  render();
});

B.on("build", (e) => {
  S.readDone = e.done; S.readTotal = e.total;
  message(`Armando las pistas: ${e.done} de ${e.total} archivos…`);
  renderStatus();
});

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
    return { id: device, kind: video ? "camera" : "recorder", name, folder: `${clips[0].track} · ${clips[0].deviceName || clips[0].folder}`,
      deviceName: clips[0].deviceName, clips };
  });
  // Drones on top, then cameras, recorders at the bottom, like an editor's timeline.
  const drones = (S.drones || []).map((d) => ({ id: "dron|" + d.name, kind: "drone", name: d.name, folder: `por imagen · ${d.folder}`,
    deviceName: d.name, clips: d.clips }));
  S.tracks = [...drones, ...rows.filter((r) => r.kind === "camera"), ...rows.filter((r) => r.kind === "recorder")];
}

B.on("read", (e) => { S.readDone = e.done; S.readTotal = e.total; renderStatus(); });
B.on("log", (e) => { if (S.phase === "matching" || S.addingDrone) message(e.line.charAt(0).toUpperCase() + e.line.slice(1)); });
// The slow search runs on its own after reading; while the project just sits there, say how it goes.
B.on("ahead", (e) => {
  if (S.phase !== "ready") return;
  const n = e.line && e.line.match(/(\d+)\/(\d+)/);
  if (e.done) message("Listo para sincronizar: el audio ya está analizado.");
  else if (n) message(`Listo para sincronizar. Analizando el audio de fondo: ${n[1]} de ${n[2]}…`);
});

async function read() {
  S.phase = "reading"; S.readDone = 0; S.readTotal = S.project.clips.length;
  message(S.syncWhenRead ? "Sincroniza apenas termine de leer el audio…" : "Leyendo el audio de los archivos…");
  render();
  try {
    const r = await B.send("read", { options: prefs.sync });
    S.durations = r.durations; S.problems = r.problems;
    S.peaks = {};
    for (const [id, b64] of Object.entries(r.peaks)) S.peaks[id] = Uint8Array.from(atob(b64), (ch) => ch.charCodeAt(0));
    S.phase = "ready";
    const failed = Object.keys(r.problems).length, images = S.project.skippedImages.length;
    let m = failed ? `Listo. ${failed} archivo(s) sin audio legible: se van a ubicar por su hora.` : "Listo para sincronizar.";
    if (images) m += ` ${images} imagen(es) quedan como están: no tienen sonido.`;
    message(m);
    // Sincronizar was pressed while it read: now it goes.
    if (S.syncWhenRead) { S.syncWhenRead = false; setTimeout(synchronize, 0); }
    return true;
  } catch (e) {
    S.phase = "stopped";
    message("Lectura detenida.");
    return false;
  } finally { render(); }
}

// MARK: Sync

async function synchronize() {
  if (!canSync()) return;
  // Still opening, building the tracks or reading: it syncs the moment that is done.
  if (S.phase === "reading") {
    S.syncWhenRead = true;
    message("Sincroniza apenas termine de leer el audio…");
    render();
    return;
  }
  if (S.phase === "stopped" || Object.keys(S.durations).length + Object.keys(S.problems).length < S.project.clips.length) {
    if (!(await read())) return;
  }
  S.phase = "matching";
  message("Buscando coincidencias de audio…");
  render();
  try {
    const r = await B.send("sync", { options: prefs.sync, ignoring: [...S.ignored] });
    applyOutcome(r);
    S.phase = "done";
    const audioClips = r.placements.length - droneClips().length;
    let m = `${r.synced} de ${audioClips} clips sincronizados por audio en ${Math.round(r.seconds)} s. Verificación: ${r.agreed} de ${r.checks} pares a 1 cuadro o menos.`;
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

function stop() { S.syncWhenRead = false; stopPlayback(); B.send("cancel"); render(); }

/** What the engine returns after a sync or a drone: every clip's place, and the drone tracks. */
function applyOutcome(r) {
  S.placements = Object.fromEntries(r.placements.map((p) => [p.id, p]));
  S.starts = r.starts;
  S.report = r.report;
  S.drones = r.drones || [];
  S.manual = r.manual || {};
  buildTracks();
}

// MARK: Drones

/** The extra step once synced: a drone's videos (or any camera with no sound), placed by their
 *  time and the light they saw with the cameras. */
async function addDrone(paths) {
  if (S.phase !== "done" || busy()) return;
  paths = paths || (await B.chooseFolders());
  if (!paths.length) return;
  S.addingDrone = true;
  message("Agregando el dron: leyendo la luz de sus tomas…");
  render();
  try {
    const r = await B.send("addDrone", { paths });
    applyOutcome(r);
    const last = S.drones[S.drones.length - 1];
    message(last ? last.summary : "Listo.");
  } catch (e) {
    message(/detenida/.test(e.message) ? "Se dejó de agregar el dron." : `No se pudo agregar el dron: ${e.message}`, !/detenida/.test(e.message));
  } finally { S.addingDrone = false; render(); }
}

async function removeDrone(track) {
  if (busy()) return;
  S.addingDrone = true;
  render();
  try { applyOutcome(await B.send("removeDrone", { name: track.deviceName })); }
  catch (e) { message(e.message, true); }
  finally { S.addingDrone = false; render(); }
}

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
  const name = S.path.split(/[\\/]/).pop().replace(/\.xml$/i, "");
  const folder = S.project.exportFolder || S.path.replace(/[\\/][^\\/]*$/, "");
  const sep = folder.includes("\\") ? "\\" : "/";
  const path = chosen || (await B.saveXML(`${folder}${sep}${name} - sincronizado.xml`));
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
  // Opening or building: what it is doing, in the middle of the screen.
  $("empty").classList.toggle("working", !has && S.phase === "reading");
  $("working-text").textContent = $("message").textContent;
  $("timeline").hidden = $("zoombar").hidden = $("overview").hidden = $("newtrack").hidden = $("ruler").hidden = !has;
  $("newtrack-text").textContent = p?.built ? "Soltá acá una carpeta o clips para crear otra pista" : "Soltá acá carpetas para empezar un proyecto nuevo con ellas";
  // Header
  if (has) {
    const badge = { reading: ["leyendo audio", "var(--accent)"], ready: ["sin sincronizar", "var(--muted)"], matching: ["sincronizando", "var(--accent)"],
      done: ["sincronizado", "var(--success)"], stopped: ["detenido", "var(--warning)"], failed: ["error", "var(--danger)"] }[S.phase] || ["", ""];
    $("title").innerHTML = "";
    const parts = [["file", S.path.split(/[\\/]/).pop()], ["meta", "›"], ["meta", p.sequence], ["meta", fmtLen(totalDuration())], ["meta", `${Number.isInteger(p.fps) ? p.fps : p.fps.toFixed(3).replace(/0+$/, "").replace(".", ",")} cps`]];
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
  const drones = new Set(droneClips().map((c) => c.id));
  const q = (k) => Object.values(S.placements).filter((x) => !drones.has(x.id) && x.quality === k).length;
  setCounter("c-exact", q("exact"), colors.exact);
  setCounter("c-approx", q("approximate"), colors.approximate);
  setCounter("c-guessed", S.phase === "done" ? q("guessed") : p ? p.clips.length - q("exact") - q("approximate") : 0, S.phase === "done" ? colors.guessed : null);
  // Buttons
  $("open").classList.toggle("primary", !has);
  $("open").disabled = busy();
  const syncBtn = $("sync");
  const stops = busy() && !canSync();
  syncBtn.disabled = !has && !canSync();
  syncBtn.querySelector("span").textContent = stops ? "Detener" : "Sincronizar";
  syncBtn.title = S.phase === "reading" && !stops ? "Empieza apenas termine de leer el audio" : "";
  syncBtn.classList.toggle("primary", has && !stops && S.phase !== "done");
  for (const b of $("speed").querySelectorAll("button")) { b.classList.toggle("on", b.dataset.speed === prefs.sync.speed); b.disabled = busy() && S.phase !== "reading"; }
  $("play").hidden = S.phase !== "done";
  $("play").textContent = S.playing ? "❚❚" : "▶";
  $("play").disabled = busy();
  $("playtime").textContent = S.phase === "done" && S.playhead !== null ? fmtTC(S.playhead) : "";
  $("drone").hidden = S.phase !== "done";
  $("drone").disabled = busy();
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

const view = { start: 0, pps: 0, fit: true, hover: null, rowH: 70, dropRow: null };

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
    d.innerHTML = `<div class="controls"><span>${t.kind === "drone" ? "✈" : t.kind === "camera" ? "🎥" : "🎙"}</span></div><b></b><span></span>`;
    if (S.phase === "done" && t.kind !== "drone") {
      const mute = document.createElement("button");
      mute.textContent = S.muted.has(t.id) ? "🔇" : "🔊"; mute.className = S.muted.has(t.id) ? "off" : "";
      mute.title = "Silenciar esta pista al reproducir";
      mute.onclick = () => toggleMute(t);
      const solo = document.createElement("button");
      solo.textContent = "S"; solo.className = S.solo === t.id ? "on" : "";
      solo.title = "Escuchar solo esta pista";
      solo.onclick = () => toggleSolo(t);
      d.querySelector(".controls").append(mute, solo);
    }
    d.oncontextmenu = (e) => { e.preventDefault(); showMenu(e.clientX, e.clientY, trackMenu(t)); };
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
      if (w > 70 && rowH > 0) {
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
  // Where it plays from
  if (S.playhead !== null) {
    const x = (S.playhead - view.start) * pps;
    if (x >= 0 && x <= W) { ctx.fillStyle = "#ef6b6b"; ctx.fillRect(x - 0.75, 0, 1.5, H); }
  }
  // A clip dragged onto another track
  if (drag && drag.moveRow !== undefined && drag.moveRow !== null) {
    ctx.strokeStyle = "#adf802"; ctx.lineWidth = 2; ctx.setLineDash([8, 6]);
    roundRect(ctx, 1, drag.moveRow * rowH + 1, W - 2, rowH - 2, 6); ctx.stroke();
    ctx.setLineDash([]);
  }
  // Where dropped files would go
  if (view.dropRow !== null && view.dropRow !== undefined) {
    ctx.strokeStyle = "#adf802"; ctx.lineWidth = 2; ctx.setLineDash([8, 6]);
    ctx.fillStyle = "rgba(173, 248, 2, .08)";
    roundRect(ctx, 1, view.dropRow * rowH + 1, W - 2, rowH - 2, 6); ctx.fill(); ctx.stroke();
    ctx.setLineDash([]);
  }
  drawRuler(W, pps);
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
    case "light": return `por las luces, contra las cámaras · z ${p.z.toFixed(1)}`;
    case "lightClock": return "por su hora, con el reloj del dron corregido por las luces";
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
    s.textContent = S.project ? "Hacé clic en un clip para ver cómo se ubicó, y con el botón derecho para lo que podés hacer con él. Arrastralo arriba o abajo para pasarlo a otra pista." : "";
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
  const hand = S.manual[c.id] || 0;
  if (hand) add(`corrido a mano ${hand > 0 ? "+" : ""}${hand} cuadro(s)`, "manual");
  const sp = document.createElement("div"); sp.className = "spacer"; box.append(sp);
  const small = (text, title, fn, disabled) => {
    const b = document.createElement("button"); b.className = "small-btn"; b.textContent = text; b.title = title; b.disabled = disabled; b.onclick = fn; box.append(b);
  };
  if (S.starts && S.starts[c.id] !== undefined) {
    small("◀", "Un cuadro antes (Alt+←; con Mayús, diez)", () => nudge(c.id, -1), busy());
    small("▶", "Un cuadro después (Alt+→; con Mayús, diez)", () => nudge(c.id, 1), busy());
  }
  small("Quitar", "Quitar este clip del proyecto (el archivo no se borra) · Supr", () => removeClip(c), busy());
  const fix = document.createElement("button"); fix.className = "small-btn";
  fix.textContent = S.ignored.has(c.id) ? "Deshacer corrección" : "Está mal: ubicarlo por su hora";
  fix.title = "Deja de usar el audio de este clip y lo ubica por la hora del archivo. Se aplica al volver a sincronizar.";
  fix.disabled = busy();
  fix.onclick = () => { S.ignored.has(c.id) ? S.ignored.delete(c.id) : S.ignored.add(c.id); render(); };
  box.append(fix);
  if (B.inTauri) small(revealText(), "", () => B.reveal(c.path), !c.exists);
}

// Mouse: drag pans, Ctrl + wheel zooms, wheel scrolls sideways, click selects.
let drag = null;
$("lanes").addEventListener("mousedown", (e) => {
  if (e.button !== 0 || e.target !== $("canvas")) return;
  drag = { x: e.offsetX, y: e.offsetY, start: view.start, moved: false, clip: clipAt(e.offsetX, e.offsetY), row: Math.floor(e.offsetY / view.rowH) };
});
window.addEventListener("mouseup", (e) => {
  if (drag && drag.moveRow !== null && drag.moveRow !== undefined) {
    const target = S.tracks[drag.moveRow], clip = drag.clip;
    drag = null;
    moveClip(clip, target);
    return;
  }
  if (drag && !drag.moved && e.target === $("canvas")) {
    S.selected = clipAt(e.offsetX, e.offsetY)?.id || null;
    if (S.phase === "done") seek(view.start + e.offsetX / view.pps);
    renderInspector(); draw();
  }
  drag = null;
});
$("lanes").addEventListener("mousemove", (e) => {
  if (drag) {
    if (Math.abs(e.offsetX - drag.x) > 3 || Math.abs(e.offsetY - drag.y) > 3) drag.moved = true;
    // A clip dragged up or down goes to the track it is let go on.
    const row = Math.floor(e.offsetY / view.rowH);
    drag.moveRow = drag.clip && !busy() && row !== drag.row && moveTargets(drag.clip).includes(S.tracks[row]) ? row : null;
    if (drag.moveRow === null && !view.fit && drag.moved && Math.abs(e.offsetX - drag.x) >= Math.abs(e.offsetY - drag.y)) {
      view.start = Math.max(0, drag.start - (e.offsetX - drag.x) / view.pps);
    }
    draw();
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
  }, () => { prefs.sync = { ...prefs.sync, strictness: st.value, band: band.value, window: Number(win.value) }; savePrefs(); });
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
    const u = document.createElement("div"); u.className = "row"; u.style.justifyContent = "space-between"; u.style.alignItems = "center";
    const uv = document.createElement("span"); uv.className = "note"; uv.style.margin = "0";
    uv.textContent = `Tenés la versión ${version}. Synco se fija solo cada vez que lo abrís.`;
    u.append(uv, button("Buscar actualizaciones…", () => checkUpdate(false), true));
    s.append(u);
    const r = document.createElement("div"); r.className = "row"; r.style.justifyContent = "flex-start";
    r.append(button("Donar", () => B.openURL(LINKS.donate)), button("Instagram @nanobrunetti", () => B.openURL(LINKS.instagram)),
      button("Reportar un problema…", reportProblem));
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
      const chip = document.createElement("div"); chip.className = "notes"; chip.textContent = "✔ Versión " + (r.version || "");
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
$("sync").onclick = () => (canSync() ? synchronize() : busy() ? stop() : null);
$("export").onclick = () => exportXML();
$("drone").onclick = () => addDrone();
$("play").onclick = () => togglePlay();
$("sync-settings").onclick = showSyncSettings;
for (const b of $("speed").querySelectorAll("button")) b.onclick = () => { prefs.sync.speed = b.dataset.speed; savePrefs(); render(); };
$("export-settings").onclick = showExportSettings;
$("settings").onclick = showGeneral;
$("missing").onclick = showPathFixer;
$("report").onclick = showReport;
$("instagram").onclick = () => B.openURL(LINKS.instagram);
$("donate").onclick = () => B.openURL(LINKS.donate);
$("zoom-in").onclick = () => setZoom(view.pps * 2);
$("zoom-out").onclick = () => setZoom(view.pps / 2);
$("zoom-fit").onclick = () => { view.fit = true; draw(); };
B.onDrop((paths, at) => drop(paths, dropTarget(at)), dropHover);
$("folders-empty").onclick = chooseFolders;
window.addEventListener("keydown", (e) => {
  if (e.key === "Escape" && !$("menu").hidden) { hideMenu(); return; }
  if (e.key === "Escape" && !$("veil").hidden && !U.step) { closeVeil(); return; }
  // On the timeline (not typing in a field, no sheet open): play, nudge, take out.
  const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement?.tagName || "");
  if (!typing && $("veil").hidden) {
    if (e.key === " " && S.phase === "done") { e.preventDefault(); togglePlay(); return; }
    if (S.selected && e.altKey && (e.key === "ArrowLeft" || e.key === "ArrowRight")) {
      e.preventDefault(); nudge(S.selected, (e.key === "ArrowLeft" ? -1 : 1) * (e.shiftKey ? 10 : 1)); return;
    }
    if (S.selected && (e.key === "Delete" || e.key === "Backspace") && !e.ctrlKey && !e.metaKey) {
      const c = clipById(S.selected); if (c) { e.preventDefault(); removeClip(c); } return;
    }
  }
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

// MARK: By hand, once synced

let platform = "dev";
B.platform().then((p) => { platform = p; });
const revealText = () => (platform === "windows" ? "Mostrar en el Explorador" : "Mostrar en la carpeta");

/** The tracks a clip can move to: others of its kind (a clip with picture only where there is picture). */
function moveTargets(c) {
  if (droneClips().some((d) => d.id === c.id)) return [];
  return S.tracks.filter((t) => t.kind !== "drone" && !t.clips.some((x) => x.id === c.id) && (!c.hasVideo || t.kind === "camera"));
}

/** After taking out or moving a clip: the project as it is now, keeping what was read and synced. */
function edited(r) {
  S.project = r.project;
  if (r.outcome) applyOutcome(r.outcome); else buildTracks();
  render();
}

async function removeClip(c) {
  if (busy() || !c) return;
  stopPlayback();
  try {
    const r = await B.send("removeClip", { clip: c.id });
    if (!r.project.clips.length && !droneClips().length) {
      Object.assign(S, { project: null, path: null, tracks: [], placements: {}, starts: null, phase: "empty" });
      render(); return;
    }
    delete S.peaks[c.id]; S.ignored.delete(c.id);
    if (S.selected === c.id) S.selected = null;
    edited(r);
    message(`Quitado del proyecto: ${c.name}. El archivo sigue en su carpeta; soltalo de nuevo para volver a sumarlo.`);
  } catch (e) { message(e.message, true); }
}

async function moveClip(c, track) {
  if (busy() || !c || !track || !track.clips.length) return;
  try {
    const mate = track.clips[0].name;
    edited(await B.send("moveClip", { clip: c.id, like: track.clips[0].id }));
    message(`${c.name} pasó a la pista de ${mate}. Sigue en el mismo lugar; al volver a sincronizar cuenta como de esa pista.`);
  } catch (e) { message(e.message, true); }
}

async function nudge(id, frames) {
  if (busy() || !S.starts || S.starts[id] === undefined) return;
  const r = await B.send("nudge", { clip: id, frames });
  S.starts = r.starts; S.manual = r.manual || {}; S.report = r.report;
  const c = clipById(id), total = S.manual[id] || 0;
  message(total ? `${c.name}: corrido a mano ${total > 0 ? "+" : ""}${total} cuadro(s). Escuchalo con la barra espaciadora.` : `${c.name}: de nuevo donde lo puso Synco.`);
  render();
  if (S.playing) play();
}

function toggleMute(t) { S.muted.has(t.id) ? S.muted.delete(t.id) : S.muted.add(t.id); render(); if (S.playing) play(); }
function toggleSolo(t) { S.solo = S.solo === t.id ? null : t.id; render(); if (S.playing) play(); }
const mutedClips = () => S.tracks.filter((t) => S.muted.has(t.id) || (S.solo && S.solo !== t.id)).flatMap((t) => t.clips.map((c) => c.id));

// MARK: Right-click menus (the app's own: the browser's never shows)

function showMenu(x, y, items) {
  const menu = $("menu");
  menu.innerHTML = "";
  if (!items.length) { menu.hidden = true; return; }
  const build = (box, list) => {
    for (const it of list) {
      if (it === "-") { box.append(document.createElement("hr")); continue; }
      if (it.sub) {
        const wrap = document.createElement("div"); wrap.className = "sub";
        const b = document.createElement("button"); b.innerHTML = `<span></span><span>›</span>`; b.firstChild.textContent = it.label;
        b.disabled = !!it.disabled;
        const inner = document.createElement("div"); inner.className = "menu";
        build(inner, it.sub);
        wrap.append(b); if (!it.disabled) wrap.append(inner);
        box.append(wrap); continue;
      }
      const b = document.createElement("button");
      b.textContent = it.label; b.disabled = !!it.disabled;
      if (it.danger) b.className = "danger";
      b.onclick = () => { hideMenu(); it.fn(); };
      box.append(b);
    }
  };
  build(menu, items);
  menu.hidden = false;
  const r = menu.getBoundingClientRect();
  menu.style.left = Math.min(x, window.innerWidth - r.width - 4) + "px";
  menu.style.top = Math.min(y, window.innerHeight - r.height - 4) + "px";
}
function hideMenu() { $("menu").hidden = true; }
window.addEventListener("mousedown", (e) => { if (!$("menu").contains(e.target)) hideMenu(); });
window.addEventListener("blur", hideMenu);
// Nowhere shows the browser's menu; where there is nothing to do, nothing shows. Text fields keep theirs (copy, paste).
document.addEventListener("contextmenu", (e) => {
  if (/^(INPUT|TEXTAREA)$/.test(e.target.tagName)) return;
  e.preventDefault();
});

function clipMenu(c, at) {
  const synced = S.phase === "done" && S.starts && S.starts[c.id] !== undefined;
  const isDrone = droneClips().some((d) => d.id === c.id);
  const items = [];
  if (synced) {
    items.push({ label: "Reproducir desde acá", fn: () => { S.selected = c.id; seek(at); play(); }, disabled: busy() });
    items.push({ label: "Correr a mano", disabled: busy(), sub: [
      { label: "1 cuadro antes", fn: () => nudge(c.id, -1) }, { label: "1 cuadro después", fn: () => nudge(c.id, 1) },
      { label: "10 cuadros antes", fn: () => nudge(c.id, -10) }, { label: "10 cuadros después", fn: () => nudge(c.id, 10) },
    ] });
    if (S.manual[c.id]) items.push({ label: "Volver a donde lo puso Synco", fn: () => nudge(c.id, -S.manual[c.id]), disabled: busy() });
  }
  const targets = moveTargets(c);
  if (targets.length) items.push({ label: "Mover a la pista", disabled: busy(), sub: targets.map((t) => ({ label: t.name, fn: () => moveClip(c, t) })) });
  if (!isDrone) {
    items.push({ label: S.ignored.has(c.id) ? "Deshacer: volver a usar su audio" : "Está mal: ubicarlo por su hora", disabled: busy(),
      fn: () => { S.ignored.has(c.id) ? S.ignored.delete(c.id) : S.ignored.add(c.id); render(); } });
  }
  if (items.length) items.push("-");
  if (B.inTauri) {
    items.push({ label: revealText(), fn: () => B.reveal(c.path), disabled: !c.exists });
    items.push({ label: "Abrir el archivo", fn: () => B.openPath(c.path), disabled: !c.exists });
  }
  items.push({ label: "Copiar la ruta del archivo", fn: () => B.copyText(c.path) });
  items.push("-");
  items.push({ label: "Quitar del proyecto", danger: true, fn: () => removeClip(c), disabled: busy() });
  return items;
}

function trackMenu(t) {
  const items = [];
  if (S.phase === "done" && t.kind !== "drone") {
    items.push({ label: S.muted.has(t.id) ? "Volver a escuchar esta pista" : "Silenciar esta pista", fn: () => toggleMute(t) });
    items.push({ label: S.solo === t.id ? "Escuchar todas" : "Escuchar solo esta pista", fn: () => toggleSolo(t) });
    items.push("-");
  }
  if (B.inTauri && t.clips[0]) items.push({ label: revealText(), fn: () => B.reveal(t.clips[0].path), disabled: !t.clips[0].exists });
  if (t.kind === "drone") {
    items.push({ label: "Quitar este dron", danger: true, disabled: busy(),
      fn: () => { if (confirm(`¿Quitar ${t.name}? Los archivos no se tocan.`)) removeDrone(t); } });
  } else if (S.project.built) {
    items.push({ label: "Quitar esta pista", danger: true, disabled: busy(),
      fn: () => { if (confirm(`¿Quitar la pista ${t.name} (${t.deviceName})? Los archivos no se tocan.`)) removeTrack(t); } });
  }
  return items.filter((it, i, all) => !(it === "-" && (i === all.length - 1)));
}

$("lanes").addEventListener("contextmenu", (e) => {
  const c = clipAt(e.offsetX, e.offsetY);
  if (c) showMenu(e.clientX, e.clientY, clipMenu(c, view.start + e.offsetX / view.pps));
});

// MARK: Listening to the synced result

/** The engine makes the sound a stretch at a time (each clip decoded where it plays); Web Audio
 *  plays the stretches back to back, without gaps. A camera's picture follows. */
const CHUNK = 15;
const P = { ctx: null, token: 0, sources: [], anchor: null, raf: 0 };

function togglePlay() { S.playing ? (stopPlayback(), render()) : play(); }

function seek(t) {
  S.playhead = Math.max(0, Math.min(t, totalDuration()));
  if (S.playing) play(); else { showPicture(S.playhead); render(); }
}

async function play() {
  if (S.phase !== "done" || busy()) { message("Para reproducir, primero sincronizá."); return; }
  stopPlayback();
  const token = ++P.token;
  P.ctx = P.ctx || new AudioContext();
  await P.ctx.resume();
  const fps = S.project.fps;
  let from = S.playhead ?? (S.selected && S.starts[S.selected] !== undefined ? S.starts[S.selected] / fps : 0);
  S.playhead = from; S.playing = true; render();
  const muted = mutedClips(), end = totalDuration();
  const fetchChunk = async (at) => {
    const r = await B.send("preview", { from: at, length: CHUNK, muted });
    const bytes = Uint8Array.from(atob(r.wav), (ch) => ch.charCodeAt(0));
    return P.ctx.decodeAudioData(bytes.buffer);
  };
  try {
    let buffer = await fetchChunk(from);
    if (token !== P.token) return;
    let when = P.ctx.currentTime + 0.05, at = from;
    P.anchor = { ctxTime: when, timeline: from };
    const tick = () => {
      if (token !== P.token) return;
      const t = P.anchor.timeline + (P.ctx.currentTime - P.anchor.ctxTime);
      S.playhead = Math.max(from, t);
      if (S.playhead >= end) { stopPlayback(); render(); return; }
      $("playtime").textContent = fmtTC(S.playhead);
      showPicture(S.playhead);
      draw();
      P.raf = requestAnimationFrame(tick);
    };
    P.raf = requestAnimationFrame(tick);
    // Each stretch starts exactly where the one before ends; the next is made while this one plays.
    while (token === P.token && at < end) {
      const src = P.ctx.createBufferSource();
      src.buffer = buffer; src.connect(P.ctx.destination); src.start(when);
      P.sources.push(src);
      when += buffer.duration; at += CHUNK;
      if (at >= end) break;
      while (token === P.token && when - P.ctx.currentTime > 8) await new Promise((r) => setTimeout(r, 250));
      if (token !== P.token) return;
      buffer = await fetchChunk(at);
    }
  } catch (e) {
    if (token === P.token) { stopPlayback(); message(`No se pudo reproducir: ${e.message}`, true); render(); }
  }
}

function stopPlayback() {
  P.token++;
  cancelAnimationFrame(P.raf);
  for (const s of P.sources) { try { s.stop(); } catch {} }
  P.sources = [];
  S.playing = false;
  const v = $("video"); if (v) v.pause();
}

/** The picture at timeline second `t`: the selected clip's track if it has picture there, else the
 *  first track with picture that does. */
function showPicture(t) {
  const box = $("picture"), video = $("video");
  const withPicture = S.tracks.filter((tr) => tr.kind !== "recorder");
  const preferred = withPicture.find((tr) => tr.clips.some((c) => c.id === S.selected));
  let found = null;
  for (const tr of [preferred, ...withPicture].filter(Boolean)) {
    const c = tr.clips.find((c) => { const s = startOf(c, tr); return c.hasVideo && c.exists && t >= s && t < s + duration(c); });
    if (c) { found = { c, offset: t - startOf(c, tr) }; break; }
  }
  if (!found || S.phase !== "done") { box.hidden = true; video.pause(); return; }
  box.hidden = false;
  if (video.dataset.id !== found.c.id) {
    video.dataset.id = found.c.id;
    video.src = B.fileURL(found.c.path);
    $("picture-name").textContent = found.c.name;
    video.onerror = () => { $("picture-name").textContent = `${found.c.name}: este formato de video no se puede mostrar acá (el sonido se escucha igual)`; };
  }
  // Picture follows the sound: put back only when it drifts, so it plays smoothly.
  if (!S.playing || Math.abs(video.currentTime - found.offset) > 0.15) { try { video.currentTime = found.offset; } catch {} }
  if (S.playing && video.paused) video.play().catch(() => {});
  if (!S.playing && !video.paused) video.pause();
}

// MARK: Ruler

function drawRuler(W, pps) {
  const canvas = $("ruler-canvas"), dpr = window.devicePixelRatio || 1, H = 22;
  canvas.width = W * dpr; canvas.height = H * dpr; canvas.style.width = W + "px";
  const ctx = canvas.getContext("2d");
  ctx.scale(dpr, dpr);
  const step = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200].find((s) => s * pps >= 80) || 7200;
  ctx.fillStyle = "#8b929c"; ctx.font = "11px " + getComputedStyle(document.body).fontFamily; ctx.textAlign = "left";
  for (let t = Math.floor(view.start / step) * step; t <= view.start + W / pps; t += step) {
    const x = (t - view.start) * pps, s = Math.round(t);
    ctx.fillRect(x, H - 7, 1, 7);
    const label = s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}`
      : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
    ctx.fillText(label, x + 3, 11);
  }
  if (S.playhead !== null) {
    const x = (S.playhead - view.start) * pps;
    ctx.fillStyle = "#ef6b6b";
    ctx.beginPath(); ctx.moveTo(x - 6, 0); ctx.lineTo(x + 6, 0); ctx.lineTo(x, 9); ctx.fill();
    ctx.fillRect(x - 0.75, 0, 1.5, H);
  }
}

$("ruler-canvas").addEventListener("mousedown", (e) => {
  if (S.phase !== "done" || e.button !== 0) return;
  const wasPlaying = S.playing;
  if (wasPlaying) stopPlayback();
  const at = (ev) => view.start + (ev.clientX - $("ruler-canvas").getBoundingClientRect().left) / view.pps;
  const move = (ev) => { S.playhead = Math.max(0, at(ev)); showPicture(S.playhead); render(); };
  move(e);
  window.addEventListener("mousemove", move);
  window.addEventListener("mouseup", (ev) => { window.removeEventListener("mousemove", move); seek(at(ev)); if (wasPlaying) play(); }, { once: true });
});
