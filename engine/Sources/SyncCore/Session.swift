import Foundation

/// Where decoded audio is kept between runs, shared by the app and the CLI.
public let defaultCacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Synco/audio")

public struct SyncCancelled: Error, CustomStringConvertible {
    public init() {}
    public var description: String { "sincronización detenida" }
}

/// How the synced timeline is written back.
public struct ExportOptions: Codable, Equatable {
    /// Premiere label names ("Blue", "Yellow", "Rose"...); empty leaves the clip's own label.
    /// Found by its audio anywhere (or confirmed by another camera): exact.
    public var syncedLabel = "Blue"
    /// Found by its audio only in the stretch its date and its neighbours point to: worth a look.
    public var approxLabel = "Yellow"
    /// Not found by its audio: placed by date, time and neighbours as a best guess.
    public var unsyncedLabel = "Rose"
    public var disableUnsynced = false
    /// Appended to the sequence name, so the synced copy is easy to tell apart.
    public var sequenceSuffix = " - sincronizado"
    public var writeReport = true

    public init() {}

    // Settings saved by older versions lack newer keys: those take their defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExportOptions()
        syncedLabel = try c.decodeIfPresent(String.self, forKey: .syncedLabel) ?? d.syncedLabel
        approxLabel = try c.decodeIfPresent(String.self, forKey: .approxLabel) ?? d.approxLabel
        unsyncedLabel = try c.decodeIfPresent(String.self, forKey: .unsyncedLabel) ?? d.unsyncedLabel
        disableUnsynced = try c.decodeIfPresent(Bool.self, forKey: .disableUnsynced) ?? d.disableUnsynced
        sequenceSuffix = try c.decodeIfPresent(String.self, forKey: .sequenceSuffix) ?? d.sequenceSuffix
        writeReport = try c.decodeIfPresent(Bool.self, forKey: .writeReport) ?? d.writeReport
    }
}

/// How sure a clip's place is, shown in three colours.
public enum SyncQuality {
    /// Its audio, searched everywhere, or confirmed against another camera.
    case exact
    /// Its audio, searched only where its date and neighbours say it can be.
    case approximate
    /// No audio match: a best guess from dates and neighbours.
    case guessed
}

/// Everything one sync produced, ready to show or export.
public struct SyncOutcome {
    public let placements: [Placement]
    /// Timeline frame where each clip's media starts, earliest clip at zero.
    public let starts: [String: Int]
    public let checks: [Syncer.Crosscheck]
    /// Same-device clips that ended up overlapping (always a wrong placement).
    public let overlaps: [String]
    public let seconds: Double
    /// Clips whose place another camera confirmed directly, to a frame or better.
    public let confirmed: Set<String>
    /// The reference was an audio recorder (its files' times are trustworthy), not a camera.
    public let referenceIsRecorder: Bool
    /// Things the user should know before trusting the result.
    public let warnings: [String]

    public var synced: Int { placements.filter { $0.method.synced }.count }

    public func quality(_ p: Placement) -> SyncQuality {
        switch p.method {
        case .audio: return .exact
        // A recorder's files are placed by their exact start times; a camera's by its file dates,
        // which can be export times: only blue when another camera confirms them.
        case .reference: return referenceIsRecorder || confirmed.contains(p.id) ? .exact : .guessed
        case .audioNear: return confirmed.contains(p.id) ? .exact : .approximate
        case .clock, .unplaced: return .guessed
        }
    }
}

/// One project from open to export: reads the audio, syncs, and writes the result.
/// The CLI and the app both drive the engine through this.
public final class SyncSession {
    public let project: FCP7Project
    public let rate: Double
    public let cache: AudioCache
    public private(set) var audio = [String: AudioTrack]()
    public private(set) var problems = [String: String]()

    public init(project: FCP7Project, cache: AudioCache = AudioCache(dir: defaultCacheDir), rate: Double = 4000) {
        self.project = project
        self.cache = cache
        self.rate = rate
    }

