import Foundation
#if canImport(AVFoundation) && !SYNCO_PORTABLE
import AVFoundation
#endif
#if canImport(Accelerate) && !SYNCO_PORTABLE
import Accelerate
#endif

/// How bright a video is, frame by frame: what is left to sync by when a clip has no sound.
/// A flash, a stage light or a cloud changes the light every camera sees at the same instant,
/// whatever angle it films from.
public struct LightTrack {
    /// Each frame's time in the file, in seconds.
    public var times: [Double] = []
    /// Each frame's mean brightness (0–255).
    public var luma: [Float] = []
}

/// Reads a stretch of a video's brightness (all of it with no `length`), from a tiny copy of
/// each frame the decoder scales down itself, so even 4K is quick.
public func readLight(url: URL, from: Double = 0, length: Double? = nil) throws -> LightTrack {
    guard FileManager.default.fileExists(atPath: url.path) else { throw MediaError.missing(url) }
    var out = LightTrack()
#if canImport(AVFoundation) && !SYNCO_PORTABLE
    // A drone's light copy (.LRF) is an MP4 under another name: opened as one.
    var source = url
    if url.pathExtension.lowercased() == "lrf" {
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("synco-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        source = link
    }
    defer { if source != url { try? FileManager.default.removeItem(at: source) } }
    let asset = AVURLAsset(url: source)
    guard let track = asset.tracks(withMediaType: .video).first else { return out }
    let reader = try AVAssetReader(asset: asset)
    let start = CMTime(seconds: max(0, from), preferredTimescale: 600)
    reader.timeRange = CMTimeRange(start: start, duration: length.map { CMTime(seconds: $0, preferredTimescale: 600) } ?? .positiveInfinity)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelBufferWidthKey as String: 64,
        kCVPixelBufferHeightKey as String: 36,
    ])
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { throw MediaError.readFailed(url, reader.error?.localizedDescription ?? "video") }
    while let sample = output.copyNextSampleBuffer() {
        guard let image = CMSampleBufferGetImageBuffer(sample) else { continue }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        CVPixelBufferLockBaseAddress(image, .readOnly)
        let w = CVPixelBufferGetWidthOfPlane(image, 0), h = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        var sum = 0
        if let base = CVPixelBufferGetBaseAddressOfPlane(image, 0)?.assumingMemoryBound(to: UInt8.self) {
            for y in 0..<h { let row = base + y * stride; for x in 0..<w { sum += Int(row[x]) } }
        }
        CVPixelBufferUnlockBaseAddress(image, .readOnly)
        out.times.append(time)
        out.luma.append(Float(sum) / Float(max(1, w * h)))
    }
    if reader.status == .failed { throw MediaError.readFailed(url, reader.error?.localizedDescription ?? "video") }
#else
    let fps = probeMedia(url)?.fps ?? 0
    guard fps > 0 else { return out }
    var args = ["-hide_banner", "-nostdin", "-v", "error"]
    if from > 0 { args += ["-ss", String(from)] }
    args += ["-i", url.path]
    if let length { args += ["-t", String(length)] }
    args += ["-an", "-vf", "scale=32:18,format=gray", "-f", "rawvideo", "-"]
    let size = 32 * 18
    try FFmpeg.streamBytes(args, frameSize: size) { frame in
        var sum = 0
        for b in frame { sum += Int(b) }
        out.times.append(max(0, from) + Double(out.luma.count) / fps)
        out.luma.append(Float(sum) / Float(size))
    }
#endif
    return out
}

/// What is compared: how fast the light changes (in log brightness, so a darker exposure
/// or a log profile changes the same), on an even grid of `rate` samples a second.
public struct LightSignal {
    public var values: [Float]
    /// 1 where the clip has picture, 0 where it doesn't.
    public var mask: [Float]
}

