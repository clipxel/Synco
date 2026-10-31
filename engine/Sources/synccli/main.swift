import Foundation
import SyncCore

#if os(Windows)
// Microsoft's C library has no line buffering (and stops the program when asked for it with no size).
setvbuf(stdout, nil, _IONBF, 0)
#else
setvbuf(stdout, nil, _IOLBF, 0)
#endif
let args = CommandLine.arguments
let rate = 4000.0
let cache = AudioCache(dir: ProcessInfo.processInfo.environment["SYNCO_CACHE"].map { URL(fileURLWithPath: $0) } ?? defaultCacheDir)

func usage() -> Never {
    print("""
    uso:
      synccli sync <entrada.xml> <salida.xml> [informe.md]   sincroniza un proyecto de Premiere (FCP 7 XML)
      synccli build <salida.xml> <carpeta>...                arma el proyecto desde carpetas: cada carpeta, una pista
      synccli pair <referencia> <clip>                       prueba una sola comparación
      synccli serve                                          motor para la app de Windows y Linux (JSON por stdin/stdout)
      synccli selftest <carpeta>                             proyecto sintético con desfases conocidos: tiene que dar exacto
      synccli times <proyecto.xml>                           hora de grabación de cada archivo (metadatos vs archivo)
      synccli check <sincronizado.xml> [etiqueta]            juzga un XML ya sincronizado (de cualquier app):
                                                             compara el audio de cada par de clips superpuestos
    """)
    exit(2)
}

if args.count >= 2, args[1] == "serve" {
    Server(cache: cache, rate: rate).run()
}
if args.count >= 2, args[1] == "--version" { print(engineVersion); exit(0) }
if args.count >= 3, args[1] == "selftest" {
    let folder = URL(fileURLWithPath: args[2])
    let ok = try Selftest.run(folder: folder, cache: AudioCache(dir: folder.appendingPathComponent("cache")))
    exit(ok ? 0 : 1)
}
guard args.count >= 3 else { usage() }

