import Foundation
import SyncCore

/// Every container and codec a camera, phone or recorder writes has to be read and synced: one
/// clip of the self-test's recorder in each, written with ffmpeg, each in a folder of its own,
/// built into a project and synced. Each must be read (its picture too) and land on its place.
/// Without an ffmpeg that writes a format (it is only for writing the test files), that one is
/// left out and said so.
enum FormatTest {
    struct Format {
        let ext: String
        let label: String
        /// ffmpeg's output options; nil video means sound only.
        let video: [String]?
        let audio: [String]
        var muxer: [String] = []
        /// Picture size the codec accepts.
        var size = "160x96"
        var rate48 = false
    }

    static let formats: [Format] = [
        Format(ext: "mov", label: "QuickTime ProRes + PCM", video: ["-c:v", "prores_ks", "-profile:v", "0"], audio: ["-c:a", "pcm_s24le"]),
        Format(ext: "mp4", label: "MP4 MPEG-4 + AAC", video: ["-c:v", "mpeg4"], audio: ["-c:a", "aac"]),
        Format(ext: "m4v", label: "M4V", video: ["-c:v", "mpeg4"], audio: ["-c:a", "aac"], muxer: ["-f", "mp4"]),
        Format(ext: "insv", label: "Insta360 (MP4)", video: ["-c:v", "mpeg4"], audio: ["-c:a", "aac"], muxer: ["-f", "mp4"]),
        Format(ext: "3gp", label: "3GP celular viejo", video: ["-c:v", "h263"], audio: ["-c:a", "aac", "-ar", "16000"], size: "176x144"),
        Format(ext: "mkv", label: "Matroska + FLAC", video: ["-c:v", "mpeg4"], audio: ["-c:a", "flac"]),
        Format(ext: "avi", label: "AVI MJPEG + PCM", video: ["-c:v", "mjpeg", "-pix_fmt", "yuvj420p"], audio: ["-c:a", "pcm_s16le"]),
        Format(ext: "mts", label: "AVCHD (MPEG-TS) + AC-3", video: ["-c:v", "mpeg2video"], audio: ["-c:a", "ac3", "-ar", "48000"], muxer: ["-f", "mpegts"]),
        Format(ext: "m2ts", label: "M2TS (Blu-ray) + AC-3", video: ["-c:v", "mpeg2video"], audio: ["-c:a", "ac3", "-ar", "48000"],
               muxer: ["-f", "mpegts", "-mpegts_m2ts_mode", "1"]),
        Format(ext: "ts", label: "MPEG-TS + MP2", video: ["-c:v", "mpeg2video"], audio: ["-c:a", "mp2", "-ar", "48000"], muxer: ["-f", "mpegts"]),
        Format(ext: "mpg", label: "MPEG-2 PS + MP2", video: ["-c:v", "mpeg2video"], audio: ["-c:a", "mp2", "-ar", "48000"], muxer: ["-f", "mpeg"]),
        Format(ext: "vob", label: "DVD (VOB) + AC-3", video: ["-c:v", "mpeg2video"], audio: ["-c:a", "ac3", "-ar", "48000"], muxer: ["-f", "vob"]),
        Format(ext: "mxf", label: "MXF DV + PCM", video: ["-c:v", "dvvideo", "-pix_fmt", "yuv420p"], audio: ["-c:a", "pcm_s16le"],
               muxer: ["-f", "mxf"], size: "720x576", rate48: true),
        Format(ext: "dv", label: "DV", video: ["-c:v", "dvvideo", "-pix_fmt", "yuv420p"], audio: ["-c:a", "pcm_s16le"],
               muxer: ["-f", "dv"], size: "720x576", rate48: true),
        Format(ext: "wmv", label: "Windows Media", video: ["-c:v", "wmv2"], audio: ["-c:a", "wmav2"], muxer: ["-f", "asf"]),
        // PCM: FLV doesn't say how much silence an AAC encoder puts first (64 ms here), so with AAC
        // the test file itself would be off, not the reading.
        Format(ext: "flv", label: "Flash Video", video: ["-c:v", "flv1"], audio: ["-c:a", "pcm_s16le", "-ar", "44100"]),
        Format(ext: "webm", label: "WebM VP9 + Opus", video: ["-c:v", "libvpx-vp9", "-deadline", "realtime", "-cpu-used", "8"],
               audio: ["-c:a", "libopus"]),
        Format(ext: "ogv", label: "Ogg Theora + Vorbis", video: ["-c:v", "libtheora"], audio: ["-c:a", "libvorbis"]),
        // Sound only.
        Format(ext: "wav", label: "WAV 24 bits 48 kHz", video: nil, audio: ["-c:a", "pcm_s24le", "-ar", "48000"]),
        Format(ext: "w64", label: "Wave64", video: nil, audio: ["-c:a", "pcm_s16le"]),
        Format(ext: "aiff", label: "AIFF", video: nil, audio: ["-c:a", "pcm_s16be"]),
        Format(ext: "caf", label: "CAF", video: nil, audio: ["-c:a", "pcm_s16le"]),
        Format(ext: "flac", label: "FLAC", video: nil, audio: ["-c:a", "flac"]),
        Format(ext: "m4a", label: "M4A AAC", video: nil, audio: ["-c:a", "aac"], muxer: ["-f", "mp4"]),
        Format(ext: "mp3", label: "MP3", video: nil, audio: ["-c:a", "libmp3lame", "-b:a", "128k"]),
        Format(ext: "ogg", label: "Ogg Vorbis", video: nil, audio: ["-c:a", "libvorbis"]),
        Format(ext: "opus", label: "Opus", video: nil, audio: ["-c:a", "libopus"]),
        Format(ext: "wma", label: "WMA", video: nil, audio: ["-c:a", "wmav2"], muxer: ["-f", "asf"]),
        Format(ext: "ac3", label: "AC-3", video: nil, audio: ["-c:a", "ac3", "-ar", "48000"]),
        Format(ext: "mka", label: "Matroska audio", video: nil, audio: ["-c:a", "flac"]),
    ]

