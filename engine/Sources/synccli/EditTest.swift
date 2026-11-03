import Foundation
import SyncCore

/// What the user does by hand once synced (listen, nudge, move, take out), on the project built
/// from folders: each has to land in the exported XML, and the rest has to stay put.
enum EditTest {
    static func run(folder: URL, cache: AudioCache, recorder: String) throws -> Bool {
        let xmlURL = folder.appendingPathComponent("carpetas.xml")
        let project = try FCP7Project(url: xmlURL)
        let session = SyncSession(project: project, cache: cache, rate: 4000)
        try session.readAudio()
        var result: SyncOutcome? = try session.sync()
        let fps = project.fps
        let rec = project.clips.first { $0.name == recorder }!
        let synced = Set(result!.placements.filter { $0.method.synced }.map(\.id))
        let cams = project.clips.filter { $0.device != rec.device && synced.contains($0.fileID) }
        guard let cam = cams.first, let other = cams.first(where: { $0.device != cam.device }) else {
            print("FALLA  edición: faltan clips sincronizados de dos cámaras"); return false
        }
        var ok = true

        // Listening: the recorder alone and the camera alone, in the same stretch, line up.
        func lag(_ outcome: SyncOutcome) -> Double {
            let start = Double(outcome.starts[cam.fileID]!) / fps
            let length = min(6, Double(cam.frames) / fps - 2)
            let rate = 24000.0
            let everyone = Set(project.clips.map(\.fileID))
            let a = session.preview(outcome, from: start + 1, length: length, muted: everyone.subtracting([rec.fileID]), rate: rate)
            let b = session.preview(outcome, from: start + 1, length: length, muted: everyone.subtracting([cam.fileID]), rate: rate)
            let reach = Int(0.2 * rate)
            var best = (lag: 0, score: -Float.infinity)
            for k in -reach...reach {
                var s: Float = 0
                for i in reach..<(a.count - reach) { s += a[i] * b[i + k] }
                if s > best.score { best = (k, s) }
            }
            return Double(best.lag) / rate
        }
        let before = lag(result!)
        var good = abs(before) <= 0.002
        print(String(format: "%@  escuchar: el grabador y %@ suenan juntos (%+.1f ms)", good ? "PASA " : "FALLA", cam.name, before * 1000))
        ok = ok && good

        // Nudged three frames later by hand: heard three frames later, and written so.
        let startBefore = result!.starts[cam.fileID]!
        result!.nudge(cam.fileID, by: 3)
        let after = lag(result!)
        good = abs(after - before - 3 / fps) <= 0.002 && result!.manual[cam.fileID] == 3
        print(String(format: "%@  corrido a mano 3 cuadros: se escucha %.1f ms después", good ? "PASA " : "FALLA", (after - before) * 1000))
        ok = ok && good

        // Moved onto the other camera's track, and another clip taken out.
        try session.project.move(cam.fileID, like: other.fileID)
        let gone = project.clips.last { ![rec.fileID, cam.fileID, other.fileID].contains($0.fileID) }!
        session.removeClip(gone.fileID, from: &result)
        let movedTo = other.deviceName
        let out = folder.appendingPathComponent("edicion - sincronizado.xml")
        try session.export(result!, to: out)
        _ = session.report(result!)
        let reread = try FCP7Project(url: out)
        let byName = Dictionary(uniqueKeysWithValues: reread.clips.map { ($0.name, $0) })
        let movedClip = byName[cam.name]
        let shift = Double((reread.mediaStarts()[movedClip?.fileID ?? ""] ?? -1) - reread.mediaStarts()[byName[rec.name]!.fileID]!) * fps
        let expected = Double(startBefore + 3 - result!.starts[rec.fileID]!)
        good = movedClip?.deviceName == movedTo && byName[gone.name] == nil && reread.clips.count == project.clips.count
            && abs(shift - expected) < 0.01
        print("\(good ? "PASA " : "FALLA")  movido a la pista de \(movedTo ?? "?"), \(gone.name) quitado: así queda en el XML")
        ok = ok && good

        // A clip with picture can't go onto a track with only sound.
        if let video = project.clips.first(where: { $0.hasVideo }) {
            let refused = (try? session.project.move(video.fileID, like: rec.fileID)) == nil
            print("\(refused ? "PASA " : "FALLA")  un clip con imagen no va a la pista de un grabador")
            ok = ok && refused
        }
        return ok
    }
}