switch args[1] {
case "build" where args.count >= 4:
    let output = URL(fileURLWithPath: args[2])
    let sources = ProjectBuilder.sources(from: args[3...].map { URL(fileURLWithPath: $0) })
    for s in sources { print("pista \(s.name): \(s.files.count) archivos (\(s.folder.path))") }
    let skipped = try ProjectBuilder.build(sources, name: output.deletingPathExtension().lastPathComponent, to: output)
    for f in skipped { print("sin imagen ni sonido, se deja afuera: \(f.lastPathComponent)") }
    print("XML: \(output.path)")

case "pair" where args.count >= 4:
    let ref = try cache.load(URL(fileURLWithPath: args[2]), rate: rate)
    var clip = try cache.load(URL(fileURLWithPath: args[3]), rate: rate)
    if args.count >= 6, let from = Double(args[4]), let length = Double(args[5]) {
        // Only part of the clip: synccli pair <ref> <clip> <desde s> <duración s>
        let a = min(clip.samples.count, Int(from * rate)), b = min(clip.samples.count, a + Int(length * rate))
        clip = AudioTrack(samples: Array(clip.samples[a..<b]), rate: rate)
    }
    let c = Correlator(reference: ref.samples, maxClip: clip.samples.count, rate: rate)
    if let m = c.match(clip.samples, lags: -clip.samples.count...ref.samples.count) {
        print(String(format: "desfase %.3f s  z %.1f  z2 %.1f", m.lag / rate, m.z, m.z2))
    }

case "sync" where args.count >= 4:
    let input = URL(fileURLWithPath: args[2])
    let output = URL(fileURLWithPath: args[3])
    let project = try FCP7Project(url: input)
    print("proyecto: \(project.sequenceName), \(project.clips.count) clips, \(project.fps) fps")
    let session = SyncSession(project: project, cache: cache, rate: rate)
    try session.readAudio(progress: { done, total in
        if done % 20 == 0 || done == total { print("audio leído: \(done)/\(total)") }
    })
    var options = SyncOptions()
    if let v = ProcessInfo.processInfo.environment["SYNCO_SPEED"].flatMap(Speed.init(rawValue:)) { options.speed = v }
    let outcome = try session.sync(options: options) { print($0) }
    var export = ExportOptions()
    export.sequenceSuffix = ""
    export.writeReport = false
    try session.export(outcome, to: output, options: export)
    let reportURL = args.count >= 5 ? URL(fileURLWithPath: args[4]) : output.deletingPathExtension().appendingPathExtension("md")
    try session.report(outcome).write(to: reportURL, atomically: true, encoding: .utf8)
    let fps = Double(project.fps)
    let agreed = outcome.checks.filter { ($0.error.map { abs($0) * fps <= 1 }) ?? false }.count
    print(String(format: "listo: %d/%d sincronizados por audio (%.1f %%); verificación: %d de %d pares a 1 cuadro; %d solapes",
                 outcome.synced, outcome.placements.count, 100 * Double(outcome.synced) / Double(outcome.placements.count),
                 agreed, outcome.checks.count, outcome.overlaps.count))
    print("XML: \(output.path)\ninforme: \(reportURL.path)")

case "compare":
    // The global search whole and in blocks, side by side, for every clip.
    let project = try FCP7Project(url: URL(fileURLWithPath: args[2]))
    let session = SyncSession(project: project, cache: cache, rate: rate)
    try session.readAudio()
    let t0 = Date()
    let rows = session.compareSearches()
    print(String(format: "%.0f s", Date().timeIntervalSince(t0)))
    for r in rows {
        let w = r.whole, b = r.blocks
        print(String(format: "%@\t%.3f\t%.3f\t%.1f\t%.1f\t%.2f\t%.2f", r.name, (w?.lag ?? 0) / rate, (b?.lag ?? 0) / rate,
                     w?.z ?? 0, b?.z ?? 0, w?.ratio ?? 0, b?.ratio ?? 0))
    }

case "drift":
    // A synced XML: each long clip's first and last two minutes, found again in the recorder's
    // audio as the XML lays it out. If the end is off by more than the start, that camera's clock
    // runs at another speed than the recorder's.
    let project = try FCP7Project(url: URL(fileURLWithPath: args[2]))
    let session = SyncSession(project: project, cache: cache, rate: rate)
    try session.readAudio()
    let starts = project.mediaStarts()
    let recorder = Dictionary(grouping: project.clips.filter { !$0.hasVideo }, by: \.device)
        .max { a, b in a.value.reduce(0) { $0 + (session.audio[$1.fileID]?.duration ?? 0) } < b.value.reduce(0) { $0 + (session.audio[$1.fileID]?.duration ?? 0) } }?.value ?? []
    let end = recorder.compactMap { c in starts[c.fileID].map { $0 + (session.audio[c.fileID]?.duration ?? 0) } }.max() ?? 0
    var line = [Float](repeating: 0, count: Int(end * rate) + 1)
    for c in recorder {
        guard let s = starts[c.fileID], let a = session.audio[c.fileID] else { continue }
        let o = Int((s * rate).rounded())
        for i in a.samples.indices where o + i >= 0 && o + i < line.count { line[o + i] = a.samples[i] }
    }
    let piece = 120.0, margin = 2.0
    func error(_ samples: ArraySlice<Float>, at t: Double) -> (Double, Float)? {
        let from = Int(((t - margin) * rate).rounded())
        let len = samples.count + Int(2 * margin * rate)
        guard from >= 0, from + len <= line.count else { return nil }
        let ref = Array(line[from..<(from + len)])
        let c = Correlator(reference: ref, maxClip: samples.count, rate: rate)
        guard let m = c.match(Array(samples), lags: 0...Int(2 * margin * rate)), m.z >= 7 else { return nil }
        return (m.lag / rate - margin, m.z)
    }
    print("clip\tminutos\terror al principio (ms)\terror al final (ms)\tderiva (ppm)")
    for c in project.clips where c.hasVideo {
        guard let s = starts[c.fileID], let a = session.audio[c.fileID], a.duration >= 600 else { continue }
        let n = Int(piece * rate)
        guard let e0 = error(a.samples[0..<n], at: s), let e1 = error(a.samples[(a.samples.count - n)...], at: s + a.duration - piece) else {
            print("\(c.name)\t\(Int(a.duration / 60))\tsin audio en común claro en un extremo"); continue
        }
        let ppm = (e1.0 - e0.0) / (a.duration - piece) * 1e6
        print(String(format: "%@\t%.0f\t%+.0f\t%+.0f\t%+.0f", c.name, a.duration / 60, e0.0 * 1000, e1.0 * 1000, ppm))
    }

case "times":
    let project = try FCP7Project(url: URL(fileURLWithPath: args[2]))
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SS"
    for c in project.clips {
        let file = (try? c.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
        let rec = recordingStart(url: c.url)
        let diff = zip([file], [rec]).compactMap { a, b in a.flatMap { a in b.map { $0.timeIntervalSince(a) } } }.first
        print("\(c.name.padding(toLength: 26, withPad: " ", startingAt: 0)) archivo \(file.map(f.string) ?? "-")  grabación \(rec.map(f.string) ?? "-")"
              + (diff.map { abs($0) >= 0.01 ? String(format: "  (%+.2f s)", $0) : "" } ?? ""))
    }

case "check":
    // Independent judge: every overlapping pair of clips from different devices,
    // compared directly by audio, against where the XML put them.
    let project = try FCP7Project(url: URL(fileURLWithPath: args[2]))
    let session = SyncSession(project: project, cache: cache, rate: rate)
    try session.readAudio()
    let starts = project.mediaStarts()
    let skipLabel = args.count >= 4 ? args[3] : ""
    let clips = project.clips.map { c in
        SyncClip(id: c.fileID, name: c.name, device: c.device, audio: session.audio[c.fileID], recordedAt: nil,
                 duration: session.audio[c.fileID]?.duration ?? Double(c.frames) / Double(project.fps))
    }
    let placed = project.clips.compactMap { c -> Placement? in
        guard let t = starts[c.fileID], session.audio[c.fileID] != nil, !project.label(c).contains(skipLabel) || skipLabel.isEmpty else { return nil }
        return Placement(id: c.fileID, time: t, method: .audio)
    }
    let checks = Syncer(clips: clips, rate: rate) { _ in }.crosscheck(placed)
    let fps = project.fps
    let judged = checks.compactMap(\.error)
    let names = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.fileID, $0.name) })
    print("pares superpuestos: \(checks.count), con audio en común claro: \(judged.count)")
    for (label, lo, hi) in [(String(format: "≤1 cuadro (%.0f ms)", 1000 / fps), 0.0, 1.0), ("1–2 cuadros", 1.0, 2.0), ("> 2 cuadros", 2.0, 1e9)] {
        print("  \(label): \(judged.filter { abs($0) * fps > lo && abs($0) * fps <= hi || (lo == 0 && $0 == 0) }.count)")
    }
    let sorted = judged.map(abs).sorted()
    if !sorted.isEmpty {
        print(String(format: "  error mediano %.0f ms, máximo %.0f ms", 1000 * sorted[sorted.count / 2], 1000 * sorted.last!))
    }
    let focus = ProcessInfo.processInfo.environment["FOCUS"] ?? "\u{0}"
    for c in checks where (c.error.map { abs($0) * fps > 2 }) ?? false || names[c.a]! == focus || names[c.b]! == focus {
        print("  \(names[c.a]!) vs \(names[c.b]!): " + (c.error.map { String(format: "%+.3f s", $0) } ?? String(format: "sin audio en común claro (z %.1f)", c.z)))
    }

default:
    usage()
}
