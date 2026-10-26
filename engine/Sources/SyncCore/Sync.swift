import Foundation

public struct SyncClip {
    public let id: String
    public let name: String
    public let device: String
    public let audio: AudioTrack?
    public let recordedAt: Date?
    /// When the file was last written: for a recorder that splits long takes,
    /// the moment the next file of the take was opened.
    public let modifiedAt: Date?
    public let duration: Double

    public init(id: String, name: String, device: String, audio: AudioTrack?, recordedAt: Date?, modifiedAt: Date? = nil, duration: Double) {
        self.id = id
        self.name = name
        self.device = device
        self.audio = audio
        self.recordedAt = recordedAt
        self.modifiedAt = modifiedAt
        self.duration = duration
    }
}

public enum SyncMethod: String {
    /// Part of the reference recording everything else is aligned to.
    case reference
    /// Found by audio anywhere in the reference.
    case audio
    /// Found by audio near where its device clock puts it.
    case audioNear
    /// Placed by its device clock only (accurate to about a second).
    case clock
    /// No audio match and no usable time.
    case unplaced

    public var synced: Bool { self == .reference || self == .audio || self == .audioNear }
}

public struct Placement {
    public let id: String
    /// Where the clip's media starts, in seconds on the shared timeline.
    public var time: Double
    public var method: SyncMethod
    public var z: Float = 0
    public var ratio: Float = 0
    /// How far the audio position is from what the device clock predicts.
    public var clockError: Double?
    public var note: String = ""
}

extension Placement {
    // In an extension, so the memberwise initializer the engine uses stays.
    public init(id: String, time: Double, method: SyncMethod) {
        self.init(id: id, time: time, method: method, z: 0)
    }
}

public struct SyncOptions {
    /// Anywhere in hours of audio: the peak must stand out a lot.
    public var zGlobal: Float = 9
    public var ratioGlobal: Float = 1.3
    /// Near the clock's prediction there are few candidates, so less is needed.
    public var zNear: Float = 7
    public var ratioNear: Float = 1.2
    /// Seconds searched either side of the clock prediction.
    public var window: Double = 20
    /// A global match further than this from its device's clock is checked again.
    public var clockTolerance: Double = 4
    /// A match this clear is kept even when its clock disagrees.
    public var zStrong: Float = 15
    /// How close to the clock a peak must be for the clock to break a tie.
    public var clockAgree: Double = 1.5
    public var workers: Int = 6
    public var match = MatchSettings()
    /// Checked between clips and stages; when it turns true the run stops early.
    public var isCancelled: () -> Bool = { false }

    public init() {}
}

public final class Syncer {
    let clips: [SyncClip]
    let options: SyncOptions
    let rate: Double
    let log: (String) -> Void

    var placements = [String: Placement]()
    var wallStart = Date()
    public private(set) var referenceDevice = ""
    var deviceOffsets = [String: Double]()
    /// Devices whose file date marks when recording stopped, not when it started.
    public private(set) var clockAtEnd = Set<String>()
    /// Devices whose file dates say nothing about when they recorded.
    public private(set) var unreliableClocks = Set<String>()

    /// Devices with no picture (console, recorders): preferred as the reference.
    public var soundOnly = Set<String>()
    /// Clips a clock check took off: the camera-to-camera search, which can't be checked against
    /// the clock any better, doesn't put them back (it would go round in circles).
    var droppedByClock = Set<String>()
    /// Global search results from before (this project opened earlier, or searched on opening).
    public var store: MatchStore?

    public init(clips: [SyncClip], rate: Double, options: SyncOptions = SyncOptions(), log: @escaping (String) -> Void) {
        self.clips = clips
        self.rate = rate
        self.options = options
        self.log = log
    }

    public func run() -> [Placement] {
        let master = buildReference()
        log(String(format: "referencia: %@, %.1f h de audio", (referenceDevice as NSString).lastPathComponent, Double(master.count) / rate / 3600))
        var t = Date()
        func lap(_ what: String) {
            if ProcessInfo.processInfo.environment["SYNCO_TIMING"] != nil { log(String(format: "tiempo %@: %.1f s", what, Date().timeIntervalSince(t))) }
            t = Date()
        }
        matchGlobally(master)
        lap("global")
        if options.isCancelled() { return [] }
        calibrateClocks()
        // Each pass again while it finds more, a few rounds at most: a clock check can take back
        // what a pass found, and the two must not take turns forever.
        let rounds = 8
        for _ in 0..<rounds where !options.isCancelled() { if matchNear(master) == 0 { break }; calibrateClocks() }
        lap("cerca")
        for _ in 0..<rounds where !options.isCancelled() { if matchBetween(master) == 0 { break }; calibrateClocks() }
        lap("vecinos")
        for _ in 0..<rounds where !options.isCancelled() { if matchAgainstCameras() == 0 { break }; calibrateClocks() }
        lap("cámaras")
        if !options.isCancelled() { matchGroups() }
        lap("grupos")
        if options.isCancelled() { return [] }
        placeByClock()
        return clips.compactMap { placements[$0.id] }
    }

