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
    /// Premiere label names ("Rose", "Mango", "Forest"...); empty leaves the clip's own label.
    public var syncedLabel = ""
    public var unsyncedLabel = "Rose"
    public var disableUnsynced = false
    /// Appended to the sequence name, so the synced copy is easy to tell apart.
    public var sequenceSuffix = " - sincronizado"
    public var writeReport = true

    public init() {}
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

    public var synced: Int { placements.filter { $0.method.synced }.count }
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
        let inputs = project.clips.map { c in
            SyncClip(id: c.fileID, name: c.name, device: c.device,
                     audio: ignoring.contains(c.fileID) ? nil : audio[c.fileID],
                     recordedAt: recordingStart(url: c.url),
                     modifiedAt: (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                     duration: audio[c.fileID]?.duration ?? Double(c.frames) / Double(project.fps))
        }
        let syncer = Syncer(clips: inputs, rate: rate, options: options, log: log)
        let result = syncer.run()
        if options.isCancelled() { throw SyncCancelled() }

        let fps = Double(project.fps)
        let origin = result.filter { $0.method != .unplaced }.map(\.time).min() ?? 0
        var starts = [String: Int]()
        for p in result where p.method != .unplaced {
            starts[p.id] = Int(((p.time - origin) * fps).rounded())
        }
        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.fileID, $0) })
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
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                let over = starts[a.fileID]! + a.frames - starts[b.fileID]!
                if over > 1 { overlaps.append("\(a.name) se pisa con \(b.name) por \(over) cuadros") }
            }
        }

        log("verificando pares de cámaras entre sí…")
        let checks = syncer.crosscheck(result)
        return SyncOutcome(placements: result, starts: starts, checks: checks, overlaps: overlaps,
                           seconds: Date().timeIntervalSince(started))
    }

    /// Writes the synced XML (and the report next to it, if asked).
    public func export(_ outcome: SyncOutcome, to url: URL, options: ExportOptions = ExportOptions()) throws {
        var labels = [String: String]()
        var disabled = Set<String>()
        for p in outcome.placements {
            if p.method.synced {
                if !options.syncedLabel.isEmpty { labels[p.id] = options.syncedLabel }
            } else {
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
        md += String(format: "**%d de %d clips sincronizados por audio (%.1f %%)**. Tiempo: %.0f s.\n\n",
                     outcome.synced, count, 100 * Double(outcome.synced) / Double(max(count, 1)), outcome.seconds)
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
        md += "\n## Clips\n\n| clip | dispositivo | método | posición | z | relación | error vs reloj |\n|---|---|---|---|---|---|---|\n"
        for p in result.sorted(by: { $0.time < $1.time }) {
            let c = byID[p.id]!
            let pos = Double(outcome.starts[p.id] ?? 0) / fps
            md += String(format: "| %@ | %@ | %@ | %02d:%02d:%05.2f | %.1f | %.2f | %@ |\n",
                         c.name, (c.device as NSString).lastPathComponent, p.method.rawValue,
                         Int(pos) / 3600, Int(pos) / 60 % 60, pos.truncatingRemainder(dividingBy: 60),
                         p.z, p.ratio, p.clockError.map { String(format: "%+.2f s", $0) } ?? "")
        }
        return md
    }
}
