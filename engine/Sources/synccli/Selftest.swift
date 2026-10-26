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
        print(ok ? "selftest: todo bien" : "selftest: HAY FALLAS")
        return ok
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
