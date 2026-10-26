import AppKit
import SwiftUI
import SyncCore

/// One row of the timeline: every clip from one card (camera, phone or recorder folder).
struct TrackRow: Identifiable {
    enum Kind { case camera, recorder }
    let id: String
    let kind: Kind
    let name: String
    let folder: String
    let clips: [ProjectClip]
}

/// How demanding the engine is before it accepts an audio match.
enum Strictness: String, Codable, CaseIterable, Identifiable {
    case permissive, normal, strict
    var id: String { rawValue }
    var label: String {
        switch self {
        case .permissive: return "Permisiva (más clips, más riesgo de errores)"
        case .normal: return "Normal"
        case .strict: return "Estricta (menos clips, casi sin errores)"
        }
    }
}

enum Band: String, Codable, CaseIterable, Identifiable {
    case voice, wide
    var id: String { rawValue }
    var label: String { self == .voice ? "Voz y ambiente (100–1900 Hz)" : "Amplia (60–1900 Hz), para música con graves" }
}

struct SyncPrefs: Codable, Equatable {
    var strictness = Strictness.normal
    /// Seconds searched either side of where a device clock puts a clip.
    var window: Double = 20
    var band = Band.voice

    var options: SyncOptions {
        var o = SyncOptions()
        switch strictness {
        case .permissive: o.zGlobal = 7.5; o.zNear = 6; o.ratioGlobal = 1.2; o.ratioNear = 1.1
        case .normal: break
        case .strict: o.zGlobal = 11; o.zNear = 8.5; o.ratioGlobal = 1.5; o.ratioNear = 1.3
        }
        o.window = window
        o.match.lowHz = band == .voice ? 100 : 60
        o.workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        return o
    }
}

struct AppPrefs: Codable, Equatable {
    var sync = SyncPrefs()
    var export = ExportOptions()
    var soundWhenDone = true
    var cacheDays = 60
    var recents: [String] = []
}