    // MARK: Reference

    /// The device with the most audio (usually the sound recorder), its files
    /// laid end to end, with silence where its clock shows a real gap.
    /// A file that was created when the previous one was closed is the same take
    /// split at the file size limit, so it follows with no gap at all, whatever
    /// the dates say.
    func buildReference() -> [Float] {
        var totals = [String: Double]()
        for c in clips where c.audio != nil { totals[c.device, default: 0] += c.duration }
        // A camera as reference is laid out by its own file dates, so they have to be recording times.
        // Of the devices whose dates make sense, the one with the most audio; only if none do,
        // the one with the most audio anyway.
        let plausible = totals.filter { datesArePlausible($0.key) }
        // The long sound-only recording (the console, a recorder) is always the base when there
        // is one: everything else is placed against it.
        let console = totals.filter { soundOnly.contains($0.key) && $0.value >= 300 }
        referenceDevice = (!console.isEmpty ? console : plausible.isEmpty ? totals : plausible).max { $0.value < $1.value }?.key ?? ""
        if !plausible.isEmpty, let biggest = totals.max(by: { $0.value < $1.value })?.key, biggest != referenceDevice {
            log("\((biggest as NSString).lastPathComponent): sus fechas no son de grabación (los clips se pisan entre sí); no se usa de referencia")
        }
        let refs = clips.filter { $0.device == referenceDevice && $0.audio != nil }
            .sorted { ($0.recordedAt ?? .distantPast, $0.name) < ($1.recordedAt ?? .distantPast, $1.name) }
        wallStart = refs.first?.recordedAt ?? Date()
        var master = [Float]()
        var previousEnd: Date?
        var previousClosed: Date?
        for r in refs {
            if let end = previousEnd, let start = r.recordedAt {
                let continues = previousClosed.map { abs(start.timeIntervalSince($0)) < 2 } ?? false
                let gap = start.timeIntervalSince(end)
                // A real pause, up to a long break between sets. Days of "gap" mean a file date
                // that is wrong (a copy), and filling them with silence would take all the memory.
                if !continues && gap > 2 && gap < 6 * 3600 {
                    master.append(contentsOf: repeatElement(0, count: Int(gap * rate)))
                } else if gap >= 6 * 3600 {
                    log(String(format: "%@: su fecha está %.0f h después del anterior; va pegado", r.name, gap / 3600))
                }
            }
            previousClosed = r.modifiedAt
            placements[r.id] = Placement(id: r.id, time: Double(master.count) / rate, method: .reference)
            master.append(contentsOf: r.audio!.samples)
            previousEnd = r.recordedAt.map { $0.addingTimeInterval(r.duration) }
        }
        return master
    }

    /// Whether a device's file dates can be when it recorded: one camera can't start a clip
    /// before the previous one ended. Exports and copies carry the time they were written, a
    /// few seconds apart, and fail this. Files sharing one time (parts of a split take) are skipped.
    func datesArePlausible(_ device: String) -> Bool {
        let mine = clips.filter { $0.device == device && $0.recordedAt != nil }.sorted { $0.recordedAt! < $1.recordedAt! }
        var fits = 0, total = 0
        for (a, b) in zip(mine, mine.dropFirst()) {
            let gap = b.recordedAt!.timeIntervalSince(a.recordedAt!)
            guard gap > 0.5 else { continue }
            total += 1
            // Dated at the start (the gap holds the earlier clip) or at the end (it holds the later one).
            if gap >= a.duration - 2 || gap >= b.duration - 2 { fits += 1 }
        }
        return total == 0 || Double(fits) >= 0.8 * Double(total)
    }

    // MARK: Global search

