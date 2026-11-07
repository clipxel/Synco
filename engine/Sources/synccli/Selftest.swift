import Foundation
import SyncCore

/// `synccli selftest <folder>`: builds a small project whose answer is known and syncs it, on
/// any system. A 6-minute "recorder" of speech-like noise; two cameras whose clips are pieces
/// of it with their own noise and colour (one with its clock 5 s off); and one clip recorded
/// when nothing else was. Every clip with common audio must land within a frame of the truth,
/// and the one without must not be "found".
enum Selftest {
    static let fps = 25
    static let rate = 16000

    struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    static func run(folder: URL, cache: AudioCache) throws -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var rng = Rng(state: 42)

        // The recorder: bursts of band-limited noise ("syllables") with pauses, plus a hum.
        let seconds = 360
        var master = [Float](repeating: 0, count: seconds * rate)
        var t = 0
        while t < master.count {
            let length = Int((0.08 + 0.35 * rng.next()) * Double(rate))
            let gap = Int((0.02 + 0.4 * rng.next()) * Double(rate))
            let level = Float(0.2 + 0.6 * rng.next())
            var low: Float = 0
            for i in 0..<length where t + i < master.count {
                let env = sinf(Float.pi * Float(i) / Float(length))
                let white = Float(rng.next() * 2 - 1)
                low += 0.25 * (white - low)          // a soft low-pass: voice-like colour
                master[t + i] = level * env * low
            }
            t += length + gap
        }
        for i in master.indices { master[i] += 0.01 * sinf(2 * .pi * 50 * Float(i) / Float(rate)) }