/// A flag the engine threads can read while the main thread sets it.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case empty, reading, ready, matching, done, stopped
        case failed(String)
    }

    @Published var phase = Phase.empty {
        didSet { holdAwake(busy) }
    }
    private var activity: NSObjectProtocol?

    /// Keeps App Nap from slowing a sync down while the app is in the background.
    private func holdAwake(_ on: Bool) {
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                             reason: "Sincronizando clips")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a)
            activity = nil
        }
    }
    @Published var fileURL: URL?
    @Published var project: FCP7Project?
    @Published var tracks: [TrackRow] = []
    @Published var placements: [String: Placement] = [:]
    @Published var starts: [String: Int]?
    @Published var peaks: [String: [Float]] = [:]
    @Published var durations: [String: Double] = [:]
    @Published var readDone = 0
    @Published var readTotal = 0
    @Published var message = "Abrí o soltá un XML exportado de Premiere, Resolve o Vegas."
    @Published var ignored = Set<String>()
    @Published var selected: String?
    @Published var missing: [ProjectClip] = []
    @Published var showPathFixer = false
    @Published var showSyncSettings = false
    @Published var showExportSettings = false
    @Published var showReport = false
    @Published var prefs: AppPrefs { didSet { savePrefs() } }

    private(set) var session: SyncSession?
    private(set) var outcome: SyncOutcome?
    private let cancel = CancelFlag()
    private var readTask: Task<Void, Never>?

    nonisolated static let peaksPerSecond = 10.0

    /// Command-line test runs (any "--" argument) read the user's settings but never write them,
    /// even if they are cut off halfway.
    private let persist = !CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--") }
        && !ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("SYNCO_UPDATE") }

    init() {
        // Settings saved while the app still had its provisional name come along.
        let saved = UserDefaults.standard.data(forKey: "prefs")
            ?? UserDefaults(suiteName: "local.mariano.sincro")?.data(forKey: "prefs")
        if let data = saved, let p = try? JSONDecoder().decode(AppPrefs.self, from: data) {
            prefs = p
        } else {
            prefs = AppPrefs()
        }
        // One-time fix: test runs of 1.0.0 and 1.0.1 could leave "disable unsynced clips" on
        // without the user choosing it. Unsynced clips stay enabled (with their colour) by default.
        if persist, UserDefaults.standard.integer(forKey: "prefsFixes") < 1 {
            prefs.export.disableUnsynced = false
            savePrefs()
            UserDefaults.standard.set(1, forKey: "prefsFixes")
        }
        // 1.0.3: synced clips get the blue label by default (they had none).
        if persist, UserDefaults.standard.integer(forKey: "prefsFixes") < 2 {
            if prefs.export.syncedLabel.isEmpty { prefs.export.syncedLabel = "Blue" }
            savePrefs()
            UserDefaults.standard.set(2, forKey: "prefsFixes")
        }
    }

    private func savePrefs() {
        guard persist else { return }
        if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data, forKey: "prefs") }
    }

    // MARK: Derived

    var busy: Bool { phase == .reading || phase == .matching }
    var cameras: Int { tracks.filter { $0.kind == .camera }.count }
    var recorders: Int { tracks.filter { $0.kind == .recorder }.count }
    var clipCount: Int { project?.clips.count ?? 0 }
    var syncedCount: Int { placements.values.filter { $0.method.synced }.count }

    func count(_ q: SyncQuality) -> Int {
        guard let outcome else { return 0 }
        return placements.values.filter { outcome.quality($0) == q }.count
    }

    /// Blue, yellow or red for a clip, once synced.
    func quality(_ id: String) -> SyncQuality? {
        guard let p = placements[id] else { return nil }
        return outcome?.quality(p)
    }
    var remainingCount: Int { clipCount - syncedCount }
    var fps: Double { Double(project?.fps ?? 25) }
    var report: String { outcome.flatMap { o in session?.report(o) } ?? "" }

    func duration(_ clip: ProjectClip) -> Double {
        durations[clip.fileID] ?? Double(clip.frames) / fps
    }

    /// Where a clip starts on screen, in seconds: its synced place, or end to end before syncing.
    func start(_ clip: ProjectClip, in track: TrackRow) -> Double {
        if let starts, let f = starts[clip.fileID] { return Double(f) / fps }
        var t = 0.0
        for c in track.clips {
            if c === clip { return t }
            t += duration(c)
        }
        return t
    }

    var totalDuration: Double {
        tracks.flatMap { t in t.clips.map { start($0, in: t) + duration($0) } }.max() ?? 0
    }

    func clip(_ id: String) -> ProjectClip? { project?.clips.first { $0.fileID == id } }

    // MARK: Open

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        stop()
        do {
            let project = try FCP7Project(url: url)
            guard !project.clips.isEmpty else { throw ProjectError.notFCP7("la secuencia no tiene clips con archivo") }
            self.project = project
            fileURL = url
            session = SyncSession(project: project)
            outcome = nil
            placements = [:]
            starts = nil
            peaks = [:]
            durations = [:]
            ignored = []
            selected = nil
            buildTracks()
            prefs.recents = ([url.path] + prefs.recents.filter { $0 != url.path }).prefix(8).map { $0 }
            refreshMissing()
            if !missing.isEmpty { showPathFixer = true }
            readAudio()
        } catch {
            phase = .failed("No se pudo abrir \(url.lastPathComponent): \(error)")
            message = "No se pudo abrir \(url.lastPathComponent). ¿Es un XML de Premiere (Final Cut Pro 7 XML)?"
        }
    }

    func reload() {
        if let fileURL { open(fileURL) }
    }

    private func buildTracks() {
        guard let project else { tracks = []; return }
        var order = [String]()
        var byDevice = [String: [ProjectClip]]()
        for c in project.clips {
            if byDevice[c.device] == nil { order.append(c.device) }
            byDevice[c.device, default: []].append(c)
        }
        var cams = 0, recs = 0
        var rows = [TrackRow]()
        for device in order {
            let clips = byDevice[device]!.sorted {
                (recordingStart(url: $0.url) ?? .distantPast, $0.name) < (recordingStart(url: $1.url) ?? .distantPast, $1.name)
            }
            let video = clips.contains { $0.hasVideo }
            // Its editor track and folder, so it is easy to tell which is which.
            let folder = "\(clips[0].track) · \((clips[0].folder as NSString).lastPathComponent)"
            if video { cams += 1 } else { recs += 1 }
            rows.append(TrackRow(id: device, kind: video ? .camera : .recorder,
                                 name: video ? "CÁMARA \(cams)" : "GRABADOR \(recs)", folder: folder, clips: clips))
        }
        // Cameras on top, recorders at the bottom, like an editor's timeline.
        tracks = rows.filter { $0.kind == .camera } + rows.filter { $0.kind == .recorder }
    }

    func refreshMissing() {
        missing = project?.clips.filter { !$0.exists } ?? []
    }

    // MARK: Audio

    private func readAudio(then next: (() -> Void)? = nil) {
        guard let session else { return }
        cancel.set(false)
        phase = .reading
        readDone = 0
        readTotal = session.project.clips.filter { session.audio[$0.fileID] == nil }.count
        message = "Leyendo el audio de los archivos…"
        let cancel = self.cancel
        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try session.readAudio(progress: { done, total in
                    Task { @MainActor in self?.readDone = done; self?.readTotal = total }
                }, cancelled: { cancel.isSet })
                let (peaks, durations) = Self.makePeaks(session)
                await MainActor.run {
                    guard let self, self.session === session else { return }
                    self.peaks = peaks
                    self.durations = durations
                    let failed = session.problems.count
                    let images = session.project.skippedImages.count
                    self.phase = .ready
                    self.message = failed == 0
                        ? "Listo para sincronizar."
                        : "Listo. \(failed) archivo(s) sin audio legible: se van a ubicar por su hora."
                    if images > 0 { self.message += " \(images) imagen(es) quedan como están: no tienen sonido." }
                    next?()
                }
            } catch {
                await MainActor.run {
                    guard let self, self.session === session else { return }
                    self.phase = .stopped
                    self.message = "Lectura detenida."
                }
            }
        }
    }

    nonisolated private static func makePeaks(_ session: SyncSession) -> ([String: [Float]], [String: Double]) {
        var peaks = [String: [Float]]()
        var durations = [String: Double]()
        for (id, track) in session.audio {
            let step = max(1, Int(track.rate / peaksPerSecond))
            var out = [Float]()
            out.reserveCapacity(track.samples.count / step + 1)
            var i = 0
            var top: Float = 0
            while i < track.samples.count {
                let end = min(track.samples.count, i + step)
                var m: Float = 0
                for j in i..<end { m = max(m, abs(track.samples[j])) }
                out.append(m)
                top = max(top, m)
                i = end
            }
            if top > 0 { out = out.map { min(1, $0 / top) } }
            peaks[id] = out
            durations[id] = track.duration
        }
        return (peaks, durations)
    }

    // MARK: Sync

    func synchronize() {
        guard session != nil, !busy else { return }
        if phase == .stopped || session!.audio.count + session!.problems.count < clipCount {
            readAudio { [weak self] in self?.match() }
        } else {
            match()
        }
    }

    private func match() {
        guard let session else { return }
        cancel.set(false)
        phase = .matching
        message = "Buscando coincidencias de audio…"
        var options = prefs.sync.options
        let cancel = self.cancel
        options.isCancelled = { cancel.isSet }
        let ignoring = ignored
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try session.sync(options: options, ignoring: ignoring) { line in
                    Task { @MainActor in self?.message = line.prefix(1).uppercased() + line.dropFirst() }
                }
            }
            await MainActor.run {
                guard let self, self.session === session else { return }
                switch result {
                case .success(let outcome):
                    self.outcome = outcome
                    self.placements = Dictionary(uniqueKeysWithValues: outcome.placements.map { ($0.id, $0) })
                    self.starts = outcome.starts
                    self.phase = .done
                    let fps = self.fps
                    let agreed = outcome.checks.filter { ($0.error.map { abs($0) * fps <= 1 }) ?? false }.count
                    self.message = String(format: "%d de %d clips sincronizados por audio en %.0f s. Verificación: %d de %d pares a 1 cuadro o menos.",
                                          outcome.synced, outcome.placements.count, outcome.seconds, agreed, outcome.checks.count)
                    if !outcome.overlaps.isEmpty { self.message += " \(outcome.overlaps.count) solape(s) a revisar." }
                    if self.prefs.soundWhenDone { NSSound(named: "Glass")?.play() }
                case .failure(let error):
                    if error is SyncCancelled {
                        self.phase = .stopped
                        self.message = "Sincronización detenida. Podés volver a empezar cuando quieras."
                    } else {
                        self.phase = .failed("\(error)")
                        self.message = "Falló la sincronización: \(error)"
                    }
                }
            }
        }
    }

    func stop() {
        cancel.set(true)
    }

    /// Marks a clip as wrongly synced (or undoes it); the next sync places it by its clock.
    func toggleIgnored(_ id: String) {
        if ignored.contains(id) { ignored.remove(id) } else { ignored.insert(id) }
    }

    func clearFixes() {
        ignored = []
    }

    // MARK: Export

    func export(to chosen: URL? = nil) {
        guard let session, let outcome, let fileURL else { return }
        var target = chosen
        if target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.xml]
            panel.directoryURL = fileURL.deletingLastPathComponent()
            panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent + " - sincronizado.xml"
            guard panel.runModal() == .OK else { return }
            target = panel.url
        }
        guard let url = target else { return }
        do {
            try session.export(outcome, to: url, options: prefs.export)
            message = "Exportado: \(url.lastPathComponent). En el editor: Archivo › Importar."
            if chosen == nil { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } catch {
            message = "No se pudo exportar: \(error)"
        }
    }

    // MARK: Missing files

    /// Looks for every missing file by name inside a folder (and its subfolders).
    func relink(searching folder: URL) -> Int {
        guard let project, let session else { return 0 }
        let wanted = Dictionary(grouping: missing, by: { $0.url.lastPathComponent.lowercased() })
        var found = 0
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        while let url = walker?.nextObject() as? URL {
            guard let clips = wanted[url.lastPathComponent.lowercased()] else { continue }
            for clip in clips where !clip.exists {
                project.relink(clip, to: url)
                session.forget(clip.fileID)
                found += 1
            }
        }
        if found > 0 {
            buildTracks()
            refreshMissing()
            outcome = nil
            starts = nil
            placements = [:]
            readAudio()
        }
        return found
    }

    // MARK: Cache

    nonisolated static func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: defaultCacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    /// Deletes cached audio not used for `days` days, or all of it when nil.
    nonisolated static func clearCache(olderThan days: Int?) {
        let keys: [URLResourceKey] = [.contentAccessDateKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: defaultCacheDir, includingPropertiesForKeys: keys)) ?? []
        let limit = Date().addingTimeInterval(-Double(days ?? 0) * 86400)
        for f in files where f.pathExtension == "f32" {
            let v = try? f.resourceValues(forKeys: Set(keys))
            let used = v?.contentAccessDate ?? v?.contentModificationDate ?? .distantPast
            if days == nil || used < limit { try? FileManager.default.removeItem(at: f) }
        }
    }
}