    /// The ffmpeg that writes the test files: SYNCO_FFMPEG_WRITER (a full one, where the app's own
    /// only reads, as on the Mac), else the one the engine reads with.
    static func ffmpeg() -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["SYNCO_FFMPEG_WRITER", "SYNCO_FFMPEG"] {
            if let p = env[key], FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static func run(folder: URL, master: [Float], rate: Int, recorder: URL, cache: AudioCache) throws -> Bool {
        guard let exe = ffmpeg() else {
            print("OMITE  formatos de video: hace falta SYNCO_FFMPEG para escribir los archivos de prueba")
            return true
        }
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        let shoot = folder.appendingPathComponent("rodaje")
        try fm.createDirectory(at: shoot.appendingPathComponent("SONIDO"), withIntermediateDirectories: true)
        try fm.copyItem(at: recorder, to: shoot.appendingPathComponent("SONIDO").appendingPathComponent(recorder.lastPathComponent))

        // Each clip: 8 s of the recorder, its own microphone colour, and a picture that changes.
        let length = 8.0, fps = 25
        let frames = Int(length) * fps
        var gray = Data(capacity: frames * 160 * 96)
        for f in 0..<frames {
            let level = UInt8(40 + (f * 7) % 180)
            gray.append(contentsOf: [UInt8](repeating: level, count: 160 * 96))
        }
        let picture = folder.appendingPathComponent("imagen.gray")
        try gray.write(to: picture)

        var written = [(format: Format, at: Double, file: String)]()
        var skipped = [String]()
        for (k, f) in formats.enumerated() {
            let at = 15 + Double(k) * 11
            let a = Int(at * Double(rate))
            var piece = Array(master[a..<(a + Int(length * Double(rate)))])
            var previous: Float = 0
            for i in piece.indices { let x = piece[i]; piece[i] = 0.7 * (x - 0.5 * previous); previous = x }
            let source = folder.appendingPathComponent("sonido-\(f.ext).wav")
            try Selftest.wav(piece).write(to: source)
            let dir = shoot.appendingPathComponent("CAM \(f.ext.uppercased())")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = "CLIP_\(f.ext.uppercased()).\(f.ext)"
            let out = dir.appendingPathComponent(name)
            var args = ["-hide_banner", "-nostdin", "-v", "error", "-y"]
            if f.video != nil { args += ["-f", "rawvideo", "-pix_fmt", "gray", "-s", "160x96", "-r", "\(fps)", "-i", picture.path] }
            args += ["-i", source.path]
            if let v = f.video {
                args += ["-map", "0:v", "-map", "1:a", "-vf", "scale=\(f.size),format=yuv420p"] + v
            }
            args += f.audio
            if f.rate48 { args += ["-ar", "48000", "-ac", "2"] }
            args += f.muxer + ["-strict", "experimental", out.path]
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let err = Pipe()
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            try p.run()
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            try? fm.removeItem(at: source)
            if p.terminationStatus != 0 || !fm.fileExists(atPath: out.path) {
                // This ffmpeg can't write it (no such encoder): nothing to read.
                skipped.append("\(f.ext) (\(message.split(whereSeparator: \.isNewline).last.map(String.init) ?? "?"))")
                try? fm.removeItem(at: dir)
                continue
            }
            written.append((f, at, name))
        }
        try? fm.removeItem(at: picture)

        let sources = ProjectBuilder.sources(from: [shoot])
        let xmlURL = folder.appendingPathComponent("formatos.xml")
        let unread = try ProjectBuilder.build(sources, name: "formatos", to: xmlURL)
        let project = try FCP7Project(url: xmlURL)
        let session = SyncSession(project: project, cache: cache, rate: 4000)
        try session.readAudio()
        let outcome = try session.sync()
        let byName = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.name, $0) })
        let placements = Dictionary(uniqueKeysWithValues: outcome.placements.map { ($0.id, $0) })
        guard let zero = byName[recorder.lastPathComponent].flatMap({ placements[$0.fileID] })?.time else {
            print("FALLA  formatos: el grabador no se leyó"); return false
        }
        var ok = true
        for w in written {
            let label = "\(w.format.ext.uppercased()) · \(w.format.label)"
            guard let clip = byName[w.file] else {
                let why = unread.contains { $0.lastPathComponent == w.file } ? "no se pudo leer" : "no está en el proyecto"
                print("FALLA  \(label): \(why)"); ok = false; continue
            }
            if let problem = session.problems[clip.fileID] { print("FALLA  \(label): \(problem)"); ok = false; continue }
            let picture = clip.hasVideo == (w.format.video != nil)
            guard let p = placements[clip.fileID] else { print("FALLA  \(label): sin ubicar"); ok = false; continue }
            let error = (p.time - zero) - w.at
            let good = picture && p.method.synced && abs(error) * Double(fps) <= 1
            print(String(format: "%@  %@%@: %@, error %+.3f s", good ? "PASA " : "FALLA", label,
                         picture ? "" : " (la imagen no se leyó)", p.method.rawValue, error))
            ok = ok && good
        }
        if !skipped.isEmpty { print("OMITE  este ffmpeg no escribe: " + skipped.joined(separator: "; ")) }
        print("\(ok ? "PASA " : "FALLA")  formatos: \(written.count) leídos y sincronizados de \(formats.count)")
        return ok
    }
}
