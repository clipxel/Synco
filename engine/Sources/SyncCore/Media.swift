import Foundation
#if canImport(AVFoundation) && !SYNCO_PORTABLE
import Accelerate
import AVFoundation
#endif

/// Mono audio of one media file, resampled to a low analysis rate.
public struct AudioTrack {
    public let samples: [Float]
    public let rate: Double
    public var duration: Double { Double(samples.count) / rate }

    public init(samples: [Float], rate: Double) {
        self.samples = samples
        self.rate = rate
    }
}

public enum MediaError: Error, CustomStringConvertible {
    case noAudio(URL)
    case readFailed(URL, String)
    case missing(URL)

    public var description: String {
        switch self {
        case .missing(let u): return "no existe: \(u.path)"
        case .noAudio(let u): return "sin audio: \(u.lastPathComponent)"
        case .readFailed(let u, let m): return "no se pudo leer \(u.lastPathComponent): \(m)"
        }
    }
}

#if canImport(AVFoundation) && !SYNCO_PORTABLE
/// Decodes every audio track of a file, mixed to mono, at `rate` Hz.
/// AVFoundation only mixes: it decodes at the file's own sample rate, because
/// its resampler is not exact (at 8 kHz it stretches time by about 50 ppm,
/// a third of a second over a 90-minute file). Filtering and decimation happen
/// here, block by block, so a long file never sits in memory at full rate.
public func decodeAudio(url: URL, rate: Double) throws -> AudioTrack {
    let asset = AVURLAsset(url: url)
    let tracks = asset.tracks(withMediaType: .audio)
    guard !tracks.isEmpty else { throw MediaError.noAudio(url) }
    let native = tracks.compactMap { track -> Double? in
        guard let desc = track.formatDescriptions.first else { return nil }
        let fmt = desc as! CMAudioFormatDescription
        return CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee.mSampleRate
    }.max() ?? 48000
    let factor = max(1, Int(native / rate))
    let decimator = Decimator(factor: factor)

    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: native,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else {
        throw MediaError.readFailed(url, reader.error?.localizedDescription ?? "?")
    }
    var block = [Float]()
    while let buffer = output.copyNextSampleBuffer() {
        guard let data = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let count = CMBlockBufferGetDataLength(data) / MemoryLayout<Float>.size
        block.removeAll(keepingCapacity: true)
        block.append(contentsOf: repeatElement(0, count: count))
        block.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: count * 4, destination: raw.baseAddress!)
        }
        decimator.push(block)
    }
    if reader.status == .failed {
        throw MediaError.readFailed(url, reader.error?.localizedDescription ?? "?")
    }
    let decimated = native / Double(factor)
    guard abs(decimated - rate) > 1e-9 else { return AudioTrack(samples: decimator.output, rate: rate) }
    return AudioTrack(samples: interpolate(decimator.output, from: decimated, to: rate), rate: rate)
}

#else

/// Decodes every audio stream of a file, mixed to mono, at `rate` Hz, with ffmpeg (bundled
/// next to the app on Windows and Linux). It decodes at the file's own sample rate, like the
/// macOS path, and the same filter and decimation take it down from there.
public func decodeAudio(url: URL, rate: Double) throws -> AudioTrack {
    let info = FFmpeg.probe(url)
    guard info.audioStreams > 0 else { throw MediaError.noAudio(url) }
    let native = info.sampleRate > 0 ? info.sampleRate : 48000
    var args = ["-v", "error", "-nostdin", "-i", url.path]
    if info.audioStreams > 1 {
        let inputs = (0..<info.audioStreams).map { "[0:a:\($0)]" }.joined()
        args += ["-filter_complex", "\(inputs)amix=inputs=\(info.audioStreams):normalize=0[a]", "-map", "[a]"]
    } else {
        args += ["-map", "0:a:0"]
    }
    args += ["-ac", "1", "-ar", String(Int(native)), "-f", "f32le", "-"]
    let factor = max(1, Int(native / rate))
    let decimator = Decimator(factor: factor)
    try FFmpeg.stream(args) { chunk in decimator.push(chunk) }
    let decimated = native / Double(factor)
    guard abs(decimated - rate) > 1e-9 else { return AudioTrack(samples: decimator.output, rate: rate) }
    return AudioTrack(samples: interpolate(decimator.output, from: decimated, to: rate), rate: rate)
}

/// The bundled ffmpeg: what a file holds, and its audio as raw samples.
enum FFmpeg {
    struct Info { var audioStreams = 0; var sampleRate = 0.0; var creation: Date? }

