import Foundation
import SyncCore
#if canImport(AVFoundation) && !SYNCO_PORTABLE
import AVFoundation
#endif

/// The drone step on a made-up shoot whose answer is known: a recorder, a camera whose clock is
/// 37 s off and a phone on the real time, both filming flashes; and a drone with no sound, its
/// clock 0.42 s off the phone's, with an .SRT per flight like DJI's. Two flights saw the
/// flashes with the camera or the phone, one flew when nobody else was filming. A fourth looked elsewhere
/// while a camera filmed: it must not be "found" by light, only by its clock. All must land
/// within a frame of the truth.
enum DroneTest {
    static func run(folder: URL, cache: AudioCache) throws -> Bool {
#if canImport(AVFoundation) && !SYNCO_PORTABLE
        let fm = FileManager.default
        try? fm.removeItem(at: folder)
        let drone = folder.appendingPathComponent("DRON")
        try fm.createDirectory(at: drone, withIntermediateDirectories: true)
        var rng = Selftest.Rng(state: 7)
        let fps = Selftest.fps, rate = Selftest.rate

        // The scene: 5 minutes of speech-like sound, and the light everyone sees: flashes and
        // stage lights now and then over a slow drift.
        let seconds = 300.0
        var sound = [Float](repeating: 0, count: Int(seconds) * rate)
        var t = 0
        while t < sound.count {
            let length = Int((0.08 + 0.35 * rng.next()) * Double(rate)), gap = Int((0.02 + 0.4 * rng.next()) * Double(rate))
            let level = Float(0.2 + 0.6 * rng.next())
            var low: Float = 0
            for i in 0..<length where t + i < sound.count {
                low += 0.25 * (Float(rng.next() * 2 - 1) - low)
                sound[t + i] = level * sinf(Float.pi * Float(i) / Float(length)) * low
            }
            t += length + gap
        }
        var flashes = [(at: Double, length: Double, level: Double)]()
        var f = 1.0
        while f < seconds { flashes.append((f, 0.05 + 0.4 * rng.next(), 0.3 + 0.9 * rng.next())); f += 1.5 + 5 * rng.next() }
        func light(_ s: Double) -> Double {
            var v = 0.25 * sin(s / 37)
            for x in flashes where s >= x.at && s < x.at + x.length { v += x.level }
            return v
        }

        let day = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .current,
                                 year: 2026, month: 3, day: 14, hour: 18, minute: 0, second: 0).date!
        // The recorder runs from 0 on the phone's clock (the real time) + 2 s.
        let recName = "REC_001.wav"
        try Selftest.wav(sound).write(to: folder.appendingPathComponent(recName))
        try fm.setAttributes([.creationDate: day.addingTimeInterval(2), .modificationDate: day.addingTimeInterval(2 + seconds)],
                             ofItemAtPath: folder.appendingPathComponent(recName).path)

