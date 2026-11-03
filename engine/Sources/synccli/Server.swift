import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SyncCore

/// `synccli serve`: the engine behind the Windows and Linux app. One JSON object per line on
/// stdin ({"id": 1, "cmd": "open", ...}); one per line on stdout: replies ({"id": 1, "ok": true,
/// "result": ...}) and events while working ({"event": "read", "done": 3, "total": 140}).
/// Commands run one at a time; "cancel" is handled at once.
final class Server {
    private let out = NSLock()
    private let work = DispatchQueue(label: "synco.work")
    private let cancel = CancelFlag()
    private var session: SyncSession?
    private var outcome: SyncOutcome?
    private var fileURL: URL?
    private var update: (version: String, url: String, sha256: String, file: String)?
    /// The slow search, run on its own after reading (SyncSession.searchAhead).
    private let ahead = DispatchGroup()
    private let aheadCancel = CancelFlag()
    let cache: AudioCache
    let rate: Double

    init(cache: AudioCache, rate: Double) {
        self.cache = cache
        self.rate = rate
    }

    func run() -> Never {
        send(["event": "ready", "version": engineVersion])
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cmd = msg["cmd"] as? String else { continue }
            let id = msg["id"] ?? NSNull()
            if cmd == "cancel" { cancel.set(true); reply(id, ["cancelled": true]); continue }
            if cmd == "quit" { exit(0) }
            work.async { [self] in
                do { reply(id, try handle(cmd, msg)) } catch { fail(id, "\(error)") }
            }
        }
        exit(0)
    }

    // MARK: Output

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        out.lock()
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        out.unlock()
    }

    private func reply(_ id: Any, _ result: Any) { send(["id": id, "ok": true, "result": result]) }
    private func fail(_ id: Any, _ message: String) { send(["id": id, "ok": false, "error": message]) }

    // MARK: Commands

    private func handle(_ cmd: String, _ msg: [String: Any]) throws -> Any {
        switch cmd {
        case "open": return try open(msg["path"] as? String ?? "")
        case "read": return try read((msg["options"] as? [String: Any])?["speed"] as? String)
        case "sync": return try sync(msg)
        case "export": return try export(msg)
        case "relink": return try relink(msg["folder"] as? String ?? "")
        case "drop": return try drop(msg["paths"] as? [String] ?? [], track: msg["track"] as? String)
        case "removeTrack": return try removeTrack(msg["track"] as? String ?? "")
        case "addDrone": return try addDrone(msg["paths"] as? [String] ?? [])
        case "removeDrone": return try removeDrone(msg["name"] as? String ?? "")
        // "clip", not "id": "id" is the request's.
        case "removeClip": return try removeClip(msg["clip"] as? String ?? "")
        case "moveClip": return try moveClip(msg["clip"] as? String ?? "", like: msg["like"] as? String ?? "")
        case "nudge": return try nudge(msg["clip"] as? String ?? "", by: msg["frames"] as? Int ?? 0)
        case "preview": return try preview(msg)
        case "cacheSize": return ["bytes": cacheSize()]
        case "clearCache": clearCache(days: msg["days"] as? Int); return ["bytes": cacheSize()]
        case "checkUpdate": return try checkUpdate(msg)
        case "downloadUpdate": return try downloadUpdate()
        case "installUpdate": return try installUpdate(msg)
        default: throw ServerError("orden desconocida: \(cmd)")
        }
    }

    private func open(_ path: String) throws -> [String: Any] {
        stopAhead()
        let url = URL(fileURLWithPath: path)
        let project = try FCP7Project(url: url)
        guard !project.clips.isEmpty else { throw ProjectError.notFCP7("la secuencia no tiene clips con archivo") }
        // Every file's recording date, read up front (it reads each file's header): with the progress.
        let total = project.clips.count
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: total) { i in
            _ = recordingStart(url: project.clips[i].url)
            lock.lock(); done += 1; let n = done; lock.unlock()
            if n % 20 == 0 || n == total { send(["event": "opening", "done": n, "total": total]) }
        }
        session = SyncSession(project: project, cache: cache, rate: rate)
        outcome = nil
        droneSources = []
        fileURL = url
        return describe(project, path: path)
    }

    /// Whether the open project is one Synco built from dropped folders (so it takes more of them).
    private var isBuilt: Bool {
        fileURL?.deletingLastPathComponent().standardizedFileURL.path == ProjectBuilder.projectsDir.standardizedFileURL.path
    }

    /// Folders and clips dropped on the timeline: into the track named `track`, or as new tracks.
    /// A project from an editor's XML is the editor's: folders dropped on it start a new one.
    private func drop(_ paths: [String], track: String?) throws -> [String: Any] {
        let current = isBuilt ? session.flatMap { ProjectBuilder.sources(of: $0.project) } ?? [] : []
        let sources = try ProjectBuilder.adding(paths.map { URL(fileURLWithPath: $0) }, to: current, track: isBuilt ? track : nil)
        return try rebuild(sources)
    }

    private func removeTrack(_ track: String) throws -> [String: Any] {
        guard isBuilt, let session else { throw ServerError("no hay un proyecto armado desde carpetas") }
        let sources = (ProjectBuilder.sources(of: session.project) ?? []).filter { $0.name != track }
        if sources.isEmpty {
            stopAhead()
            self.session = nil
            outcome = nil
            fileURL = nil
            return ["closed": true]
        }
        return try rebuild(sources)
    }

    /// Writes the built project's XML again with these tracks (in Synco's own folder) and opens it.
    private func rebuild(_ sources: [ProjectBuilder.Source]) throws -> [String: Any] {
        stopAhead()
        let built = isBuilt
        let name = built ? session?.project.sequenceName ?? "Proyecto"
            : ProjectBuilder.commonFolder(sources.map(\.folder))?.lastPathComponent ?? sources[0].name
        let url = built ? fileURL! : ProjectBuilder.newProjectURL(name: name)
        let skipped = try ProjectBuilder.build(sources, name: name, to: url) { done, total in
            self.send(["event": "build", "done": done, "total": total])
        }
        var result = try open(url.path)
        result["skipped"] = skipped.map(\.lastPathComponent)
        return result
    }

    private func describe(_ project: FCP7Project, path: String) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        return [
            "file": (path as NSString).lastPathComponent,
            "path": path,
            "built": isBuilt,
            // Where to offer saving the result: for a built project, the shoot's folder.
            "exportFolder": (isBuilt ? ProjectBuilder.commonFolder(Array(Set(project.clips.map { $0.url.deletingLastPathComponent() }))) : nil)?.path
                ?? (path as NSString).deletingLastPathComponent,
            "sequence": project.sequenceName,
            "fps": project.fps,
            "skippedImages": project.skippedImages,
            "clips": project.clips.map { c -> [String: Any] in
                var d: [String: Any] = [
                    "id": c.fileID, "name": c.name, "track": c.track, "device": c.device,
                    "folder": (c.folder as NSString).lastPathComponent, "folderPath": c.folder, "path": c.url.path,
                    "hasVideo": c.hasVideo, "frames": c.frames, "exists": c.exists,
                ]
                if let name = c.deviceName { d["deviceName"] = name }
                if let date = recordingStart(url: c.url) { d["recordedAt"] = iso.string(from: date) }
                return d
            },
        ]
    }

    private func read(_ speed: String?) throws -> [String: Any] {
        guard let session else { throw ServerError("no hay proyecto abierto") }
        cancel.set(false)
        try session.readAudio(progress: { done, total in self.send(["event": "read", "done": done, "total": total]) },
                              cancelled: { self.cancel.isSet })
        // Waveforms: the loudest sample of every tenth of a second, 0-255, base64.
        var peaks = [String: String](), durations = [String: Double]()
        for (id, track) in session.audio {
            let step = max(1, Int(track.rate / 10))
            var bytes = [UInt8]()
            bytes.reserveCapacity(track.samples.count / step + 1)
            var top: Float = 0
            var raw = [Float]()
            var i = 0
            while i < track.samples.count {
                let end = min(track.samples.count, i + step)
                var m: Float = 0
                for j in i..<end { m = max(m, abs(track.samples[j])) }
                raw.append(m)
                top = max(top, m)
                i = end
            }
            for m in raw { bytes.append(UInt8(top > 0 ? min(255, Int(m / top * 255)) : 0)) }
            peaks[id] = Data(bytes).base64EncodedString()
            durations[id] = track.duration
        }
        startAhead(session, speed: speed.flatMap(Speed.init(rawValue:)) ?? .normal)
        return ["peaks": peaks, "durations": durations, "problems": session.problems]
    }

    private func startAhead(_ session: SyncSession, speed: Speed) {
        stopAhead()
        aheadCancel.set(false)
        var options = SyncOptions()
        options.speed = speed
        options.workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        let flag = aheadCancel
        options.isCancelled = { flag.isSet }
        DispatchQueue.global(qos: .utility).async(group: ahead) { [self] in
            session.searchAhead(options: options) { line in self.send(["event": "ahead", "line": line]) }
            if !flag.isSet { send(["event": "ahead", "done": true]) }
        }
    }

    /// Stops it (what it found is kept) and waits, so two searches never run at once.
    private func stopAhead() {
        aheadCancel.set(true)
        ahead.wait()
    }

    private func sync(_ msg: [String: Any]) throws -> [String: Any] {
        guard let session else { throw ServerError("no hay proyecto abierto") }
        stopAhead()
        cancel.set(false)
        let prefs = msg["options"] as? [String: Any] ?? [:]
        var options = SyncOptions()
        switch prefs["strictness"] as? String ?? "normal" {
        case "permissive": options.zGlobal = 7.5; options.zNear = 6; options.ratioGlobal = 1.2; options.ratioNear = 1.1
        case "strict": options.zGlobal = 11; options.zNear = 8.5; options.ratioGlobal = 1.5; options.ratioNear = 1.3
        default: break
        }
        options.window = prefs["window"] as? Double ?? 20
        options.speed = (prefs["speed"] as? String).flatMap(Speed.init(rawValue:)) ?? .normal
        options.match.lowHz = (prefs["band"] as? String) == "wide" ? 60 : 100
        options.workers = max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        let flag = cancel
        options.isCancelled = { flag.isSet }
        let ignoring = Set(msg["ignoring"] as? [String] ?? [])
        var result = try session.sync(options: options, ignoring: ignoring) { line in self.send(["event": "log", "line": line]) }
        // The frames moved by hand before stay moved, on top of the new sync.
        result.applyManual(outcome?.manual ?? [:])
        // The drones added before go back in, on top of the new sync.
        for urls in droneSources {
            result = try session.addDrone(urls, to: result, log: { line in self.send(["event": "log", "line": line]) }, cancelled: { flag.isSet })
        }
        outcome = result
        return describe(result, session)
    }

    /// The drones added after the sync, to add again after the next one.
    private var droneSources = [[URL]]()

    /// The extra step once synced: a drone's videos (or any camera with no sound), by their time and light.
    private func addDrone(_ paths: [String]) throws -> [String: Any] {
        guard let session, let current = outcome else { throw ServerError("primero hay que sincronizar") }
        cancel.set(false)
        let flag = cancel
        let urls = paths.map { URL(fileURLWithPath: $0) }
        let result = try session.addDrone(urls, to: current, log: { line in self.send(["event": "log", "line": line]) }, cancelled: { flag.isSet })
        outcome = result
        droneSources.append(urls)
        return describe(result, session)
    }

    private func removeDrone(_ name: String) throws -> [String: Any] {
        guard let session, let current = outcome, let index = current.drones.firstIndex(where: { $0.name == name }) else {
            throw ServerError("no hay ese dron")
        }
        // The ones after it are numbered again ("DRON 2" becomes "DRON 1"): added again in order.
        var result = current
        for d in current.drones { result = session.removeDrone(d.name, from: result) }
        if index < droneSources.count { droneSources.remove(at: index) }
        let flag = cancel
        for urls in droneSources { result = try session.addDrone(urls, to: result, cancelled: { flag.isSet }) }
        outcome = result
        return describe(result, session)
    }

    // MARK: By hand, once synced

    /// Takes a clip out of the project (the file stays). Returns the project, and the sync if there is one.
    private func removeClip(_ id: String) throws -> [String: Any] {
        guard let session else { throw ServerError("no hay proyecto abierto") }
        stopAhead()
        session.removeClip(id, from: &outcome)
        saveBuilt()
        return edited(session)
    }

    /// Moves a clip onto the tracks of the clip `like`'s device.
    private func moveClip(_ id: String, like: String) throws -> [String: Any] {
        guard let session else { throw ServerError("no hay proyecto abierto") }
        stopAhead()
        do { try session.project.move(id, like: like) } catch let e as EditError { throw ServerError(e.description) }
        saveBuilt()
        return edited(session)
    }

    private func edited(_ session: SyncSession) -> [String: Any] {
        var out: [String: Any] = ["project": describe(session.project, path: fileURL?.path ?? "")]
        if let outcome { out["outcome"] = describe(outcome, session) }
        return out
    }

    /// A project built from folders is Synco's own file: written again as it is now.
    private func saveBuilt() {
        guard isBuilt, let session, let url = fileURL, let sources = ProjectBuilder.sources(of: session.project) else { return }
        _ = try? ProjectBuilder.build(sources, name: session.project.sequenceName, to: url)
    }

    private func nudge(_ id: String, by frames: Int) throws -> [String: Any] {
        guard let session, var current = outcome else { throw ServerError("primero hay que sincronizar") }
        current.nudge(id, by: frames)
        outcome = current
        return ["starts": current.starts, "manual": current.manual, "report": session.report(current)]
    }

    /// The synced sound from timeline second `from`, a WAV in base64 (see SyncSession.preview).
    private func preview(_ msg: [String: Any]) throws -> [String: Any] {
        guard let session, let outcome else { throw ServerError("primero hay que sincronizar") }
        let from = msg["from"] as? Double ?? 0, length = min(60, msg["length"] as? Double ?? 15)
        let rate = 24000.0
        let samples = session.preview(outcome, from: from, length: length, muted: Set(msg["muted"] as? [String] ?? []), rate: rate)
        return ["from": from, "length": length, "wav": wavData(samples, rate: rate).base64EncodedString()]
    }

    private func describe(_ result: SyncOutcome, _ session: SyncSession) -> [String: Any] {
        let quality: (Placement) -> String = {
            switch result.quality($0) { case .exact: return "exact"; case .approximate: return "approximate"; case .guessed: return "guessed" }
        }
        let fps = Double(session.project.fps)
        let agreed = result.checks.filter { ($0.error.map { abs($0) * fps <= 1 }) ?? false }.count
        return [
            "placements": result.placements.map { p -> [String: Any] in
                var d: [String: Any] = ["id": p.id, "time": p.time, "method": p.method.rawValue, "z": Double(p.z),
                                        "ratio": Double(p.ratio), "note": p.note, "quality": quality(p)]
                if let e = p.clockError { d["clockError"] = e }
                return d
            },
            "starts": result.starts,
            "manual": result.manual,
            "synced": result.synced,
            "seconds": result.seconds,
            "checks": result.checks.count,
            "agreed": agreed,
            "overlaps": result.overlaps.count,
            "report": session.report(result),
            "warnings": result.warnings,
            "drones": result.drones.map { d -> [String: Any] in
                ["name": d.name, "folder": d.folder, "summary": d.summary,
                 "clips": d.clips.map { c -> [String: Any] in
                     ["id": c.fileID, "name": c.name, "track": d.name, "device": c.device, "deviceName": d.name,
                      "folder": d.folder, "folderPath": c.folder, "path": c.url.path, "hasVideo": true, "frames": c.frames, "exists": c.exists]
                 }]
            },
        ]
    }

    private func export(_ msg: [String: Any]) throws -> [String: Any] {
        guard let session, let outcome else { throw ServerError("primero hay que sincronizar") }
        let o = msg["options"] as? [String: Any] ?? [:]
        var options = ExportOptions()
        if let v = o["syncedLabel"] as? String { options.syncedLabel = v }
        if let v = o["approxLabel"] as? String { options.approxLabel = v }
        if let v = o["unsyncedLabel"] as? String { options.unsyncedLabel = v }
        if let v = o["disableUnsynced"] as? Bool { options.disableUnsynced = v }
        if let v = o["sequenceSuffix"] as? String { options.sequenceSuffix = v }
        if let v = o["writeReport"] as? Bool { options.writeReport = v }
        guard let path = msg["path"] as? String else { throw ServerError("falta el destino") }
        try session.export(outcome, to: URL(fileURLWithPath: path), options: options)
        return ["path": path]
    }

    private func relink(_ folder: String) throws -> [String: Any] {
        guard let session, let fileURL else { throw ServerError("no hay proyecto abierto") }
        let project = session.project
        let missing = project.clips.filter { !$0.exists }
        let wanted = Dictionary(grouping: missing, by: { $0.url.lastPathComponent.lowercased() })
        var found = 0
        let walker = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard let clips = wanted[url.lastPathComponent.lowercased()] else { continue }
            for clip in clips where !clip.exists {
                project.relink(clip, to: url)
                session.forget(clip.fileID)
                found += 1
            }
        }
        outcome = nil
        return ["found": found, "project": describe(project, path: fileURL.path)]
    }

    // MARK: Cache

    private func cacheSize() -> Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: defaultCacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func clearCache(days: Int?) {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: defaultCacheDir, includingPropertiesForKeys: keys)) ?? []
        let limit = Date().addingTimeInterval(-Double(days ?? 0) * 86400)
        for f in files where ["f32", "matches"].contains(f.pathExtension) {
            let used = (try? f.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
            if days == nil || used < limit { try? FileManager.default.removeItem(at: f) }
        }
    }

    // MARK: Updates (same update.json as the macOS app)

    private static let manifest = "https://github.com/clipxel/Synco/releases/latest/download/update.json"

    private func fetch(_ url: URL) throws -> Data {
        if url.isFileURL { return try Data(contentsOf: url) }
        final class Box: @unchecked Sendable { var result: Result<Data, Error> = .failure(ServerError("sin conexión")) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("Synco/\(engineVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200 { box.result = .success(data) }
            else if let error { box.result = .failure(error) }
            done.signal()
        }.resume()
        done.wait()
        return try box.result.get()
    }

    private func checkUpdate(_ msg: [String: Any]) throws -> [String: Any] {
        let current = msg["current"] as? String ?? engineVersion
        let source = ProcessInfo.processInfo.environment["SYNCO_UPDATE_MANIFEST"] ?? Self.manifest
        guard let url = URL(string: source),
              let root = try? JSONSerialization.jsonObject(with: fetch(url)) as? [String: Any],
              let version = root["version"] as? String else { return ["available": false] }
        #if os(Windows)
        let key = "windows"
        #else
        let key = "linux"
        #endif
        guard let asset = (root["assets"] as? [String: Any])?[key] as? [String: Any],
              let link = asset["url"] as? String, let sha = (asset["sha256"] as? String)?.lowercased(),
              let file = asset["file"] as? String, sha.count == 64, !file.contains("/"),
              link.hasPrefix("https://github.com/clipxel/Synco/releases/download/") || link.hasPrefix("file:"),
              compareVersions(version, current) > 0 else { return ["available": false, "version": version] }
        update = (version, link, sha, file)
        return ["available": true, "version": version, "notes": root["notes"] as? String ?? ""]
    }

    private func downloadUpdate() throws -> [String: Any] {
        guard let update, let url = URL(string: update.url) else { throw ServerError("no hay versión nueva") }
        send(["event": "update", "step": "downloading", "progress": 0.1])
        let data = try fetch(url)
        send(["event": "update", "step": "verifying", "progress": 1])
        guard sha256Hex(data) == update.sha256 else { throw ServerError("el archivo descargado no coincide con el publicado") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Synco-update")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(update.file)
        try data.write(to: file)
        return ["file": file.path]
    }

    /// Windows: runs the new installer silently once the app has closed, then opens Synco again.
    /// Linux (AppImage): puts the new AppImage over the running one and opens it.
    private func installUpdate(_ msg: [String: Any]) throws -> [String: Any] {
        guard let file = msg["file"] as? String else { throw ServerError("falta el instalador") }
        let pid = msg["pid"] as? Int ?? 0
        let p = Process()
        #if os(Windows)
        let app = msg["app"] as? String ?? ""
        let script = "Start-Sleep -Milliseconds 800; while (Get-Process -Id \(pid) -ErrorAction SilentlyContinue) { Start-Sleep -Milliseconds 200 }; "
            + "Start-Process -FilePath '\(file)' -ArgumentList '/S' -Wait; Start-Process -FilePath '\(app)'"
        p.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe")
        p.arguments = ["-NoProfile", "-WindowStyle", "Hidden", "-Command", script]
        #else
        guard let target = msg["appImage"] as? String, !target.isEmpty else {
            throw ServerError("esta instalación no se actualiza sola: bajá la versión nueva desde la página")
        }
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + "cp '\(file)' '\(target).new' && chmod +x '\(target).new' && mv '\(target).new' '\(target)' && '\(target)' >/dev/null 2>&1 &"
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        #endif
        try p.run()
        return ["started": true]
    }
}

struct ServerError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
}

func compareVersions(_ a: String, _ b: String) -> Int {
    func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 } }
    let x = parts(a), y = parts(b)
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
        if p != q { return p < q ? -1 : 1 }
    }
    return 0
}