    static var executable: URL {
        let env = ProcessInfo.processInfo.environment
        if let path = env["SYNCO_FFMPEG"] { return URL(fileURLWithPath: path) }
        #if os(Windows)
        let name = "ffmpeg.exe"
        #else
        let name = "ffmpeg"
        #endif
        let here = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for dir in [here, here.appendingPathComponent("ffmpeg")] {
            let candidate = dir.appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return URL(fileURLWithPath: name)   // on the PATH
    }

    private static let lock = NSLock()
    private static var cache = [String: Info]()

    /// Reads the stream list ffmpeg prints for a file ("Stream #0:1: Audio: aac, 48000 Hz, ...").
    static func probe(_ url: URL) -> Info {
        lock.lock()
        if let hit = cache[url.path] { lock.unlock(); return hit }
        lock.unlock()
        var info = Info()
        let text = (try? run(["-hide_banner", "-nostdin", "-i", url.path], stderrOnly: true)) ?? ""
        for line in text.split(separator: "\n") {
            if line.contains("Stream #"), line.contains("Audio:") {
                info.audioStreams += 1
                if let r = line.range(of: #"(\d+) Hz"#, options: .regularExpression) {
                    info.sampleRate = max(info.sampleRate, Double(line[r].split(separator: " ")[0]) ?? 0)
                }
            } else if info.creation == nil, line.contains("creation_time"),
                      let v = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) {
                let f = ISO8601DateFormatter()
                f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                info.creation = f.date(from: v) ?? ISO8601DateFormatter().date(from: v)
            }
        }
        lock.lock(); cache[url.path] = info; lock.unlock()
        return info
    }

    @discardableResult
    static func run(_ args: [String], stderrOnly: Bool = false) throws -> String {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = stderrOnly ? FileHandle.nullDevice : err
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs ffmpeg writing float32 samples to stdout, handing them over in blocks.
    static func stream(_ args: [String], _ body: ([Float]) -> Void) throws {
        let p = Process()
        p.executableURL = executable
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        var carry = Data()
        while true {
            let data = out.fileHandleForReading.availableData
            if data.isEmpty { break }
            carry.append(data)
            let usable = carry.count - carry.count % 4
            guard usable >= 1 << 16 else { continue }
            let block = carry.prefix(usable).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            carry.removeFirst(usable)
            body(block)
        }
        if carry.count >= 4 {
            let usable = carry.count - carry.count % 4
            body(carry.prefix(usable).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) })
        }
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw MediaError.readFailed(URL(fileURLWithPath: args.last ?? ""), message.split(separator: "\n").last.map(String.init) ?? "ffmpeg")
        }
    }
}
#endif

/// Streaming low-pass (windowed sinc, cut at 90% of the decimated rate's Nyquist)
/// followed by keeping every `factor`th sample.
final class Decimator {
    let factor: Int
    let filter: [Float]
    private var pending = [Float]()
    private(set) var output = [Float]()

    init(factor: Int) {
        self.factor = factor
        let taps = 16 * factor + 1
        let cutoff = 0.45 / Double(factor)
        let mid = Double(taps - 1) / 2
        filter = (0..<taps).map { i in
            let t = Double(i) - mid
            let sinc = t == 0 ? 2 * cutoff : sin(2 * .pi * cutoff * t) / (.pi * t)
            let w = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1)) + 0.08 * cos(4 * .pi * Double(i) / Double(taps - 1))
            return Float(sinc * w)
        }
    }

    func push(_ x: [Float]) {
        guard factor > 1 else { output += x; return }
        pending += x
        let taps = filter.count
        guard pending.count >= taps else { return }
        let count = (pending.count - taps) / factor + 1
        let start = output.count
        output.append(contentsOf: repeatElement(0, count: count))
#if canImport(Accelerate) && !SYNCO_PORTABLE
        output.withUnsafeMutableBufferPointer { out in
            vDSP_desamp(pending, vDSP_Stride(factor), filter, out.baseAddress! + start, vDSP_Length(count), vDSP_Length(taps))
        }
#else
        pending.withUnsafeBufferPointer { a in
            filter.withUnsafeBufferPointer { f in
                for i in 0..<count {
                    var sum: Float = 0
                    let base = i * factor
                    for k in 0..<taps { sum += a[base + k] * f[k] }
                    output[start + i] = sum
                }
            }
        }
#endif
        pending.removeFirst(count * factor)
    }
}

/// Linear interpolation onto an exact rate, for sources whose rate isn't a
/// multiple of the analysis rate (44.1 kHz). The input is already band-limited.
func interpolate(_ x: [Float], from: Double, to: Double) -> [Float] {
    let count = Int(Double(x.count) * to / from)
    let step = from / to
    return (0..<max(0, count - 1)).map { i in
        let p = Double(i) * step
        let j = Int(p)
        guard j + 1 < x.count else { return x[x.count - 1] }
        let f = Float(p - Double(j))
        return x[j] * (1 - f) + x[j + 1] * f
    }
}

/// Decoded audio is cached on disk, keyed by path, size, modification date and rate,
/// so a second run only reads the small cache files.
public final class AudioCache {
    let dir: URL

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func key(_ url: URL, rate: Double) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        var h: UInt64 = 1469598103934665603
        for b in url.path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return "\(url.deletingPathExtension().lastPathComponent)_\(String(h, radix: 16))_\(size)_\(mtime)_\(Int(rate))_v2.f32"
    }

    public func load(_ url: URL, rate: Double) throws -> AudioTrack {
        guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.missing(url) }
        let file = dir.appendingPathComponent(key(url, rate: rate))
        if let data = try? Data(contentsOf: file) {
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            return AudioTrack(samples: samples, rate: rate)
        }
        let track = try decodeAudio(url: url, rate: rate)
        let data = track.samples.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: file, options: .atomic)
        return track
    }
}