/// The light of `track`, whose file time 0 sits at `offset` on the timeline, sampled from
/// timeline second `start` for `count` samples.
public func lightSignal(_ track: LightTrack, offset: Double, start: Double, count: Int, rate: Double) -> LightSignal {
    var level = [Float](repeating: 0, count: count)
    var mask = [Float](repeating: 0, count: count)
    guard track.times.count >= 2 else { return LightSignal(values: level, mask: mask) }
    let frame = (track.times.last! - track.times.first!) / Double(track.times.count - 1)
    var j = 0
    for i in 0..<count {
        let t = start + Double(i) / rate - offset
        guard t >= track.times[0], t < track.times.last! + frame else { continue }
        while j + 1 < track.times.count && track.times[j + 1] <= t { j += 1 }
        level[i] = log(max(1, track.luma[j]))
        mask[i] = 1
    }
    // The change from one sample to the next: zero within a frame, a step at each new frame.
    var change = [Float](repeating: 0, count: count)
    for i in 1..<count where mask[i] > 0 && mask[i - 1] > 0 { change[i] = level[i] - level[i - 1] }
    // On a common scale (a camera that moves a lot is not louder than a still one), with the
    // rare big changes, the ones worth syncing by, kept but not left to swamp everything.
    let present = (0..<count).filter { mask[$0] > 0 && change[$0] != 0 }.map { abs(change[$0]) }.sorted()
    let typical = present.isEmpty ? 1 : max(1e-4, present[present.count / 2] * 1.4826)
    for i in 0..<count { change[i] = max(-12, min(12, change[i] / typical)) }
    // Spread over a few samples: two cameras at different frame rates see a change up to a frame apart.
    let width = max(1, Int((rate * 0.02).rounded()))
    var smooth = [Float](repeating: 0, count: count)
    var acc: Float = 0
    for i in 0..<count {
        acc += change[i]
        if i >= 2 * width + 1 { acc -= change[i - 2 * width - 1] }
        if i >= width { smooth[i - width] = acc }
    }
    return LightSignal(values: smooth, mask: mask)
}

/// Normalised cross-correlation of `clip` against `reference` for every lag 0..<lags, where
/// lag k lines clip sample n up with reference sample n + k. `reference` holds
/// clip.count + lags - 1 samples. Only samples where both have picture count; lags with less
/// than `minOverlap` samples in common score 0. Returns the scores and the overlap per lag.
public func lightCorrelation(_ clip: LightSignal, _ reference: LightSignal, lags: Int, minOverlap: Int) -> (score: [Float], overlap: [Float]) {
    let n = clip.values.count
    precondition(reference.values.count >= n + lags - 1)
    func correlate(_ ref: [Float], _ x: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: lags)
#if canImport(Accelerate) && !SYNCO_PORTABLE
        vDSP_conv(ref, 1, x, 1, &out, 1, vDSP_Length(lags), vDSP_Length(n))
#else
        ref.withUnsafeBufferPointer { r in
            x.withUnsafeBufferPointer { c in
                for k in 0..<lags {
                    var s: Float = 0
                    for i in 0..<n { s += r[k + i] * c[i] }
                    out[k] = s
                }
            }
        }
#endif
        return out
    }
    let c = clip.values.enumerated().map { clip.mask[$0.offset] > 0 ? $0.element : 0 }
    let c2 = c.map { $0 * $0 }
    let r = reference.values.enumerated().map { reference.mask[$0.offset] > 0 ? $0.element : 0 }
    let r2 = r.map { $0 * $0 }
    let top = correlate(r, c)
    let clipEnergy = correlate(reference.mask, c2)       // the clip where the reference has picture
    let refEnergy = correlate(r2, clip.mask)             // the reference where the clip has picture
    let overlap = correlate(reference.mask, clip.mask)
    var score = [Float](repeating: 0, count: lags)
    for k in 0..<lags where overlap[k] >= Float(minOverlap) {
        let d = (clipEnergy[k] * refEnergy[k]).squareRoot()
        if d > 0 { score[k] = top[k] / d }
    }
    return (score, overlap)
}

/// How much a peak stands out of a curve: (peak - median) over the spread of the rest
/// (robust, from the median absolute deviation), the peak's index, and how much it beats
/// the best peak more than `apart` samples away.
public func peakStrength(_ curve: [Float], apart: Int) -> (index: Int, z: Float, ratio: Float)? {
    guard curve.count > 8, let best = curve.indices.max(by: { curve[$0] < curve[$1] }) else { return nil }
    let sorted = curve.sorted()
    let median = sorted[sorted.count / 2]
    let deviations = curve.map { abs($0 - median) }.sorted()
    let sigma = max(1e-6, deviations[deviations.count / 2] * 1.4826)
    var second: Float = median
    for (i, v) in curve.enumerated() where abs(i - best) > apart { second = max(second, v) }
    let z = (curve[best] - median) / sigma
    let ratio = (curve[best] - median) / max(1e-6, second - median)
    return (best, z, ratio)
}