        // Picture: each device sees the light its own way (gain, exposure, its own moves).
        func frames(_ from: Double, _ length: Double, _ rate: Double, gain: Double, base: Double, wobble: Double) -> [UInt8] {
            var level = 0.0
            return (0..<Int(length * rate)).map { i in
                let s = from + Double(i) / rate
                level += wobble * (rng.next() * 2 - 1)
                if rng.next() < 0.004 { level += (rng.next() * 2 - 1) * 0.5 }   // a pan to the sky, its own
                level *= 0.995
                return UInt8(max(4, min(250, base * exp(gain * light(s) + level))))
            }
        }
        struct Clip { let name: String; let track: String; let at: Double; let length: Double; let clock: Double }
        // Camera at 25 fps, its clock 37 s fast; the phone at 30 fps on the real time.
        let cameras = [
            Clip(name: "C0001.MOV", track: "V1", at: 30, length: 70, clock: 37), Clip(name: "C0002.MOV", track: "V1", at: 160, length: 50, clock: 37),
            Clip(name: "IMG_0001.MOV", track: "V2", at: 60, length: 40, clock: 0), Clip(name: "IMG_0002.MOV", track: "V2", at: 120, length: 30, clock: 0),
        ]
        for c in cameras {
            let r = c.track == "V1" ? 25.0 : 30.0
            let a = Int(c.at * Double(rate)), b = min(sound.count, a + Int(c.length * Double(rate)))
            let audio = sound[a..<b].map { 0.7 * $0 + Float(0.03 * (rng.next() * 2 - 1)) }
            let url = folder.appendingPathComponent(c.name)
            try writeMovie(url, frames: frames(c.at, c.length, r, gain: 0.8, base: 110, wobble: 0.01), rate: r, audio: audio,
                           audioRate: rate, phone: c.track == "V2", created: day.addingTimeInterval(2 + c.at + c.clock))
        }
        // The drone at 60 fps, its clock 0.42 s behind the phone's.
        // The fourth looks elsewhere while the camera films: none of the flashes, only its own moves.
        let flights = [(at: 45.0, length: 35.0, gain: 0.5), (at: 125.0, length: 20.0, gain: 0.5), (at: 240.0, length: 25.0, gain: 0.5),
                       (at: 170.0, length: 25.0, gain: 0.0)]
        let droneClock = -0.42
        var flightNames = [String]()
        for (i, fl) in flights.enumerated() {
            let shot = day.addingTimeInterval(2 + fl.at + droneClock)
            let f = DateFormatter()
            f.dateFormat = "yyyyMMddHHmmss"
            let name = "DJI_\(f.string(from: shot))_000\(i + 1)_D"
            let url = drone.appendingPathComponent(name + ".MP4")
            flightNames.append(name + ".MP4")
            try writeMovie(url, frames: frames(fl.at, fl.length, 60, gain: fl.gain, base: 70, wobble: 0.015), rate: 60, audio: nil,
                           audioRate: rate, phone: false, created: shot.addingTimeInterval(-0.2))
            f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            let srt = "1\n00:00:00,000 --> 00:00:00,016\n<font size=\"28\">FrameCnt: 1, DiffTime: 16ms\n\(f.string(from: shot))\n[iso: 100] </font>\n\n"
            try srt.write(to: drone.appendingPathComponent(name + ".SRT"), atomically: true, encoding: .utf8)
        }

        // The project and its sync, as the app does it, then the drone.
        var items = [(name: String, track: String, frames: Int)]()
        items.append((recName, "A9", Int(seconds) * fps))
        for c in cameras { items.append((c.name, c.track, Int(c.length * Double(fps)))) }
        let xmlURL = folder.appendingPathComponent("dron.xml")
        try Selftest.xml(items, folder: folder).write(to: xmlURL, atomically: true, encoding: .utf8)
        let project = try FCP7Project(url: xmlURL)
        let session = SyncSession(project: project, cache: cache, rate: 4000)
        try session.readAudio()
        var outcome = try session.sync()
        let audioOK = outcome.synced == outcome.placements.count
        print("\(audioOK ? "PASA " : "FALLA")  dron: el resto sincronizado por audio (\(outcome.synced) de \(outcome.placements.count))")
        outcome = try session.addDrone([drone], to: outcome) { print("       \($0)") }
        let recID = project.clips.first { $0.name == recName }!.fileID
        let zero = Double(outcome.starts[recID]!) / Double(fps)
        var ok = audioOK
        for (i, fl) in flights.enumerated() {
            guard let clip = outcome.drones.first?.clips.first(where: { $0.name == flightNames[i] }), let frame = outcome.starts[clip.fileID],
                  let p = outcome.placements.first(where: { $0.id == clip.fileID }) else { print("FALLA  dron: falta la toma \(i + 1)"); ok = false; continue }
            let error = Double(frame) / Double(fps) - zero - fl.at
            let expected: [SyncMethod] = i < 2 ? [.light] : [.lightClock]
            let good = expected.contains(p.method) && abs(error) * Double(fps) <= 1
            print(String(format: "%@  dron: %@ %@ error %+.3f s", good ? "PASA " : "FALLA", clip.name, p.method.rawValue, error))
            ok = ok && good
        }
        // With no phone to say the real time: the drone's clock searched against the cameras' wider.
        setenv("SYNCO_TEST_NO_PHONES", "1", 1)
        let wide = try session.addDrone([drone], to: session.removeDrone("DRON 1", from: outcome))
        unsetenv("SYNCO_TEST_NO_PHONES")
        let wideOK = flights.indices.allSatisfy { i in
            guard let clip = wide.drones.first?.clips.first(where: { $0.name == flightNames[i] }), let frame = wide.starts[clip.fileID] else { return false }
            return abs(Double(frame) / Double(fps) - zero - flights[i].at) * Double(fps) <= 1
        }
        print("\(wideOK ? "PASA " : "FALLA")  dron sin teléfonos en el proyecto: buscado más amplio, las \(flights.count) tomas a un cuadro o menos")
        ok = ok && wideOK
        // Exported: the drone on a video track of its own, once, even when exported twice.
        let out = folder.appendingPathComponent("dron - sincronizado.xml")
        try session.export(outcome, to: out)
        try session.export(outcome, to: out)
        let text = try String(contentsOf: out, encoding: .utf8)
        let once = text.components(separatedBy: "SyncoDrone=").count - 1 == 1 && text.components(separatedBy: "synco-drone-clip-").count - 1 == flights.count
        print("\(once ? "PASA " : "FALLA")  dron: en el XML, en una pista de video propia, una sola vez")
        return ok && once
#else
        print("OMITIDA  dron: hace falta macOS para fabricar los videos de prueba")
        return true
#endif
    }

