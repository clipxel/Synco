import Accelerate
import AVFoundation
import Foundation

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
        output.withUnsafeMutableBufferPointer { out in
            vDSP_desamp(pending, vDSP_Stride(factor), filter, out.baseAddress! + start, vDSP_Length(count), vDSP_Length(taps))
        }
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
    let fileDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
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
    let result = date ?? fileDate
    startLock.lock()
    startCache[key] = result
    startLock.unlock()
    return result
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
    let asset = AVURLAsset(url: url)
    guard let date = asset.creationDate?.dateValue,
          date.timeIntervalSince1970 > 946_684_800 else { return nil } // ignore unset clocks (before 2000)
    return date
}