    func matchGlobally(_ master: [Float]) {
        let todo = clips.filter { placements[$0.id] == nil && ($0.audio?.samples.count ?? 0) > Int(rate) }
        guard !todo.isEmpty else { return }
        let maxClip = todo.map { $0.audio!.samples.count }.max()!
        let n = fftSize(atLeast: master.count + maxClip + 16)
        // Results depend on the reference, the FFT length (padding) and the band: all in the key.
        let m = options.match
        let referenceKey = "\(contentKey(master))_\(n)_\(Int(rate))_\(m.lowHz)_\(m.highHz)_\(m.phatBeta)"
        let lock = NSLock()
        var found = [String: Match?]()
        var search = [SyncClip]()
        for clip in todo {
            let key = contentKey(clip.audio!.samples)
            if let stored = store?.get(referenceKey, key) { found[clip.id] = .some(stored) } else { search.append(clip) }
        }
        if found.count > 0 { log("búsqueda global: \(found.count) clips ya buscados antes") }
        if !search.isEmpty {
            let correlator = Correlator(reference: master, maxClip: maxClip, rate: rate, settings: options.match)
            var done = 0
            let workers = min(options.workers, search.count, Self.workersThatFit(n))
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in stride(from: w, to: search.count, by: workers) {
                    if options.isCancelled() { return }
                    let clip = search[i]
                    let samples = clip.audio!.samples
                    let overlap = min(samples.count / 2, Int(4 * rate))
                    let m = correlator.match(samples, lags: (-samples.count + overlap)...(master.count - overlap))
                    store?.put(referenceKey, contentKey(samples), m)
                    lock.lock()
                    found[clip.id] = .some(m)
                    done += 1
                    if done % 10 == 0 || done == search.count { log("búsqueda global: \(done)/\(search.count)") }
                    lock.unlock()
                }
            }
            store?.save()
        }
        for clip in todo {
            if let m = found[clip.id] ?? nil, m.z >= options.zGlobal, m.ratio >= options.ratioGlobal {
                placements[clip.id] = Placement(id: clip.id, time: m.lag / rate, method: .audio, z: m.z, ratio: m.ratio)
            }
        }
    }

    /// The slow part alone, to have it stored before Sync is pressed.
    public func searchAhead() {
        let master = buildReference()
        matchGlobally(master)
    }

    /// How many clips can be correlated at once without swapping: each one needs about
    /// ten bytes per FFT point (its spectrum, weights and correlation); a third of the RAM is the budget.
    static func workersThatFit(_ n: Int) -> Int {
        let budget = Double(ProcessInfo.processInfo.physicalMemory) / 3
        return max(1, Int(budget / (Double(n) * bytesPerFFTPoint)))
    }

    // MARK: Clocks

    func clockPosition(_ clip: SyncClip) -> Double? {
        clip.recordedAt.map { $0.timeIntervalSince(wallStart) - (clockAtEnd.contains(clip.device) ? clip.duration : 0) }
    }

    /// Each device's clock offset from the reference, as the median over its
    /// audio-synced clips; matches that disagree with it are dropped for a second look.
    /// A device whose clips disagree among themselves (exports and copies carry the date
    /// they were written, not recorded) has no usable clock: nothing is judged by it.
    func calibrateClocks() {
        // Whether a device's file date is when it started or stopped recording is read from the
        // clips already synced: the guess under which they agree with each other wins.
        func stats(_ v: [Double]) -> (median: Double, spread: Double) {
            let median = v.sorted()[v.count / 2]
            return (median, v.map { abs($0 - median) }.sorted()[v.count / 2])
        }
        var starts = [String: [Double]](), ends = [String: [Double]]()
        for clip in clips where clip.device != referenceDevice {
            guard let p = placements[clip.id], p.method.synced, let date = clip.recordedAt else { continue }
            let clock = date.timeIntervalSince(wallStart)
            starts[clip.device, default: []].append(p.time - clock)
            ends[clip.device, default: []].append(p.time + clip.duration - clock)
        }
        for (device, s) in starts where s.count >= 3 {
            if stats(ends[device]!).spread < stats(s).spread * 0.5 {
                if !clockAtEnd.contains(device) {
                    log("\((device as NSString).lastPathComponent): la fecha de sus archivos es cuando terminan de grabar")
                }
                clockAtEnd.insert(device)
            } else {
                clockAtEnd.remove(device)
            }
        }

        var byDevice = [String: [(clip: SyncClip, offset: Double)]]()
        for clip in clips where clip.device != referenceDevice {
            guard let p = placements[clip.id], p.method.synced, let clock = clockPosition(clip) else { continue }
            byDevice[clip.device, default: []].append((clip, p.time - clock))
        }
        unreliableClocks = []
        for (device, list) in byDevice {
            let (median, spread) = stats(list.map(\.offset))
            if list.count >= 3 && spread > options.clockTolerance {
                deviceOffsets[device] = nil
                unreliableClocks.insert(device)
                for (clip, _) in list { placements[clip.id]?.clockError = nil }
                continue
            }
            deviceOffsets[device] = median
            for (clip, offset) in list {
                let error = offset - median
                placements[clip.id]?.clockError = error
                // A clear, unique peak is trusted over a clock: clocks get reset, audio does not lie.
                guard let p = placements[clip.id], p.method == .audio, abs(error) > options.clockTolerance,
                      !(p.z >= options.zStrong && p.ratio >= 1.5) else { continue }
                placements[clip.id] = nil
                droppedByClock.insert(clip.id)
                log(String(format: "descarto %@: %.1f s lejos de lo que dice su reloj (z %.1f)", clip.name, error, p.z))
            }
        }
    }


    // MARK: Search near the clock

    /// The reference plus every synced clip from other devices, for one stretch of time.
    func composite(from start: Double, length: Int, excluding device: String, master: [Float]) -> [Float] {
        var out = [Float](repeating: 0, count: length)
        var filled = [Bool](repeating: false, count: length)
        let s0 = Int((start * rate).rounded())
        for i in 0..<length {
            let m = s0 + i
            if m >= 0 && m < master.count && master[m] != 0 { out[i] = master[m]; filled[i] = true }
        }
        for clip in clips where clip.device != device && clip.device != referenceDevice {
            guard let p = placements[clip.id], p.method.synced, let audio = clip.audio else { continue }
            let c0 = Int((p.time * rate).rounded()) - s0
            let from = max(0, c0), to = min(length, c0 + audio.samples.count)
            guard from < to else { continue }
            var rms: Float = 0
            for i in from..<to { rms += audio.samples[i - c0] * audio.samples[i - c0] }
            rms = (rms / Float(to - from)).squareRoot()
            guard rms > 0 else { continue }
            for i in from..<to where !filled[i] {
                out[i] = audio.samples[i - c0] / rms * 0.1
                filled[i] = true
            }
        }
        return out
    }

    /// Returns how many clips it synced.
    func matchNear(_ master: [Float]) -> Int {
        let todo = clips.filter {
            placements[$0.id] == nil && ($0.audio?.samples.count ?? 0) > Int(rate)
                && clockPosition($0) != nil && deviceOffsets[$0.device] != nil
        }
        let lock = NSLock()
        var found = 0
        let workers = max(1, min(options.workers, todo.count))
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in stride(from: w, to: todo.count, by: workers) {
                let clip = todo[i]
                let samples = clip.audio!.samples
                lock.lock()
                let predicted = clockPosition(clip)! + deviceOffsets[clip.device]!
                let start = predicted - options.window
                let length = samples.count + Int(2 * options.window * rate)
                let reference = composite(from: start, length: length, excluding: clip.device, master: master)
                lock.unlock()
                guard reference.contains(where: { $0 != 0 }) else { continue }
                let correlator = Correlator(reference: reference, maxClip: samples.count, rate: rate, settings: options.match)
                let m = correlator.match(samples, lags: 0...Int(2 * options.window * rate))
                lock.lock()
                // A rival peak far from the clock can't beat one right where the clock says.
                let clockAgrees = m.map {
                    $0.z >= options.zGlobal
                        && abs(start + $0.lag / rate - predicted) <= options.clockAgree
                        && abs(start + $0.lag2 / rate - predicted) >= 2 * options.clockAgree
                } ?? false
                // Devices keep their clocks to about a second, so a weak peak far from the
                // clock is a false match; only a clear one may say the clock jumped.
                let farFromClock = m.map {
                    abs(start + $0.lag / rate - predicted) > options.clockTolerance
                        && !($0.z >= options.zGlobal && $0.ratio >= 1.5 * options.ratioGlobal)
                } ?? true
                if let m, m.z >= options.zNear, m.ratio >= options.ratioNear || clockAgrees, !farFromClock {
                    let time = start + m.lag / rate
                    placements[clip.id] = Placement(id: clip.id, time: time, method: .audioNear, z: m.z, ratio: m.ratio,
                                                    clockError: time - predicted)
                    found += 1
                } else if let p = matchPairwise(clip, predicted: predicted) {
                    placements[clip.id] = p
                    found += 1
                    log(String(format: "%@: por audio contra %@ (z %.1f)", clip.name, p.note, p.z))
                } else if ProcessInfo.processInfo.environment["SYNC_DEBUG"] != nil, let m {
                    log(String(format: "  sin match cerca: %@ z %.1f relación %.2f en %+.1f s del reloj",
                               clip.name, m.z, m.ratio, start + m.lag / rate - predicted))
                }
                lock.unlock()
            }
        }
        if found > 0 { log("búsqueda cerca del reloj: \(found) clips más") }
        return found
    }

    /// When the reference barely hears a clip (a recorder far from that camera), the
    /// composite search can miss it even though another camera heard the same thing
    /// clearly. Tries each already synced clip from another device that overlaps the
    /// clock's window, one by one, with the same thresholds, and keeps only a match that
    /// lands where the clock says. Called with the lock held.
    func matchPairwise(_ clip: SyncClip, predicted: Double) -> Placement? {
        let samples = clip.audio!.samples
        let lo = predicted - options.window, hi = predicted + options.window
        var best: Placement?
        // The reference was already in the composite; asking it again alone would only
        // turn an ambiguous answer into a weak yes.
        for other in clips where other.device != clip.device && other.device != referenceDevice {
            guard let p = placements[other.id], p.method.synced, let audio = other.audio else { continue }
            // Only clips that can overlap the clip somewhere in the window.
            guard p.time < hi + clip.duration, p.time + other.duration > lo else { continue }
            let from = Int(((lo - p.time) * rate).rounded()), to = Int(((hi - p.time) * rate).rounded())
            let overlapMin = min(samples.count / 2, Int(4 * rate))
            let lags = max(from, -samples.count + overlapMin)...min(to, audio.samples.count - overlapMin)
            guard lags.lowerBound < lags.upperBound else { continue }
            let correlator = Correlator(reference: audio.samples, maxClip: samples.count, rate: rate, settings: options.match)
            guard let m = correlator.match(samples, lags: lags) else { continue }
            let time = p.time + m.lag / rate
            // A second-chance match has to be clear: the global search's peak contrast,
            // and close to where the clock says.
            guard m.z >= options.zNear, m.ratio >= options.ratioGlobal,
                  abs(time - predicted) <= options.clockTolerance else { continue }
            if best == nil || m.z > best!.z {
                var placed = Placement(id: clip.id, time: time, method: .audioNear, z: m.z, ratio: m.ratio,
                                       clockError: time - predicted)
                placed.note = other.name
                best = placed
            }
        }
        return best
    }

    // MARK: Search between neighbours

    /// A device's clips in the order they were recorded: by file date (start or end, whichever
    /// the device writes), then by name. Copies and exports keep this order even when their
    /// dates are not the recording time.
    func recordingOrder(_ device: String) -> [SyncClip] {
        clips.filter { $0.device == device }.sorted {
            let a = $0.recordedAt ?? .distantPast, b = $1.recordedAt ?? .distantPast
            return a != b ? a < b : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Where a missing clip can be: after the synced clip recorded before it and before the one
    /// recorded after it, on its own device. Its audio is searched only there, against the
    /// reference and every other synced device; in a short stretch a peak that was ambiguous
    /// over hours is often the only one. Returns how many it placed.
    func matchBetween(_ master: [Float]) -> Int {
        let slack = 30.0, longest = 90.0 * 60
        var jobs = [(clip: SyncClip, from: Double, to: Double)]()
        // A device whose clock proved reliable was already searched around its clock.
        for device in Set(clips.map(\.device)) where device != referenceDevice && deviceOffsets[device] == nil {
            let order = recordingOrder(device)
            for (i, clip) in order.enumerated() where placements[clip.id] == nil && (clip.audio?.samples.count ?? 0) > Int(rate) {
                let before = order[..<i].last { placements[$0.id]?.method.synced == true }
                let after = order[(i + 1)...].first { placements[$0.id]?.method.synced == true }
                guard before != nil || after != nil else { continue }
                // Only one side known: up to ten minutes beyond it.
                let from = before.map { placements[$0.id]!.time + $0.duration - slack }
                    ?? (placements[after!.id]!.time - clip.duration - 600)
                let to = after.map { placements[$0.id]!.time - clip.duration + slack }
                    ?? (from + slack + 600)
                guard to > from, to - from <= longest else { continue }
                jobs.append((clip, from, to))
            }
        }
        guard !jobs.isEmpty else { return 0 }
        let lock = NSLock()
        var found = 0
        let biggest = jobs.map { Int(($0.to - $0.from) * rate) + $0.clip.audio!.samples.count }.max()!
        let workers = max(1, min(options.workers, jobs.count, Self.workersThatFit(fftSize(atLeast: biggest * 2))))
        DispatchQueue.concurrentPerform(iterations: workers) { w in
            for i in stride(from: w, to: jobs.count, by: workers) {
                if options.isCancelled() { return }
                let (clip, from, to) = jobs[i]
                let samples = clip.audio!.samples
                let span = Int(((to - from) * rate).rounded())
                lock.lock()
                let reference = composite(from: from, length: span + samples.count, excluding: clip.device, master: master)
                lock.unlock()
                guard reference.contains(where: { $0 != 0 }) else { continue }
                let correlator = Correlator(reference: reference, maxClip: samples.count, rate: rate, settings: options.match)
                guard let m = correlator.match(samples, lags: 0...span) else { continue }
                // The stretch is narrow, but the peak still has to stand out clearly.
                guard m.z >= options.zNear, m.ratio >= options.ratioGlobal else { continue }
                // Against near silence any noise looks like a big peak: most of the clip has to
                // land on real reference audio.
                let at = Int(m.lag.rounded())
                let covered = reference[max(0, at)..<min(reference.count, at + samples.count)].reduce(0) { $1 != 0 ? $0 + 1 : $0 }
                guard Double(covered) >= 0.6 * Double(samples.count) else { continue }
                let time = from + m.lag / rate
                lock.lock()
                // Never on top of a clip from the same camera: that can't have happened.
                let clash = clips.contains { o in
                    o.device == clip.device && o.id != clip.id && placements[o.id]?.method.synced == true
                        && min(time + clip.duration, placements[o.id]!.time + o.duration) - max(time, placements[o.id]!.time) > 1
                }
                if clash { lock.unlock(); continue }
                placements[clip.id] = Placement(id: clip.id, time: time, method: .audioNear, z: m.z, ratio: m.ratio,
                                                note: "entre sus vecinos")
                found += 1
                lock.unlock()
            }
        }
        if found > 0 { log("búsqueda entre vecinos: \(found) clips más") }
        return found
    }

    // MARK: Search against the other cameras

    /// A clip the reference doesn't hear can still overlap a camera that is already placed.
    /// Every missing clip is searched against all the synced audio of the other cameras, laid
    /// one after another; a clear match puts it exactly where that camera says. Returns how many.
    func matchAgainstCameras() -> Int {
        var found = 0
        let devices = Set(clips.map(\.device)).subtracting([referenceDevice])
        for device in devices.sorted() where !options.isCancelled() {
            let todo = clips.filter {
                $0.device == device && placements[$0.id] == nil && !droppedByClock.contains($0.id)
                    && ($0.audio?.samples.count ?? 0) > 2 * Int(rate)
            }
            guard !todo.isEmpty else { continue }
            // The other cameras' synced audio, end to end with a second of silence between clips.
            var buffer = [Float]()
            var segments = [(offset: Int, count: Int, time: Double)]()
            for other in clips where other.device != device && other.device != referenceDevice {
                guard let p = placements[other.id], p.method.synced, let audio = other.audio else { continue }
                segments.append((buffer.count, audio.samples.count, p.time))
                buffer.append(contentsOf: audio.samples)
                buffer.append(contentsOf: repeatElement(0, count: Int(rate)))
            }
            guard !segments.isEmpty else { continue }
            let maxClip = todo.map { $0.audio!.samples.count }.max()!
            let correlator = Correlator(reference: buffer, maxClip: maxClip, rate: rate, settings: options.match)
            let lock = NSLock()
            let workers = max(1, min(options.workers, todo.count, Self.workersThatFit(fftSize(atLeast: buffer.count + maxClip + 16))))
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in stride(from: w, to: todo.count, by: workers) {
                    if options.isCancelled() { return }
                    let clip = todo[i]
                    let samples = clip.audio!.samples
                    let overlap = min(samples.count / 2, Int(4 * rate))
                    guard let m = correlator.match(samples, lags: (-samples.count + overlap)...(buffer.count - overlap)),
                          m.z >= options.zGlobal, m.ratio >= options.ratioGlobal else { continue }
                    // Mostly on one placed clip (not on the silence between them): where that clip is.
                    let at = Int(m.lag.rounded())
                    guard let seg = segments.max(by: {
                        max(0, min(at + samples.count, $0.offset + $0.count) - max(at, $0.offset))
                            < max(0, min(at + samples.count, $1.offset + $1.count) - max(at, $1.offset))
                    }) else { continue }
                    let shared = min(at + samples.count, seg.offset + seg.count) - max(at, seg.offset)
                    guard shared >= min(samples.count / 2, Int(4 * rate)) else { continue }
                    let time = seg.time + Double(at - seg.offset) / rate + (m.lag - Double(at)) / rate
                    lock.lock()
                    let clash = clips.contains { o in
                        o.device == clip.device && o.id != clip.id && placements[o.id]?.method.synced == true
                            && min(time + clip.duration, placements[o.id]!.time + o.duration) - max(time, placements[o.id]!.time) > 1
                    }
                    if !clash {
                        var p = Placement(id: clip.id, time: time, method: .audio, z: m.z, ratio: m.ratio)
                        p.note = "contra otra cámara"
                        placements[clip.id] = p
                        found += 1
                    }
                    lock.unlock()
                }
            }
        }
        if found > 0 { log("búsqueda contra las otras cámaras: \(found) clips más") }
        return found
    }

    // MARK: Groups of cameras without the reference

    /// Clips from different cameras that hear each other while nothing placed hears them (the
    /// recorder was off, or there is none): matched among themselves, they form groups that
    /// are exact inside. A group goes where its clips' dates and neighbours put it, so it is
    /// marked approximate. Links that disagree with the rest of their group are dropped.
    func matchGroups() {
        let left = clips.filter { placements[$0.id] == nil && ($0.audio?.samples.count ?? 0) > 3 * Int(rate) }
        let devices = Array(Set(left.map(\.device))).sorted()
        guard devices.count >= 2 else { return }
        struct Link { let a: String; let b: String; let shift: Double; let z: Float }   // b starts `shift` s after a
        var links = [Link]()
        let lock = NSLock()
        for device in devices where !options.isCancelled() {
            // This camera's missing clips end to end; the other cameras' missing clips are searched in it.
            var buffer = [Float]()
            var segments = [(offset: Int, count: Int, id: String)]()
            for c in left where c.device == device {
                segments.append((buffer.count, c.audio!.samples.count, c.id))
                buffer.append(contentsOf: c.audio!.samples)
                buffer.append(contentsOf: repeatElement(0, count: Int(rate)))
            }
            let others = left.filter { $0.device > device }   // each pair of cameras once
            guard !others.isEmpty, !buffer.isEmpty else { continue }
            let maxClip = others.map { $0.audio!.samples.count }.max()!
            let correlator = Correlator(reference: buffer, maxClip: maxClip, rate: rate, settings: options.match)
            let workers = max(1, min(options.workers, others.count, Self.workersThatFit(fftSize(atLeast: buffer.count + maxClip + 16))))
            DispatchQueue.concurrentPerform(iterations: workers) { w in
                for i in stride(from: w, to: others.count, by: workers) {
                    if options.isCancelled() { return }
                    let clip = others[i]
                    let samples = clip.audio!.samples
                    let overlap = min(samples.count / 2, Int(4 * rate))
                    // Nothing anchors these: only a clearly unique peak counts.
                    guard let m = correlator.match(samples, lags: (-samples.count + overlap)...(buffer.count - overlap)),
                          m.z >= options.zGlobal + 1, m.ratio >= 1.5 else { continue }
                    let at = Int(m.lag.rounded())
                    guard let seg = segments.max(by: {
                        max(0, min(at + samples.count, $0.offset + $0.count) - max(at, $0.offset))
                            < max(0, min(at + samples.count, $1.offset + $1.count) - max(at, $1.offset))
                    }) else { continue }
                    let shared = min(at + samples.count, seg.offset + seg.count) - max(at, seg.offset)
                    guard shared >= Int(4 * rate) else { continue }
                    lock.lock()
                    links.append(Link(a: seg.id, b: clip.id, shift: (m.lag - Double(seg.offset)) / rate, z: m.z))
                    lock.unlock()
                }
            }
        }
        guard !links.isEmpty else { return }
        // Groups: strongest links first; a link that contradicts a group already built is dropped.
        var position = [String: Double]()   // relative to the group's first clip
        var group = [String: Int]()
        var members = [Int: [String]]()
        var next = 0
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        // Two clips of one camera in a group must sit as far apart as their dates say, and not on top of each other.
        func holds(_ ids: [String], _ at: [String: Double]) -> Bool {
            for (i, a) in ids.enumerated() {
                guard let ca = byID[a] else { continue }
                for b in ids[(i + 1)...] {
                    guard let cb = byID[b], ca.device == cb.device else { continue }
                    let (pa, pb) = (at[a]!, at[b]!)
                    if pa < pb + cb.duration - 0.5 && pb < pa + ca.duration - 0.5 { return false }
                    if let da = clockPosition(ca), let db = clockPosition(cb),
                       abs((pb - pa) - (db - da)) > options.clockTolerance { return false }
                }
            }
            return true
        }
        for l in links.sorted(by: { $0.z > $1.z }) {
            switch (group[l.a], group[l.b]) {
            case (nil, nil):
                group[l.a] = next; group[l.b] = next; position[l.a] = 0; position[l.b] = l.shift
                members[next] = [l.a, l.b]; next += 1
            case (let g?, nil):
                var at = position; at[l.b] = position[l.a]! + l.shift
                guard holds(members[g]! + [l.b], at) else { continue }
                group[l.b] = g; position = at; members[g]!.append(l.b)
            case (nil, let g?):
                var at = position; at[l.a] = position[l.b]! - l.shift
                guard holds(members[g]! + [l.a], at) else { continue }
                group[l.a] = g; position = at; members[g]!.append(l.a)
            case (let ga?, let gb?) where ga != gb:
                // Merge b's group into a's, moved so the link holds.
                let move = position[l.a]! + l.shift - position[l.b]!
                var at = position
                for id in members[gb]! { at[id]! += move }
                guard holds(members[ga]! + members[gb]!, at) else { continue }
                for id in members[gb]! { group[id] = ga }
                position = at
                members[ga]! += members[gb]!; members[gb] = nil
            default:
                continue   // same group already: kept only if it agrees, nothing to do either way
            }
        }
        var placed = 0
        for (_, ids) in members where ids.count >= 2 {
            // Where the group goes: each clip's own best guess as a median. Between its synced
            // neighbours, or by a calibrated clock, it is approximate; by a clock nothing
            // checked, only the clips' places among themselves are known.
            var trusted = [Double](), loose = [Double]()
            for id in ids {
                guard let c = byID[id] else { continue }
                if let t = placeBetweenNeighbours(c) {
                    trusted.append(t - position[id]!)
                } else if let clock = clockPosition(c) {
                    if let offset = deviceOffsets[c.device], !unreliableClocks.contains(c.device) {
                        trusted.append(clock + offset - position[id]!)
                    } else {
                        loose.append(clock - position[id]!)
                    }
                }
            }
            let guesses = (trusted.isEmpty ? loose : trusted).sorted()
            // Members whose own places disagree about where the group goes: one of its links is doubtful.
            guard let first = guesses.first, let last = guesses.last, last - first <= 120 else { continue }
            let base = guesses[guesses.count / 2]
            let names = ids.compactMap { byID[$0].map { ($0.name as NSString).lastPathComponent } }.sorted()
            log("grupo de \(ids.count) clips (\(trusted.isEmpty ? "por reloj sin verificar" : "por sus vecinos")): \(names.joined(separator: ", "))")
            for id in ids {
                var p = trusted.isEmpty
                    ? Placement(id: id, time: base + position[id]!, method: .clock)
                    : Placement(id: id, time: base + position[id]!, method: .audioNear, z: 0, ratio: 0)
                p.note = "en grupo con otras cámaras"
                placements[id] = p
                if !trusted.isEmpty { placed += 1 }
            }
        }
        if placed > 0 { log("grupos de cámaras sin la referencia: \(placed) clips") }
    }

    // MARK: Check

    public struct Crosscheck {
        public let a: String
        public let b: String
        /// Direct A-to-B audio offset minus the timeline's, in seconds; nil if no clear peak.
        public let error: Double?
        public let z: Float
    }

    /// Independent check: clips from two different non-reference devices that ended up
    /// overlapping are compared with each other directly. Each was placed against the
    /// reference on its own, so agreement here means both placements are right.
    public func crosscheck(_ result: [Placement], minOverlap: Double = 5) -> [Crosscheck] {
        let byID = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        let synced = result.filter { $0.method.synced && byID[$0.id]!.device != referenceDevice }
        var pairs = [(Placement, Placement)]()
        for (i, p) in synced.enumerated() {
            for q in synced[(i + 1)...] where byID[p.id]!.device != byID[q.id]!.device {
                let a = byID[p.id]!, b = byID[q.id]!
                let overlap = min(p.time + a.duration, q.time + b.duration) - max(p.time, q.time)
                if overlap >= minOverlap { pairs.append((p, q)) }
            }
        }
        let lock = NSLock()
        var out = [Crosscheck]()
        let slack = 2.0
        DispatchQueue.concurrentPerform(iterations: max(1, min(options.workers, pairs.count))) { w in
            for i in stride(from: w, to: pairs.count, by: max(1, min(options.workers, pairs.count))) {
                let (p, q) = pairs[i]
                let a = byID[p.id]!.audio!.samples, b = byID[q.id]!.audio!.samples
                let expected = Int(((q.time - p.time) * rate).rounded())
                let s = Int(slack * rate)
                let correlator = Correlator(reference: a, maxClip: b.count, rate: rate, settings: options.match)
                let m = correlator.match(b, lags: (expected - s)...(expected + s))
                let check = Crosscheck(a: p.id, b: q.id,
                                       error: m.flatMap { $0.z >= options.zNear ? ($0.lag - Double(expected)) / rate : nil },
                                       z: m?.z ?? 0)
                lock.lock(); out.append(check); lock.unlock()
            }
        }
        return out
    }

    // MARK: Fallback

    func placeByClock() {
        for clip in clips where placements[clip.id] == nil {
            // Only for clips their audio didn't place: between the synced clip recorded before
            // and the one recorded after, in proportion to its own time between theirs. Whether
            // the camera's clock is right doesn't matter, only the times relative to each other.
            if let t = placeBetweenNeighbours(clip) {
                placements[clip.id] = Placement(id: clip.id, time: t, method: .clock, note: "entre sus vecinos, por su hora")
            } else if unreliableClocks.contains(clip.device), let t = placeByOrder(clip) {
                placements[clip.id] = Placement(id: clip.id, time: t, method: .clock, note: "por orden (reloj no confiable)")
            } else if let clock = clockPosition(clip) {
                let offset = deviceOffsets[clip.device] ?? 0
                placements[clip.id] = Placement(id: clip.id, time: clock + offset, method: .clock,
                                                note: deviceOffsets[clip.device] == nil ? "reloj sin calibrar" : "")
            } else {
                placements[clip.id] = Placement(id: clip.id, time: 0, method: .unplaced)
            }
        }
        placeOverlapsAside()
    }

    func placeBetweenNeighbours(_ clip: SyncClip) -> Double? {
        guard let mine = clip.recordedAt else { return nil }
        let order = recordingOrder(clip.device)
        guard let i = order.firstIndex(where: { $0.id == clip.id }) else { return nil }
        let synced = { (c: SyncClip) in self.placements[c.id]?.method.synced == true && c.recordedAt != nil }
        guard let before = order[..<i].last(where: synced), let after = order[(i + 1)...].first(where: synced),
              let p = placements[before.id], let n = placements[after.id] else { return nil }
        let span = after.recordedAt!.timeIntervalSince(before.recordedAt!)
        guard span > 0 else { return nil }
        let share = min(1, max(0, mine.timeIntervalSince(before.recordedAt!) / span))
        var t = p.time + share * (n.time - p.time)
        // Not on top of its neighbours when there is room between them.
        let lo = p.time + before.duration, hi = n.time - clip.duration
        if hi >= lo { t = min(max(t, lo), hi) }
        return t
    }

    /// For a device with no usable clock: in recording order (file date, then name), one after another from the synced clip before them, or ending at the next one.
    func placeByOrder(_ clip: SyncClip) -> Double? {
        let mine = recordingOrder(clip.device)
        guard let i = mine.firstIndex(where: { $0.id == clip.id }) else { return nil }
        // Walk back to the last clip that already has a place, adding up the ones in between.
        var gap = 0.0
        for j in stride(from: i - 1, through: 0, by: -1) {
            if let p = placements[mine[j].id] { return p.time + mine[j].duration + 1 + gap }
            gap += mine[j].duration + 1
        }
        // Nothing before it: line up backwards from the next placed clip.
        var ahead = clip.duration + 1
        for j in (i + 1)..<mine.count {
            if let p = placements[mine[j].id] { return p.time - ahead }
            ahead += mine[j].duration + 1
        }
        return nil
    }

    func placeOverlapsAside() {
        // A clock guess can't overlap its own device's clips: slide it to the nearer free side.
        for clip in clips where placements[clip.id]?.method == .clock {
            let others = clips.filter { $0.device == clip.device && $0.id != clip.id }
                .compactMap { o in placements[o.id].map { (start: $0.time, end: $0.time + o.duration) } }
                .sorted { $0.start < $1.start }
            var t = placements[clip.id]!.time
            for o in others where t < o.end - 0.05 && t + clip.duration > o.start + 0.05 {
                let after = o.end, before = o.start - clip.duration
                t = abs(after - t) <= abs(before - t) ? after : before
            }
            placements[clip.id]!.time = t
        }
    }
}