/// When the file started recording, from the best source it has:
/// 1. a WAV's broadcast header time reference (samples since midnight on the
///    recorder's clock, exact to the sample), anchored to the right day;
/// 2. the QuickTime creation date cameras and phones write inside MOV/MP4, unless the
///    file date agrees with it (it has fractions of a second);
/// 3. the file's creation date otherwise.
/// The broadcast header's origination *time* is not used: recorders often write it
/// when the file is closed, which for a long take is more than an hour off.
public func recordingStart(url: URL) -> Date? {
    let key = url.path
    startLock.lock()
    if let cached = startCache[key] { startLock.unlock(); return cached }
    startLock.unlock()
    // Linux keeps no creation date: the modification date stands in.
    let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    let fileDate = values?.creationDate ?? values?.contentModificationDate
    var date: Date?
    switch url.pathExtension.lowercased() {
    case "wav", "bwf": date = broadcastStart(url: url, near: fileDate)
    case "mov", "mp4", "m4v", "mxf", "mts", "m4a":
        // Inside the file it is often whole seconds only; the file date has fractions.
        // Keep the file date when both agree, the metadata when the file date was lost in a copy.
        if let meta = quickTimeCreation(url: url) {
            date = fileDate.map { abs($0.timeIntervalSince(meta)) < 2 ? $0 : meta } ?? meta
        }
    default: break
    }
    // Phones and recorders name files after when they started ("20260801_222840-01.wav"):
    // better than a file date that a copy or an export rewrote.
    let result = date ?? nameTimestamp(url.lastPathComponent) ?? fileDate
    startLock.lock()
    startCache[key] = result
    startLock.unlock()
    return result
}

/// "YYYYMMDD_HHMMSS" (or with "-" / "T" between) at the start of a file name, local time.
public func nameTimestamp(_ name: String) -> Date? {
    guard let m = name.range(of: #"^(VID_|IMG_|REC_|AUD_)?(20\d{2})(\d{2})(\d{2})[_\-T ]?(\d{2})(\d{2})(\d{2})"#,
                             options: .regularExpression) else { return nil }
    let digits = name[m].filter(\.isNumber)
    guard digits.count >= 14 else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyyMMddHHmmss"
    f.timeZone = .current
    return f.date(from: String(digits.prefix(14)))
}

private let startLock = NSLock()
private var startCache = [String: Date?]()

/// The start of a broadcast WAV from its `bext` time reference and `fmt` sample rate.
func broadcastStart(url: URL, near fileDate: Date?) -> Date? {
    guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
    defer { try? handle.close() }
    guard let header = try? handle.read(upToCount: 12), header.count == 12,
          let riff = String(data: header.prefix(4), encoding: .ascii), riff == "RIFF" || riff == "RF64" else { return nil }
    var sampleRate: Double?
    var reference: UInt64?
    var dayString: String?
    var offset: UInt64 = 12
    for _ in 0..<64 {
        try? handle.seek(toOffset: offset)
        guard let chunk = try? handle.read(upToCount: 8), chunk.count == 8 else { break }
        let id = String(data: chunk.prefix(4), encoding: .ascii) ?? ""
        let size = UInt64(chunk.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if id == "fmt ", let body = try? handle.read(upToCount: 8), body.count == 8 {
            sampleRate = Double(body.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        } else if id == "bext", size >= 346, let body = try? handle.read(upToCount: 346), body.count == 346 {
            dayString = String(data: body[320..<330], encoding: .ascii)
            reference = body[338..<346].withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        } else if id == "data" {
            break
        }
        if sampleRate != nil && reference != nil { break }
        offset += 8 + size + (size & 1)
    }
    guard let rate = sampleRate, rate > 0, let reference, reference > 0 else { return nil }
    let seconds = Double(reference) / rate
    // Midnight of which day? The header's date may be the day the file was closed, so
    // take the day (that one or the one before or after) that lands closest to the file date.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .current
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = .current
    let base = dayString.flatMap { formatter.date(from: $0.replacingOccurrences(of: ":", with: "-")) }
        ?? fileDate.map { calendar.startOfDay(for: $0) }
    guard let day = base else { return nil }
    let candidates = [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: day) }
        .map { $0.addingTimeInterval(seconds) }
    guard let anchor = fileDate else { return candidates[1] }
    return candidates.min { abs($0.timeIntervalSince(anchor)) < abs($1.timeIntervalSince(anchor)) }
}

/// The creation date a camera or phone wrote inside a QuickTime / MP4 file.
func quickTimeCreation(url: URL) -> Date? {
#if canImport(AVFoundation) && !SYNCO_PORTABLE
    let asset = AVURLAsset(url: url)
    guard let date = asset.creationDate?.dateValue,
          date.timeIntervalSince1970 > 946_684_800 else { return nil } // ignore unset clocks (before 2000)
    return date
#else
    guard let date = FFmpeg.probe(url).creation, date.timeIntervalSince1970 > 946_684_800 else { return nil }
    return date
#endif
}