    /// Reads every file's audio not read yet, a few at a time (disk bound).
    public func readAudio(progress: (Int, Int) -> Void = { _, _ in }, cancelled: () -> Bool = { false }) throws {
        let todo = project.clips.filter { audio[$0.fileID] == nil }
        let lock = NSLock()
        var read = 0
        let readers = 4
        DispatchQueue.concurrentPerform(iterations: readers) { w in
            for i in stride(from: w, to: todo.count, by: readers) {
                if cancelled() { return }
                let clip = todo[i]
                let result = Result { try cache.load(clip.url, rate: rate) }
                lock.lock()
                switch result {
                case .success(let a): audio[clip.fileID] = a; problems[clip.fileID] = nil
                case .failure(let e): problems[clip.fileID] = "\(e)"
                }
                read += 1
                progress(read, todo.count)
                lock.unlock()
            }
        }
        if cancelled() { throw SyncCancelled() }
    }

    /// Forgets a file's audio, after it was relinked to another path.
    public func forget(_ fileID: String) {
        audio[fileID] = nil
        problems[fileID] = nil
    }

    /// Syncs the clips. `ignoring` are clips the user marked as wrongly synced:
    /// their audio is left out, so they fall back to their device clock.
    public func sync(options: SyncOptions = SyncOptions(), ignoring: Set<String> = [],
                     log: @escaping (String) -> Void = { _ in }) throws -> SyncOutcome {
        let started = Date()
        let duration = { (c: ProjectClip) in self.audio[c.fileID]?.duration ?? Double(c.frames) / Double(self.project.fps) }
        let twinOf = Self.twins(project.clips, duration: duration)
        if !twinOf.isEmpty { log("\(twinOf.count) copias de otros clips (original + convertido): van donde va su original") }
        let inputs = project.clips.filter { twinOf[$0.fileID] == nil }.map { c in
            SyncClip(id: c.fileID, name: c.name, device: c.device,
                     audio: ignoring.contains(c.fileID) ? nil : audio[c.fileID],
                     recordedAt: recordingStart(url: c.url),
                     modifiedAt: (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                     duration: audio[c.fileID]?.duration ?? Double(c.frames) / Double(project.fps))
        }
        let syncer = Syncer(clips: inputs, rate: rate, options: options, log: log)
        syncer.soundOnly = Set(Dictionary(grouping: project.clips, by: \.device).filter { !$0.value.contains { $0.hasVideo } }.keys)
        var result = syncer.run()
        if options.isCancelled() { throw SyncCancelled() }
        let placed = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
        let names = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.fileID, $0.name) })
        for (twin, original) in twinOf {
            guard var p = placed[original] else { continue }
            p = Placement(id: twin, time: p.time, method: p.method, z: p.z, ratio: p.ratio, clockError: p.clockError,
                          note: "copia de \(names[original] ?? original)")
            result.append(p)
        }

        let fps = Double(project.fps)
        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.fileID, $0) })
        // The reference (the recorder) stays exactly where it is on the editor's timeline and
        // everything is laid out around it; only if something would land before the start of
        // the sequence does the whole thing move later, together.
        let reference = syncer.referenceDevice
        let referenceClips = project.clips.filter { $0.device == reference }
        let referenceIsRecorder = !referenceClips.isEmpty && !referenceClips.contains { $0.hasVideo }
        let originalStarts = project.mediaStarts()
        var origin = result.filter { $0.method != .unplaced }.map(\.time).min() ?? 0
        var anchorFrame = 0
        if let first = result.filter({ byID[$0.id]?.device == reference && $0.method == .reference }).min(by: { $0.time < $1.time }),
           let was = originalStarts[first.id] {
            origin = first.time
            anchorFrame = Int((was * fps).rounded())
        }
        var starts = [String: Int]()
        for p in result where p.method != .unplaced {
            starts[p.id] = anchorFrame + Int(((p.time - origin) * fps).rounded())
        }
        if let lowest = starts.values.min(), lowest < 0 {
            for k in starts.keys { starts[k]! -= lowest }
        }
        var end = 0
        for p in result where p.method == .unplaced {
            // Nothing to go on: after everything else, one after another.
            end = max(end, starts.map { $0.value + byID[$0.key]!.frames }.max() ?? 0)
            starts[p.id] = end
            end += byID[p.id]!.frames
        }

        // Two clips from the same device can never overlap; if they do, one placement is wrong.
        var overlaps = [String]()
        for (_, list) in Dictionary(grouping: project.clips, by: \.device) {
            let sorted = list.sorted { starts[$0.fileID]! < starts[$1.fileID]! }
            for (a, b) in zip(sorted, sorted.dropFirst()) where twinOf[a.fileID] != b.fileID && twinOf[b.fileID] != a.fileID {
                let over = starts[a.fileID]! + a.frames - starts[b.fileID]!
                if over > 1 { overlaps.append("\(a.name) se pisa con \(b.name) por \(over) cuadros") }
            }
        }

        log("verificando pares de cámaras entre sí…")
        let checks = syncer.crosscheck(result.filter { twinOf[$0.id] == nil })
        // Confirmed: checked against another camera to a frame or better (and their copies with them).
        var confirmed = Set(checks.filter { ($0.error.map { abs($0) * Double(project.fps) <= 1 }) ?? false }.flatMap { [$0.a, $0.b] })
        for (copy, original) in twinOf where confirmed.contains(original) { confirmed.insert(copy) }
        // Say so when there was no recorder to sync against: a camera made a poor reference.
        var warnings = [String]()
        let audioOnly = Dictionary(grouping: project.clips.filter { !$0.hasVideo }, by: \.device)
            .mapValues { $0.reduce(0) { $0 + duration($1) } }
        if !referenceIsRecorder {
            let name = referenceClips.first.map { "\($0.track) · \(($0.folder as NSString).lastPathComponent)" } ?? reference
            if let longest = audioOnly.values.max() {
                warnings.append(String(format: "Ninguna pista de solo audio cubre el evento (la más larga suma %@): se usó la cámara %@ "
                    + "como referencia. Si faltan los archivos del grabador en la secuencia, agregalos y volvé a exportar el XML.",
                    formatSeconds(longest), name))
            } else {
                warnings.append("No hay un grabador en la secuencia: se usó la cámara \(name) como referencia. "
                    + "Sus clips solo quedan en azul si otra cámara los confirma.")
            }
        }
        return SyncOutcome(placements: result, starts: starts, checks: checks, overlaps: overlaps,
                           seconds: Date().timeIntervalSince(started), confirmed: confirmed,
                           referenceIsRecorder: referenceIsRecorder, warnings: warnings)
    }

    /// Copies of one recording on the same device (an original and the version converted for
    /// editing, "IMG_2868.MOV" and "IMG_2868_1.mp4"): same name stem and length. Returns copy → original.
    static func twins(_ clips: [ProjectClip], duration: (ProjectClip) -> Double) -> [String: String] {
        func stem(_ name: String) -> String {
            var s = name.lowercased()
            while let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 5 { s = String(s[..<dot]) }
            // Only the marks a copy gets ("_1", " copy"); "-02" is the next part of a split take,
            // and "Tema 2" is another song.
            if let r = s.range(of: #"(_\d{1,2}|[ _\-](copy|copia|proxy))$"#, options: .regularExpression) { s.removeSubrange(r) }
            return s
        }
        func rank(_ c: ProjectClip) -> (Int, Int, String) {
            let ext = c.url.pathExtension.lowercased()
            let looksCopied = stem(c.name) + "." + ext != c.name.lowercased() ? 1 : 0
            let original = ["mov", "mxf", "mts", "braw", "r3d", "wav"].contains(ext) ? 0 : 1
            return (looksCopied, original, c.name)
        }
        var out = [String: String]()
        for (_, group) in Dictionary(grouping: clips, by: { $0.device + "|" + stem($0.name) }) where group.count > 1 {
            let sorted = group.sorted { rank($0) < rank($1) }
            let original = sorted[0]
            for copy in sorted.dropFirst() where abs(duration(copy) - duration(original)) <= 2 {
                out[copy.fileID] = original.fileID
            }
        }
        return out
    }

    /// Writes the synced XML (and the report next to it, if asked).
    public func export(_ outcome: SyncOutcome, to url: URL, options: ExportOptions = ExportOptions()) throws {
        var labels = [String: String]()
        var disabled = Set<String>()
        for p in outcome.placements {
            switch outcome.quality(p) {
            case .exact:
                if !options.syncedLabel.isEmpty { labels[p.id] = options.syncedLabel }
            case .approximate:
                if !options.approxLabel.isEmpty { labels[p.id] = options.approxLabel }
            case .guessed:
                if !options.unsyncedLabel.isEmpty { labels[p.id] = options.unsyncedLabel }
                if options.disableUnsynced { disabled.insert(p.id) }
            }
        }
        project.apply(starts: outcome.starts, labels: labels, disabled: disabled)
        project.rename(project.sequenceName + options.sequenceSuffix)
        try project.write(to: url)
        if options.writeReport {
            try report(outcome).write(to: url.deletingPathExtension().appendingPathExtension("md"), atomically: true, encoding: .utf8)
        }
    }

    public func report(_ outcome: SyncOutcome) -> String {
        let result = outcome.placements, checks = outcome.checks
        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.fileID, $0) })
        let count = result.count
        let methods = Dictionary(grouping: result, by: \.method)
        let fps = Double(project.fps)
        let agreed = checks.filter { ($0.error.map { abs($0) * fps <= 1 }) ?? false }.count
        let within2 = checks.filter { ($0.error.map { abs($0) * fps > 1 && abs($0) * fps <= 2 }) ?? false }
        let disagreed = checks.filter { ($0.error.map { abs($0) * fps > 2 }) ?? false }
        var md = "# Sincronización: \(project.sequenceName)\n\n"
        for w in outcome.warnings { md += "> ⚠️ \(w)\n\n" }
        md += String(format: "**%d de %d clips sincronizados por audio (%.1f %%)**. Tiempo: %.0f s.\n\n",
                     outcome.synced, count, 100 * Double(outcome.synced) / Double(max(count, 1)), outcome.seconds)
        let q = Dictionary(grouping: result, by: { outcome.quality($0) })
        md += "- azul (exacto, por audio): \(q[.exact]?.count ?? 0)\n"
        md += "- amarillo (por audio, buscando cerca de su hora o de sus vecinos): \(q[.approximate]?.count ?? 0)\n"
        md += "- rojo (sin audio en común: ubicado por fecha, hora y vecinos): \(q[.guessed]?.count ?? 0)\n\n"
        for m in [SyncMethod.reference, .audio, .audioNear, .clock, .unplaced] {
            md += "- \(m.rawValue): \(methods[m]?.count ?? 0)\n"
        }
        md += "\n## Verificación cruzada\n\n"
        md += "Pares de clips de dispositivos distintos que quedaron superpuestos, comparados entre sí directamente: "
        md += "\(checks.count) pares, \(agreed) coinciden a 1 cuadro o menos, \(within2.count) entre 1 y 2 cuadros, "
        md += "\(disagreed.count) no coinciden, \(checks.count - agreed - within2.count - disagreed.count) sin audio en común claro.\n\n"
        md += "Entre 1 y 2 cuadros es lo esperable cuando las cámaras están a distinta distancia del sonido: "
        md += "el sonido tarda unos 3 ms por metro, y 14 m ya son un cuadro.\n\n"
        for c in within2 + disagreed {
            md += String(format: "- %@ vs %@: %.2f s de diferencia\n", byID[c.a]!.name, byID[c.b]!.name, c.error!)
        }
        if !outcome.overlaps.isEmpty {
            md += "\n## Clips del mismo dispositivo que se pisan\n\n" + outcome.overlaps.map { "- \($0)\n" }.joined()
        }
        if !problems.isEmpty {
            md += "\n## Archivos con problemas\n\n" + problems.map { "- \(byID[$0.key]?.name ?? $0.key): \($0.value)\n" }.joined()
        }
        md += "\n## Clips\n\n| clip | dispositivo | método | posición | z | relación | error vs reloj | color |\n|---|---|---|---|---|---|---|---|\n"
        for p in result.sorted(by: { $0.time < $1.time }) {
            let c = byID[p.id]!
            let pos = Double(outcome.starts[p.id] ?? 0) / fps
            let colour = ["exact": "azul", "approximate": "amarillo", "guessed": "rojo"]["\(outcome.quality(p))"]!
            md += String(format: "| %@ | %@ | %@ | %02d:%02d:%05.2f | %.1f | %.2f | %@ | %@ |\n",
                         c.name, (c.device as NSString).lastPathComponent, p.method.rawValue,
                         Int(pos) / 3600, Int(pos) / 60 % 60, pos.truncatingRemainder(dividingBy: 60),
                         p.z, p.ratio, p.clockError.map { String(format: "%+.2f s", $0) } ?? "", colour)
        }
        return md
    }
}

func formatSeconds(_ s: Double) -> String {
    s < 60 ? String(format: "%.0f s", s) : (s < 3600 ? String(format: "%.0f min", s / 60) : String(format: "%.1f h", s / 3600))
}