#if canImport(AVFoundation) && !SYNCO_PORTABLE
    /// A small movie: gray frames of the given brightness, optional mono sound, its creation date
    /// inside and on the file, and a phone's maker when it is one.
    static func writeMovie(_ url: URL, frames: [UInt8], rate: Double, audio: [Float]?, audioRate: Int, phone: Bool, created: Date) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov)
        let make = AVMutableMetadataItem()
        make.keySpace = .quickTimeMetadata
        make.key = "com.apple.quicktime.make" as NSString
        make.value = (phone ? "Apple" : "Sony") as NSString
        let date = AVMutableMetadataItem()
        date.keySpace = .quickTimeMetadata
        date.key = "com.apple.quicktime.creationdate" as NSString
        date.value = ISO8601DateFormatter().string(from: created) as NSString
        writer.metadata = [make, date]
        let w = 128, h = 72
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(video)
        var sound: AVAssetWriterInput?
        if audio != nil {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: audioRate, AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            a.expectsMediaDataInRealTime = false
            writer.add(a)
            sound = a
        }
        guard writer.startWriting() else { throw writer.error ?? MediaError.readFailed(url, "escribir") }
        writer.startSession(atSourceTime: .zero)
        var format: CMAudioFormatDescription?
        var asbd = AudioStreamBasicDescription(mSampleRate: Double(audioRate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                               mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1,
                                               mBitsPerChannel: 16, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                       extensions: nil, formatDescriptionOut: &format)
        func appendSound(_ at: Int, _ n: Int) {
            guard let audio, let sound else { return }
            var pcm = audio[at..<(at + n)].map { Int16(max(-1, min(1, $0)) * 32000) }
            var blockBuffer: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: n * 2, blockAllocator: nil, customBlockSource: nil,
                                               offsetToData: 0, dataLength: n * 2, flags: 0, blockBufferOut: &blockBuffer)
            pcm.withUnsafeMutableBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer!, offsetIntoDestination: 0, dataLength: n * 2) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blockBuffer!, formatDescription: format!, sampleCount: n,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(at), timescale: CMTimeScale(audioRate)),
                                                                 packetDescriptions: nil, sampleBufferOut: &sample)
            sound.append(sample!)
        }
        // Picture and sound in step: whichever the writer is ready for (it interleaves them, and
        // waits for the one behind; the encoder also holds a few frames back).
        var frame = 0, at = 0
        let total = audio?.count ?? 0
        while frame < frames.count || at < total {
            let videoTime = Double(frame) / rate, soundTime = Double(at) / Double(audioRate)
            let videoWanted = frame < frames.count && video.isReadyForMoreMediaData && (at >= total || videoTime <= soundTime + 0.5)
            let soundWanted = at < total && (sound?.isReadyForMoreMediaData ?? false)
            if videoWanted {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                if let buffer {
                    CVPixelBufferLockBaseAddress(buffer, [])
                    memset(CVPixelBufferGetBaseAddress(buffer), Int32(frames[frame]), CVPixelBufferGetBytesPerRow(buffer) * h)
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame) * 1000, timescale: CMTimeScale(rate * 1000)))
                }
                frame += 1
                if frame == frames.count { video.markAsFinished() }
            } else if soundWanted {
                let n = min(Int(audioRate / 10), total - at)
                appendSound(at, n)
                at += n
                if at >= total { sound?.markAsFinished() }
            } else {
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        if frames.isEmpty { video.markAsFinished() }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? MediaError.readFailed(url, "escribir") }
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: created.addingTimeInterval(Double(frames.count) / rate)],
                                              ofItemAtPath: url.path)
    }
#endif
}
