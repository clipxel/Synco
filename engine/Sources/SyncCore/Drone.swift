import Foundation
#if canImport(AVFoundation) && !SYNCO_PORTABLE
import AVFoundation
#endif

/// Drones (and any camera with no sound), added once the rest is synced: an extra step, so
/// syncing by audio never waits for it.
///
/// 1. **Its time.** The drone's own record of when each frame was shot (DJI's .SRT, to the
///    millisecond), or else the file's date. A drone takes its clock from the phone that flies
///    it, so it shows the real time.
/// 2. **Its clock against the timeline.** Phones in the project also show the real time, and
///    the sync already knows where their clips go: they say where the drone's time falls. With
///    no phone, the other devices' clocks give a rougher guess, searched more widely.
/// 3. **The light.** Where the drone and a camera filmed at the same time, a flash, a stage light
///    or a cloud changes the light both see at the same instant. Every flight of one drone shares
///    one clock, so all of them are searched together for that one correction; then each flight
///    on its own, close to it.
public enum Drone {
    /// The videos among what was chosen (folders searched inside), in name order. A drone's light
    /// copies (.LRF) and flight logs (.SRT) are not clips of their own.
    public static func files(in urls: [URL]) -> [URL] {
        var out = [URL]()
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            out += isDir.boolValue ? ProjectBuilder.mediaFiles(in: url) : [url]
        }
        let video: Set<String> = ["mp4", "mov", "m4v", "mxf", "mts", "avi", "mkv"]
        return out.filter { video.contains($0.pathExtension.lowercased()) && !$0.lastPathComponent.hasPrefix("._") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// A file next to `url` with the same name and another extension, in any case.
    static func sibling(_ url: URL, _ ext: String) -> URL? {
        let base = url.deletingPathExtension()
        for e in [ext.uppercased(), ext.lowercased()] {
            let candidate = base.appendingPathExtension(e)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// When the first frame was shot, from the drone's .SRT next to the video: its first cue holds
    /// the date and time to the millisecond ("2026-10-30 16:20:11.784", older ones "…,784,123"),
    /// on the drone's local clock, like the file dates.
    public static func srtStart(for url: URL) -> Date? {
        guard let srt = sibling(url, "srt"), let handle = try? FileHandle(forReadingFrom: srt) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096) else { return nil }
        return parseSRTStart(String(decoding: head, as: UTF8.self))
    }

    /// The first cue's date and time in an .SRT, minus where that cue starts in the video.
    public static func parseSRTStart(_ text: String) -> Date? {
        guard let r = text.range(of: #"(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})([.,:](\d{1,3}))?"#, options: .regularExpression) else { return nil }
        let stamp = String(text[r])
        let digits = stamp.split { !$0.isNumber }.map(String.init)
        guard digits.count >= 6 else { return nil }
        var c = DateComponents()
        c.year = Int(digits[0]); c.month = Int(digits[1]); c.day = Int(digits[2])
        c.hour = Int(digits[3]); c.minute = Int(digits[4]); c.second = Int(digits[5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard var date = calendar.date(from: c) else { return nil }
        if digits.count >= 7 {
            let ms = digits[6]
            date += (Double(ms) ?? 0) / pow(10, Double(ms.count))
        }
        // The cue's own start ("00:00:00,000 --> …"): the frame the time belongs to.
        if let cue = text.range(of: #"(\d{2}):(\d{2}):(\d{2})[,.](\d{3})\s*-->"#, options: .regularExpression) {
            let p = text[cue].split { !$0.isNumber }.compactMap { Double($0) }
            if p.count >= 4 { date -= p[0] * 3600 + p[1] * 60 + p[2] + p[3] / 1000 }
        }
        return date
    }

    /// Whether a file was made by a phone (its clock is set from the network): Apple and Android
    /// both write it inside the file.
    public static func isPhone(_ url: URL) -> Bool {
#if canImport(AVFoundation) && !SYNCO_PORTABLE
        let asset = AVURLAsset(url: url)
        for item in asset.metadata {
            let key = (item.key as? String) ?? item.identifier?.rawValue ?? ""
            if key.contains("com.android.version") { return true }
            if item.commonKey == .commonKeyMake || key.contains("quicktime.make"),
               let make = item.stringValue?.lowercased(), make.contains("apple") || make.contains("samsung")
                || make.contains("google") || make.contains("xiaomi") || make.contains("motorola") { return true }
        }
        return false
#else
        let text = (try? FFmpeg.run(["-hide_banner", "-nostdin", "-i", url.path], stderrOnly: true)) ?? ""
        return text.contains("com.android.version") || text.range(of: #"com\.apple\.quicktime\.make\s*:\s*Apple"#, options: .regularExpression) != nil
#endif
    }
}

/// One drone (or camera with no sound) added to a synced project.
public struct DroneGroup {
    /// "DRON 1", "DRON 2"… as it shows on the timeline and in the editor.
    public let name: String
    public let folder: String
    public let clips: [ProjectClip]
    let media: [String: MediaInfo]
    /// What was done, in a line or two, for the screen and the report.
    public let summary: String
}

extension SyncSession {
    /// Places a drone's videos on the synced timeline by their time and their light, and returns
    /// the outcome with them in it (as a group of their own; the audio sync is left as it was).
    public func addDrone(_ urls: [URL], to outcome: SyncOutcome, log: @escaping (String) -> Void = { _ in },
                         cancelled: @escaping () -> Bool = { false }) throws -> SyncOutcome {
        let files = Drone.files(in: urls).filter { url in !outcome.drones.contains { $0.clips.contains { $0.url == url } } }
            .filter { url in !project.clips.contains { $0.url.standardizedFileURL == url.standardizedFileURL } }
        guard !files.isEmpty else { throw ProjectBuilder.NothingToAdd(description: "No hay videos nuevos en lo que elegiste.") }
        let fps = Double(project.fps)
        let number = outcome.drones.count + 1
        let groupName = "DRON \(number)"
        let folder = files[0].deletingLastPathComponent().lastPathComponent

        // The timeline in seconds (frame 0 at 0) against the sync's own seconds.
        let shifts = outcome.placements.filter { $0.method != .unplaced }.compactMap { p in outcome.starts[p.id].map { Double($0) / fps - p.time } }.sorted()
        let shift = shifts.isEmpty ? 0 : shifts[shifts.count / 2]
        let byID = Dictionary(uniqueKeysWithValues: project.clips.map { ($0.fileID, $0) })
        func length(_ c: ProjectClip) -> Double { audio[c.fileID]?.duration ?? Double(c.frames) / fps }

        // Each synced device's clock: timeline second = clock (seconds since 1970) + offset.
        var offsets = [String: (offset: Double, spread: Double)]()
        var phoneDevices = Set<String>()
        for (device, list) in Dictionary(grouping: project.clips, by: \.device) {
            var starts = [Double](), ends = [Double]()
            for c in list {
                guard let p = outcome.placements.first(where: { $0.id == c.fileID }), p.method.synced, let date = recordingStart(url: c.url),
                      let frame = outcome.starts[c.fileID] else { continue }
                let t = Double(frame) / fps
                starts.append(t - date.timeIntervalSince1970)
                ends.append(t + length(c) - date.timeIntervalSince1970)
            }
            guard !starts.isEmpty else { continue }
            func stats(_ v: [Double]) -> (Double, Double) {
                let s = v.sorted(), m = s[s.count / 2]
                return (m, v.map { abs($0 - m) }.sorted()[v.count / 2])
            }
            let a = stats(starts), b = stats(ends)
            offsets[device] = b.1 < a.1 * 0.5 ? (b.0, b.1) : (a.0, a.1)
            // SYNCO_TEST_NO_PHONES: as if there were none, to test the wider search.
            if ProcessInfo.processInfo.environment["SYNCO_TEST_NO_PHONES"] == nil, list.contains(where: { $0.hasVideo }),
               list.prefix(3).contains(where: { Drone.isPhone($0.url) }) { phoneDevices.insert(device) }
        }
        let trusted = offsets.filter { phoneDevices.contains($0.key) && $0.value.spread < 1 }
        let pool = trusted.isEmpty ? offsets.filter { $0.value.spread < 2 } : trusted
        let base = pool.isEmpty ? nil : pool.values.map(\.offset).sorted()[pool.count / 2]
        let spread = pool.isEmpty ? 0 : (pool.values.map(\.offset).max()! - pool.values.map(\.offset).min()!)
        let window = trusted.isEmpty ? min(900, max(60, spread + 60)) : 10
        if trusted.isEmpty {
            log(String(format: "%@: no hay teléfonos en el proyecto; la hora del dron se busca ±%.0f s alrededor de los relojes de las cámaras", groupName, window))
        } else {
            log("\(groupName): la hora del dron se compara con la \(trusted.count == 1 ? "del teléfono" : "de los \(trusted.count) teléfonos") del proyecto")
        }

        // The drone's videos: time, length, and their light (from the light copy when there is one).
        struct Flight { let url: URL; let info: MediaInfo; let start: Date?; let fromSRT: Bool; var light = LightTrack() }
        var flights = files.compactMap { url -> Flight? in
            guard let info = probeMedia(url), info.hasVideo else { return nil }
            let srt = Drone.srtStart(for: url)
            return Flight(url: url, info: info, start: srt ?? recordingStart(url: url), fromSRT: srt != nil)
        }
        guard !flights.isEmpty else { throw ProjectBuilder.NothingToAdd(description: "No hay videos que se puedan leer en lo que elegiste.") }
        let lock = NSLock()
        var read = 0
        DispatchQueue.concurrentPerform(iterations: min(4, flights.count)) { w in
            for i in stride(from: w, to: flights.count, by: min(4, flights.count)) where !cancelled() {
                let source = Drone.sibling(flights[i].url, "lrf") ?? flights[i].url
                let light = (try? readLight(url: source)).flatMap { $0.luma.count > 1 ? $0 : nil } ?? (try? readLight(url: flights[i].url)) ?? LightTrack()
                lock.lock(); flights[i].light = light; read += 1; let n = read; lock.unlock()
                log("\(groupName): luz leída \(n)/\(flights.count)")
            }
        }
        if cancelled() { throw SyncCancelled() }

        // The cameras the light is compared with: synced, with picture, on the disk.
        let cameras = project.clips.filter { c in
            c.hasVideo && c.exists && outcome.placements.contains { $0.id == c.fileID && outcome.quality($0) != .guessed }
        }.map { c in (clip: c, start: Double(outcome.starts[c.fileID] ?? 0) / fps, length: length(c)) }

        let coarse = 20.0, fine = 100.0
        // Each flight against every camera that may have filmed with it, as one curve over the
        // correction to the drone's clock (-window…+window).
        // What each flight saw of each camera, read once (the close look reads inside the wide one).
        var seen = [String: (from: Double, to: Double, light: LightTrack)]()
        func cameraLight(_ flight: Int, _ cam: (clip: ProjectClip, start: Double, length: Double), _ a: Double, _ b: Double) -> LightTrack? {
            let key = "\(flight)|\(cam.clip.fileID)"
            lock.lock(); let hit = seen[key]; lock.unlock()
            if let hit, hit.from <= a, hit.to >= b { return hit.light }
            guard let light = try? readLight(url: cam.clip.url, from: a - cam.start, length: b - a), light.luma.count > 1 else { return nil }
            lock.lock(); seen[key] = (a, b, light); lock.unlock()
            return light
        }
        func curve(_ i: Int, predicted: Double, from lo: Double, to hi: Double, rate: Double) -> (score: [Float], covered: [Bool])? {
            let f = flights[i]
            let n = Int((f.info.duration * rate).rounded())
            let lags = Int(((hi - lo) * rate).rounded()) + 1
            guard n > Int(3 * rate), f.light.luma.count > 1 else { return nil }
            let clip = lightSignal(f.light, offset: predicted, start: predicted, count: n, rate: rate)
            var total = [Float](repeating: 0, count: lags), covered = [Bool](repeating: false, count: lags)
            var any = false
            for cam in cameras {
                let a = max(cam.start, predicted + lo), b = min(cam.start + cam.length, predicted + hi + f.info.duration)
                guard b - a >= 3 else { continue }
                guard let light = cameraLight(i, cam, a, b) else { continue }
                let ref = lightSignal(light, offset: cam.start, start: predicted + lo, count: n + lags - 1, rate: rate)
                let (score, overlap) = lightCorrelation(clip, ref, lags: lags, minOverlap: Int(3 * rate))
                for k in 0..<lags where overlap[k] > 0 {
                    total[k] += score[k] * (overlap[k] / Float(rate)).squareRoot()
                    covered[k] = true
                }
                any = true
            }
            return any ? (total, covered) : nil
        }
        func strength(_ c: (score: [Float], covered: [Bool]), apart: Int) -> (index: Int, z: Float, ratio: Float)? {
            let inside = c.score.indices.filter { c.covered[$0] }
            guard inside.count > 20 else { return nil }
            guard let p = peakStrength(inside.map { c.score[$0] }, apart: apart) else { return nil }
            return (inside[p.index], p.z, p.ratio)
        }

        var predicted = [Double?](repeating: nil, count: flights.count)
        for (i, f) in flights.enumerated() { if let s = f.start, let base { predicted[i] = s.timeIntervalSince1970 + base } }
        // All flights together: the one correction their shared clock needs.
        var perFlight = [(score: [Float], covered: [Bool])?](repeating: nil, count: flights.count)
        DispatchQueue.concurrentPerform(iterations: min(4, flights.count)) { w in
            for i in stride(from: w, to: flights.count, by: min(4, flights.count)) where !cancelled() {
                guard let p = predicted[i] else { continue }
                let c = curve(i, predicted: p, from: -window, to: window, rate: coarse)
                lock.lock(); perFlight[i] = c; lock.unlock()
            }
        }
        if cancelled() { throw SyncCancelled() }
        let lags = Int((2 * window * coarse).rounded()) + 1
        var sum = [Float](repeating: 0, count: lags), sumCovered = [Bool](repeating: false, count: lags)
        for c in perFlight.compactMap({ $0 }) {
            for k in 0..<lags where c.covered[k] { sum[k] += c.score[k]; sumCovered[k] = true }
        }
        let withCameras = perFlight.compactMap { $0 }.count
        var correction: Double?
        var how = ""
        if let s = strength((sum, sumCovered), apart: Int(coarse)), s.z >= 8, s.ratio >= 1.3 {
            correction = Double(s.index) / coarse - window
            how = String(format: "las luces coinciden con las cámaras (z %.1f, %d de %d tomas con cámaras a la vez)", s.z, withCameras, flights.count)
        } else {
            // Not as a whole: a flight that on its own matches clearly can still set the clock.
            var found = [Double]()
            for c in perFlight.compactMap({ $0 }) {
                if let s = strength(c, apart: Int(coarse)), s.z >= 10, s.ratio >= 1.5 { found.append(Double(s.index) / coarse - window) }
            }
            if !found.isEmpty {
                correction = found.sorted()[found.count / 2]
                how = "las luces de \(found.count) toma(s) coinciden con las cámaras"
            }
        }
        if let c = correction { log(String(format: "%@: %@; su reloj va %+.2f s respecto del teléfono o las cámaras", groupName, how, c)) }
        else if withCameras == 0 { log("\(groupName): ninguna cámara filmaba a la misma hora que el dron; queda por su hora") }
        else { log("\(groupName): las luces no alcanzan para confirmar; queda por su hora") }

        // Each flight close to the shared correction: its own light if it is clear, else the clock.
        let reach = flights.allSatisfy(\.fromSRT) ? 0.3 : 1.5
        var placements = [Placement]()
        var clips = [ProjectClip]()
        var media = [String: MediaInfo]()
        var starts = outcome.starts
        let lastEnd = (outcome.starts.map { $0.value + (byID[$0.key]?.frames ?? 0) }.max() ?? 0)
        let eventStart = Double(outcome.starts.values.min() ?? 0) / fps, eventEnd = Double(lastEnd) / fps
        var farFirst: Double?
        let farStart = eventEnd + 1
        var farEnd = farStart
        var noTime = [(id: String, frames: Int)]()
        for (i, f) in flights.enumerated() {
            let id = "synco-dron\(number)-\(i + 1)"
            let frames = max(1, Int((f.info.duration * fps).rounded()))
            let clip = ProjectClip(fileID: id, name: f.url.lastPathComponent, url: f.url, frames: frames, hasVideo: true,
                                   track: "V+", deviceName: groupName, items: [])
            clips.append(clip)
            media[id] = f.info
            // With no time, or a time far from the event (a clock set to another day): after the
            // rest, one after another, as the sync does with clips it can't place.
            guard let p = predicted[i] else {
                placements.append(Placement(id: id, time: 0, method: .unplaced, note: "sin hora"))
                noTime.append((id, frames))
                continue
            }
            if p + f.info.duration < eventStart - 3600 || p > eventEnd + 3600 {
                // A drone set to another day: after the rest, its flights as far apart as its clock says.
                let first = farFirst ?? p
                farFirst = first
                let at = farStart + (p - first)
                placements.append(Placement(id: id, time: at - shift, method: .clock, note: "su hora cae lejos del evento: después del resto"))
                starts[id] = Int((at * fps).rounded())
                farEnd = max(farEnd, at + f.info.duration)
                continue
            }
            var time = p + (correction ?? 0)
            var method = correction == nil ? SyncMethod.clock : .lightClock
            var z: Float = 0
            var note = correction == nil ? (trusted.isEmpty ? "por su hora (sin teléfonos para calibrar)" : "por su hora, según los teléfonos") : "por su hora, calibrada con las luces de sus otras tomas"
            if let c = correction, let local = curve(i, predicted: p, from: c - reach - 0.2, to: c + reach + 0.2, rate: fine),
               let s = strength(local, apart: Int(0.25 * fine)), s.z >= 7, s.ratio >= 1.3 {
                // The peak to a fraction of a sample, as with the audio.
                var k = Double(s.index)
                if s.index > 0, s.index < local.score.count - 1 {
                    let a = local.score[s.index - 1], b = local.score[s.index], d = local.score[s.index + 1]
                    let den = a - 2 * b + d
                    if den < 0 { k += Double(0.5 * (a - d) / den) }
                }
                time = p + c - reach - 0.2 + k / fine
                method = .light
                z = s.z
                note = "por las luces, contra las cámaras"
            }
            let clockError = correction.map { time - p - $0 }
            placements.append(Placement(id: id, time: time - shift, method: method, z: z, ratio: 0, clockError: clockError, note: note))
            starts[id] = Int((time * fps).rounded())
        }
        // With no time at all: after everything, one after another.
        var end = max(lastEnd, Int((farEnd * fps).rounded()))
        for c in noTime { starts[c.id] = end; end += c.frames }
        // Nothing before the start of the sequence: then everything moves later together.
        if let lowest = starts.values.min(), lowest < 0 { for k in starts.keys { starts[k]! -= lowest } }

        let byLight = placements.filter { $0.method == .light }.count
        let summary = "\(groupName) (\(folder)): \(flights.count) tomas; \(byLight) por las luces, "
            + "\(placements.filter { $0.method == .lightClock }.count) por su hora calibrada con las luces, "
            + "\(placements.filter { $0.method == .clock }.count) solo por su hora."
            + (placements.contains { $0.note.contains("lejos") } ? " Su hora cae lejos del resto: quedaron al final." : "")
            + (placements.contains { $0.method == .unplaced } ? " Sin hora: al final." : "")
        log(summary)
        var next = outcome
        next.placements += placements
        next.starts = starts
        next.drones.append(DroneGroup(name: groupName, folder: folder, clips: clips, media: media, summary: summary))
        return next
    }

    /// The outcome without a drone it had, to add it again or leave it out.
    public func removeDrone(_ name: String, from outcome: SyncOutcome) -> SyncOutcome {
        guard let group = outcome.drones.first(where: { $0.name == name }) else { return outcome }
        let ids = Set(group.clips.map(\.fileID))
        var next = outcome
        next.placements.removeAll { ids.contains($0.id) }
        for id in ids { next.starts[id] = nil }
        next.drones.removeAll { $0.name == name }
        return next
    }
}

extension FCP7Project {
    /// The drones as video tracks of their own above the cameras (written again on each export,
    /// so an export after another doesn't add them twice).
    func setDroneTracks(_ groups: [DroneGroup], starts: [String: Int], labels: [String: String], disabled: Set<String>) {
        guard let video = sequence.elements(forName: "media").first?.elements(forName: "video").first else { return }
        for t in video.elements(forName: "track") where t.attribute(forName: "SyncoDrone") != nil { t.detach() }
        let rate = ProjectBuilder.Rate(fps)
        var fileNumber = 0
        for group in groups {
            let track = XMLElement(name: "track")
            track.addAttribute(XMLNode.attribute(withName: "SyncoDrone", stringValue: group.name) as! XMLNode)
            track.addAttribute(XMLNode.attribute(withName: "SyncoDevice", stringValue: group.name) as! XMLNode)
            for clip in group.clips {
                guard let start = starts[clip.fileID], let info = group.media[clip.fileID] else { continue }
                fileNumber += 1
                let fileRate = info.fps > 0 ? ProjectBuilder.Rate(info.fps) : rate
                let file = XMLElement(name: "file")
                file.addAttribute(XMLNode.attribute(withName: "id", stringValue: "synco-drone-file-\(fileNumber)") as! XMLNode)
                file.addChild(XMLElement(name: "name", stringValue: clip.name))
                file.addChild(XMLElement(name: "pathurl", stringValue: clip.url.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")))
                file.addChild(fileRate.element())
                file.addChild(XMLElement(name: "duration", stringValue: String(max(1, Int((info.duration * fileRate.actual).rounded())))))
                let media = XMLElement(name: "media")
                let v = XMLElement(name: "video")
                let sc = XMLElement(name: "samplecharacteristics")
                sc.addChild(fileRate.element())
                for (k, value) in [("width", String(info.width)), ("height", String(info.height)), ("anamorphic", "FALSE"),
                                   ("pixelaspectratio", "square"), ("fielddominance", "none")] {
                    sc.addChild(XMLElement(name: k, stringValue: value))
                }
                v.addChild(sc)
                media.addChild(v)
                file.addChild(media)

                let item = XMLElement(name: "clipitem")
                item.addAttribute(XMLNode.attribute(withName: "id", stringValue: "synco-drone-clip-\(fileNumber)") as! XMLNode)
                for (k, value) in [("masterclipid", "synco-drone-master-\(fileNumber)"), ("name", clip.name),
                                   ("enabled", disabled.contains(clip.fileID) ? "FALSE" : "TRUE"), ("duration", String(clip.frames))] {
                    item.addChild(XMLElement(name: k, stringValue: value))
                }
                item.addChild(rate.element())
                for (k, value) in [("start", start), ("end", start + clip.frames), ("in", 0), ("out", clip.frames)] {
                    item.addChild(XMLElement(name: k, stringValue: String(value)))
                }
                item.addChild(file)
                if let label = labels[clip.fileID] {
                    let l = XMLElement(name: "labels")
                    l.addChild(XMLElement(name: "label2", stringValue: label))
                    item.addChild(l)
                }
                track.addChild(item)
            }
            video.addChild(track)
        }
    }
}