        let start = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                   year: 2026, month: 1, day: 10, hour: 20, minute: 0, second: 0).date!
        func stamp(_ offset: Double) -> String {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd_HHmmss"
            f.timeZone = .current
            return f.string(from: start.addingTimeInterval(offset))
        }

        struct Item { let name: String; let track: String; let video: Bool; let truth: Double?; let frames: Int }
        var items = [Item]()

        func write(_ samples: [Float], _ name: String) throws {
            try wav(samples).write(to: folder.appendingPathComponent(name))
        }
        let recorderName = "\(stamp(0))_REC.wav"
        try write(master, recorderName)
        items.append(Item(name: recorderName, track: "A3", video: false, truth: 0, frames: seconds * fps))

        // Camera clips: (camera, start in the recorder, length); camera 2's clock runs 5 s fast.
        let clips: [(cam: Int, at: Double, length: Double)] = [
            (1, 12, 40), (1, 70, 25), (1, 130, 55), (1, 230, 30), (1, 300, 45),
            (2, 20, 35), (2, 95, 50), (2, 180, 20), (2, 260, 60),
        ]
        for (n, c) in clips.enumerated() {
            let a = Int(c.at * Double(rate)), b = min(master.count, a + Int(c.length * Double(rate)))
            var piece = Array(master[a..<b])
            // Another microphone: different level, a little high-pass, its own noise.
            var previous: Float = 0
            let gain = Float(0.4 + 0.8 * rng.next())
            for i in piece.indices {
                let x = piece[i]
                piece[i] = gain * (x - 0.6 * previous) + Float(0.04 * (rng.next() * 2 - 1))
                previous = x
            }
            let clockError = c.cam == 2 ? 5.0 : 0.3
            let name = "\(stamp(c.at + clockError))_CAM\(c.cam)_\(n + 1).wav"
            try write(piece, name)
            items.append(Item(name: name, track: "V\(c.cam)", video: true, truth: c.at, frames: Int(c.length * Double(fps))))
        }
        // Recorded while the recorder was off: only noise, nothing in common.
        var lonely = [Float](repeating: 0, count: 20 * rate)
        for i in lonely.indices { lonely[i] = Float(0.3 * (rng.next() * 2 - 1)) }
        let lonelyName = "\(stamp(400))_CAM1_solo.wav"
        try write(lonely, lonelyName)
        items.append(Item(name: lonelyName, track: "V1", video: true, truth: nil, frames: 20 * fps))

        let xmlURL = folder.appendingPathComponent("selftest.xml")
        try xml(items.map { ($0.name, $0.track, $0.frames) }, folder: folder).write(to: xmlURL, atomically: true, encoding: .utf8)

        // Sync it like the app does.
        let project = try FCP7Project(url: xmlURL)
        let session = SyncSession(project: project, cache: cache, rate: 4000)
        try session.readAudio()
        guard session.problems.isEmpty else {
            print("FALLA: no se pudo leer el audio: \(session.problems)")
            return false
        }
        let outcome = try session.sync()
        let byName = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.name, $0.fileID) })
        let placements = Dictionary(uniqueKeysWithValues: outcome.placements.map { ($0.id, $0) })
        let recorder = placements[byName[recorderName]!]!.time
        var ok = true
        for item in items where item.name != recorderName {
            guard let p = placements[byName[item.name]!] else { print("FALLA: \(item.name) sin ubicar"); ok = false; continue }
            if let truth = item.truth {
                let error = (p.time - recorder) - truth
                let good = p.method.synced && abs(error) * Double(fps) <= 1
                print(String(format: "%@  %-36@ %@  error %+.3f s", good ? "PASA " : "FALLA", item.name, p.method.rawValue, error))
                ok = ok && good
            } else {
                let good = !p.method.synced
                print("\(good ? "PASA " : "FALLA")  \(item.name.padding(toLength: 36, withPad: " ", startingAt: 0)) \(p.method.rawValue) (no tiene audio en común: no se tiene que encontrar)")
                ok = ok && good
            }
        }
        // The exported XML keeps every item and no clip covers another on a track.
        let out = folder.appendingPathComponent("selftest - sincronizado.xml")
        try session.export(outcome, to: out)
        let reread = try FCP7Project(url: out)
        let sameItems = reread.clips.count == project.clips.count
        print("\(sameItems ? "PASA " : "FALLA")  XML exportado con los \(project.clips.count) clips")
        ok = ok && sameItems
        // The fast search (a few clips everywhere, the rest near their clock) lands them the same.
        var fast = SyncOptions()
        fast.speed = .fast
        let quick = try session.sync(options: fast)
        let same = quick.placements.allSatisfy { q in
            guard let p = placements[q.id] else { return false }
            return p.method.synced == q.method.synced && abs(p.time - q.time) * Double(fps) <= 1
        }
        print("\(same ? "PASA " : "FALLA")  modo rápido: el mismo resultado")
        ok = ok && same
        ok = try ntscSequence(folder: folder, cache: cache, items: items.map { ($0.name, $0.track, $0.truth, $0.frames) },
                              recorder: recorderName) && ok
        ok = try fromFolders(folder: folder, cache: cache, items: items.map { ($0.name, $0.track, $0.truth) }, recorder: recorderName) && ok
        ok = try EditTest.run(folder: folder, cache: cache, recorder: recorderName) && ok
        ok = mediaInfo() && ok
        ok = midnight() && ok
        ok = splitRecorder() && ok
        ok = try DroneTest.run(folder: folder.appendingPathComponent("dron"), cache: cache) && ok
        ok = try FormatTest.run(folder: folder.appendingPathComponent("formatos"), master: master, rate: rate,
                                recorder: folder.appendingPathComponent(recorderName), cache: cache) && ok
        print(ok ? "selftest: todo bien" : "selftest: HAY FALLAS")
        return ok
    }

    /// The same project in a 29.97 sequence (timebase 30, NTSC): a frame there is 1001/30000 s, and
    /// the exported XML, read with that rate, must put every clip within a frame of the truth.
    /// (Counting 30 frames a second would put a clip 6 minutes in about a third of a second off.)
    static func ntscSequence(folder: URL, cache: AudioCache, items: [(name: String, track: String, truth: Double?, frames: Int)],
                             recorder: String) throws -> Bool {
        let rate = 30000.0 / 1001
        let converted = items.map { ($0.name, $0.track, Int((Double($0.frames) / Double(fps) * rate).rounded())) }
        let text = xml(converted, folder: folder).replacingOccurrences(of: "<timebase>\(fps)</timebase>",
                                                                       with: "<timebase>30</timebase><ntsc>TRUE</ntsc>")
        let xmlURL = folder.appendingPathComponent("ntsc.xml")
        try text.write(to: xmlURL, atomically: true, encoding: .utf8)
        let project = try FCP7Project(url: xmlURL)
        let session = SyncSession(project: project, cache: cache, rate: 4000)
        try session.readAudio()
        let outcome = try session.sync()
        let out = folder.appendingPathComponent("ntsc - sincronizado.xml")
        try session.export(outcome, to: out)
        // The exported frames, turned into seconds by hand at 29.97.
        let doc = try String(contentsOf: out, encoding: .utf8)
        var start = [String: Double]()
        for part in doc.components(separatedBy: "<clipitem").dropFirst() {
            func value(_ tag: String) -> Int? {
                guard let a = part.range(of: "<\(tag)>"), let b = part.range(of: "</\(tag)>", range: a.upperBound..<part.endIndex) else { return nil }
                return Int(part[a.upperBound..<b.lowerBound])
            }
            guard let a = part.range(of: "<name>"), let b = part.range(of: "</name>"), let s = value("start") else { continue }
            let name = String(part[a.upperBound..<b.lowerBound])
            if start[name] == nil { start[name] = Double(s - (value("in") ?? 0)) / rate }
        }
        guard let zero = start[recorder] else { print("FALLA  secuencia 29,97: falta el grabador"); return false }
        var ok = true, worst = 0.0
        for item in items where item.name != recorder {
            guard let truth = item.truth, let s = start[item.name] else { continue }
            let error = abs((s - zero) - truth)
            worst = max(worst, error)
            ok = ok && error * rate <= 1.01
        }
        print(String(format: "%@  secuencia 29,97 (NTSC): todos a un cuadro o menos en el XML (peor %.0f ms)", ok ? "PASA " : "FALLA", worst * 1000))
        return ok
    }

    /// The same files sorted into one folder per device, dropped as the shoot's folder: three
    /// tracks, built and synced like the XML (every clip with common audio within a frame).
    static func fromFolders(folder: URL, cache: AudioCache, items: [(name: String, track: String, truth: Double?)],
                            recorder: String) throws -> Bool {
        let fm = FileManager.default
        let shoot = folder.appendingPathComponent("rodaje")
        for item in items {
            let dir = shoot.appendingPathComponent(item.track == "A3" ? "SONIDO" : "CAM \(item.track.dropFirst())")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try fm.copyItem(at: folder.appendingPathComponent(item.name), to: dir.appendingPathComponent(item.name))
        }
        let sources = ProjectBuilder.sources(from: [shoot])
        let names = sources.map(\.name).sorted()
        guard names == ["CAM 1", "CAM 2", "SONIDO"] else { print("FALLA  carpetas: pistas \(names)"); return false }
        let xmlURL = folder.appendingPathComponent("carpetas.xml")
        let skipped = try ProjectBuilder.build(sources, name: "carpetas", to: xmlURL)
        let project = try FCP7Project(url: xmlURL)
        guard skipped.isEmpty, project.clips.count == items.count, Set(project.clips.map(\.device)).count == 3 else {
            print("FALLA  carpetas: \(project.clips.count) clips, \(skipped.count) afuera"); return false
        }
        let session = SyncSession(project: project, cache: cache, rate: 4000)
        try session.readAudio()
        let outcome = try session.sync()
        let byName = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.name, $0.fileID) })
        let placements = Dictionary(uniqueKeysWithValues: outcome.placements.map { ($0.id, $0) })
        let zero = placements[byName[recorder]!]!.time
        var ok = true
        for item in items where item.name != recorder {
            guard let p = placements[byName[item.name]!] else { ok = false; continue }
            if let truth = item.truth {
                ok = ok && p.method.synced && abs((p.time - zero) - truth) * Double(fps) <= 1
            } else {
                ok = ok && !p.method.synced
            }
        }
        print("\(ok ? "PASA " : "FALLA")  proyecto armado desde carpetas: 3 pistas, \(project.clips.count) clips, sincronizado igual")
        return ok
    }

    /// A console recorder that cuts its take into files of the same length, one right after the
    /// other, with file dates that wrongly say there were 15 and 25 s between them; a camera
    /// clip straddles the first cut. The files must follow each other with no gap and the camera
    /// clip must land where it was recorded.
    static func splitRecorder() -> Bool {
        let rate = 4000.0
        var rng = Rng(state: 7)
        let total = 1500 * Int(rate)
        var take = [Float](repeating: 0, count: total)
        var low: Float = 0
        for i in take.indices {
            low += 0.2 * (Float(rng.next() * 2 - 1) - low)
            take[i] = low * (0.3 + 0.7 * Float(abs(sin(Double(i) / rate * 1.3))))
        }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let part = 600 * Int(rate)
        let starts = [0.0, 615.0, 1225.0]          // what the dates say (true: 0, 600, 1200)
        var clips = (0..<3).map { k -> SyncClip in
            let a = k * part, b = min(total, a + part)
            return SyncClip(id: "rec\(k)", name: "TASCAM_000\(k + 1).wav", device: "consola",
                            audio: AudioTrack(samples: Array(take[a..<b]), rate: rate),
                            recordedAt: t0.addingTimeInterval(starts[k]), duration: Double(b - a) / rate)
        }
        // The camera: from 570 to 650 s of the take, with its own noise; its clock is right.
        var cam = Array(take[(570 * Int(rate))..<(650 * Int(rate))])
        for i in cam.indices { cam[i] = 0.8 * cam[i] + Float(0.05 * (rng.next() * 2 - 1)) }
        clips.append(SyncClip(id: "cam", name: "C0001.MP4", device: "cámara", audio: AudioTrack(samples: cam, rate: rate),
                              recordedAt: t0.addingTimeInterval(570), duration: 80))
        // Another camera, its clock years off: one clip found by audio, one with nothing in common.
        var cam2 = Array(take[(900 * Int(rate))..<(960 * Int(rate))])
        for i in cam2.indices { cam2[i] = 0.7 * cam2[i] + Float(0.05 * (rng.next() * 2 - 1)) }
        let years = 3 * 365 * 86400.0
        clips.append(SyncClip(id: "cam2a", name: "A001.MOV", device: "teléfono", audio: AudioTrack(samples: cam2, rate: rate),
                              recordedAt: t0.addingTimeInterval(years + 900), duration: 60))
        let noise = (0..<(30 * Int(rate))).map { _ in Float(0.3 * (rng.next() * 2 - 1)) }
        clips.append(SyncClip(id: "cam2b", name: "A002.MOV", device: "teléfono", audio: AudioTrack(samples: noise, rate: rate),
                              recordedAt: t0.addingTimeInterval(2 * years), duration: 30))
        let syncer = Syncer(clips: clips, rate: rate) { _ in }
        syncer.soundOnly = ["consola"]
        let placed = Dictionary(uniqueKeysWithValues: syncer.run().map { ($0.id, $0.time) })
        let zero = placed["rec0"] ?? 0
        let ok = abs((placed["rec1"] ?? 0) - zero - 600) < 0.01 && abs((placed["rec2"] ?? 0) - zero - 1200) < 0.01
            && abs((placed["cam"] ?? 0) - zero - 570) * Double(fps) <= 1
        print("\(ok ? "PASA " : "FALLA")  consola que corta por tamaño: los archivos van seguidos, sin huecos")
        let lost = (placed["cam2b"] ?? 1e12) - zero
        let inside = lost >= -3600 && lost <= 1500 + 3600
        print("\(inside ? "PASA " : "FALLA")  cámara con el reloj años corrido: lo que no tiene audio en común queda dentro del evento")
        return ok && inside
    }

    /// A recorder's files in name order: 22:30, 23:40, then 00:50 and 02:00 written with the first
    /// day (its clock only knows the time of day). Those two go to the next day; nothing else moves,
    /// and files named in no particular order are left alone.
    static func midnight() -> Bool {
        let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                 year: 2026, month: 3, day: 7).date!
        func at(_ h: Double) -> Date { day.addingTimeInterval(h * 3600) }
        let fixed = fixDayRollover([at(22.5), at(23.67), at(0.83), at(2), nil, at(2.5)])
        let night = fixed == [at(22.5), at(23.67), at(24.83), at(26), nil, at(26.5)]
        let untouched = fixDayRollover([at(23), at(10), at(12)]) == [at(23), at(10), at(12)]
        let ok = night && untouched
        print("\(ok ? "PASA " : "FALLA")  set que pasa la medianoche: los archivos siguen en el orden en que se grabaron")
        return ok
    }

    /// What ffmpeg says about a portrait phone clip, read as its size, rate and sound.
    static func mediaInfo() -> Bool {
        let text = """
          Duration: 00:01:02.50, start: 0.000000, bitrate: 15000 kb/s
          Stream #0:0[0x1](und): Video: hevc (Main) (hvc1 / 0x31637668), yuv420p(tv, bt709), 1920x1080, 14000 kb/s, 29.97 fps, 29.97 tbr, 600 tbn (default)
              displaymatrix: rotation of -90.00 degrees
          Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 48000 Hz, stereo, fltp, 192 kb/s (default)
        """
        // Windows' ffmpeg ends lines with CR LF, which Swift reads as one character.
        let i = parseMediaInfoForTest(text.replacingOccurrences(of: "\n", with: "\r\n"))
        let ok = abs(i.duration - 62.5) < 0.01 && i.hasVideo && i.width == 1080 && i.height == 1920
            && abs(i.fps - 29.97) < 0.001 && i.channels == 2 && i.sampleRate == 48000
        print("\(ok ? "PASA " : "FALLA")  datos de un video vertical de teléfono (ffmpeg, líneas de Windows)")
        // Rates as files report them, to the standard ones a sequence uses.
        let rates: [(Double, Int, Bool)] = [(29.83, 30, true), (30.02, 30, false), (29.9, 30, true), (29.97, 30, true), (23.976, 24, true), (24, 24, false),
                                            (25, 25, false), (50, 50, false), (59.94, 60, true), (60, 60, false), (119.88, 120, true)]
        let snapped = rates.allSatisfy { r in let x = ProjectBuilder.rateForTest(r.0); return x.timebase == r.1 && x.ntsc == r.2 }
        print("\(snapped ? "PASA " : "FALLA")  velocidades de filmación distintas (29,83 de un teléfono es 29,97)")
        return ok && snapped
    }

    /// 16-bit mono PCM WAV.
    static func wav(_ samples: [Float]) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + samples.count * 2)); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(samples.count * 2))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices { pcm[i] = Int16(max(-1, min(1, samples[i])) * 32000) }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }

    /// A Final Cut Pro 7 XML like Premiere's: each device on its own track, clips end to end.
    static func xml(_ items: [(name: String, track: String, frames: Int)], folder: URL) -> String {
        var video = [String: [String]](), audio = [String: [String]]()
        var position = [String: Int]()
        for (i, item) in items.enumerated() {
            let id = "file-\(i + 1)"
            let path = folder.appendingPathComponent(item.name).absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")
            let at = position[item.track] ?? 0
            position[item.track] = at + item.frames
            let file = """
            <file id="\(id)"><name>\(item.name)</name><pathurl>\(path)</pathurl><duration>\(item.frames)</duration>\
            <rate><timebase>\(fps)</timebase></rate><media><audio><channelcount>1</channelcount></audio></media></file>
            """
            let clip = { (kind: String) in
                "<clipitem id=\"\(kind)-\(i + 1)\"><name>\(item.name)</name><duration>\(item.frames)</duration>"
                    + "<rate><timebase>\(fps)</timebase></rate><start>\(at)</start><end>\(at + item.frames)</end>"
                    + "<in>0</in><out>\(item.frames)</out>\(file)</clipitem>"
            }
            if item.track.hasPrefix("V") {
                video[item.track, default: []].append(clip("v"))
                audio["A" + item.track.dropFirst(), default: []].append(clip("a"))
            } else {
                audio[item.track, default: []].append(clip("a"))
            }
        }
        func tracks(_ t: [String: [String]]) -> String {
            t.keys.sorted().map { "<track>\(t[$0]!.joined())</track>" }.joined()
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE xmeml>
        <xmeml version="4"><sequence id="seq"><name>selftest</name><duration>9000</duration>\
        <rate><timebase>\(fps)</timebase></rate><media><video>\(tracks(video))</video><audio>\(tracks(audio))</audio></media>\
        </sequence></xmeml>
        """
    }
}
