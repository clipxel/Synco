import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// What the user changes by hand once synced: a clip taken out, a clip moved to another track,
/// a clip nudged a few frames. None of it syncs again: the rest stays where it was.

public struct EditError: Error, CustomStringConvertible {
    public let description: String
}

extension FCP7Project {
    /// Takes a clip out of the sequence (all its items). Returns it, or nil if it is not there.
    @discardableResult
    public func remove(_ fileID: String) -> ProjectClip? {
        guard let i = clips.firstIndex(where: { $0.fileID == fileID }) else { return nil }
        let clip = clips.remove(at: i)
        for item in clip.items { item.detach() }
        return clip
    }

    /// Moves a clip onto the tracks of `targetID`'s device: its picture onto that device's video
    /// track, its sound channels onto its audio tracks, in order (with another track of the
    /// device's when it has fewer). From then on it counts as that device.
    public func move(_ fileID: String, like targetID: String) throws {
        guard let clip = clips.first(where: { $0.fileID == fileID }),
              let target = clips.first(where: { $0.fileID == targetID }) else { throw EditError(description: "Ese clip ya no está.") }
        guard clip.device != target.device else { return }
        func kind(_ track: XMLElement) -> String { (track.parent as? XMLElement)?.name ?? "" }
        func tracksOf(_ c: ProjectClip, _ k: String) -> [XMLElement] {
            var seen = Set<ObjectIdentifier>(), out = [XMLElement]()
            for item in c.items {
                guard let t = item.parent as? XMLElement, kind(t) == k, seen.insert(ObjectIdentifier(t)).inserted else { continue }
                out.append(t)
            }
            return out
        }
        // Checked before anything moves: a camera's picture needs a track with picture.
        let mine = ["video", "audio"].map { k in clip.items.filter { ($0.parent as? XMLElement).map(kind) == k } }
        if !mine[0].isEmpty && tracksOf(target, "video").isEmpty {
            throw EditError(description: "Un clip con imagen va en una pista de cámara, no en la de un grabador.")
        }
        if !mine[1].isEmpty && tracksOf(target, "audio").isEmpty {
            throw EditError(description: "Esa pista no tiene sonido: el clip perdería su audio.")
        }
        for (k, items) in zip(["video", "audio"], mine) where !items.isEmpty {
            var dest = tracksOf(target, k)
            while dest.count < items.count {
                // One more track for this device: like the item's own (its channel settings), without clips.
                let own = items[dest.count].parent as! XMLElement
                let t = own.copy() as! XMLElement
                for child in t.elements(forName: "clipitem") + t.elements(forName: "transitionitem") { child.detach() }
                t.removeAttribute(forName: "SyncoDevice")
                if let device = target.deviceName {
                    t.addAttribute(XMLNode.attribute(withName: "SyncoDevice", stringValue: device) as! XMLNode)
                }
                (dest.last!.parent as? XMLElement)?.addChild(t)
                dest.append(t)
            }
            for (item, track) in zip(items, dest) {
                item.detach()
                track.addChild(item)
            }
        }
        clip.track = target.track
        clip.deviceName = target.deviceName
        clip.device = target.device
    }
}

extension SyncOutcome {
    /// Moves a clip `frames` later (earlier when negative) on the synced timeline, by hand.
    public mutating func nudge(_ id: String, by frames: Int) {
        guard let start = starts[id], frames != 0 else { return }
        let moved = max(0, start + frames)
        starts[id] = moved
        manual[id, default: 0] += moved - start
        if manual[id] == 0 { manual[id] = nil }
    }

    /// The hand corrections of a previous sync, put back on this one.
    public mutating func applyManual(_ corrections: [String: Int]) {
        for (id, frames) in corrections.sorted(by: { $0.key < $1.key }) { nudge(id, by: frames) }
    }
}

extension SyncSession {
    /// Takes a clip out of the project and of the synced result (a drone's take too).
    public func removeClip(_ id: String, from outcome: inout SyncOutcome?) {
        if project.remove(id) != nil { forget(id) }
        guard var o = outcome else { return }
        o.placements.removeAll { $0.id == id }
        o.starts[id] = nil
        o.manual[id] = nil
        o.checks.removeAll { $0.a == id || $0.b == id }
        for i in o.drones.indices.reversed() {
            o.drones[i].clips.removeAll { $0.fileID == id }
            if o.drones[i].clips.isEmpty { o.drones.remove(at: i) }
        }
        outcome = o
    }

    /// The synced audio of every clip that sounds between timeline seconds `from` and
    /// `from + length`, each where the sync put it, mixed to mono at `rate`: what the sync sounds
    /// like. Two clips a little off sound doubled, like an echo; well synced, as one.
    /// Each clip is brought to the same loudness, so a far camera mic is heard as well as the
    /// recorder. `muted` clips are left out.
    public func preview(_ outcome: SyncOutcome, from: Double, length: Double, muted: Set<String> = [],
                        rate: Double = 24000) -> [Float] {
        let fps = project.fps
        let count = max(0, Int(length * rate))
        struct Part { let clip: ProjectClip; let at: Double; let fileFrom: Double; let length: Double }
        let parts = project.clips.compactMap { clip -> Part? in
            guard !muted.contains(clip.fileID), problems[clip.fileID] == nil, clip.exists,
                  let frame = outcome.starts[clip.fileID] else { return nil }
            let start = Double(frame) / fps
            let duration = audio[clip.fileID]?.duration ?? Double(clip.frames) / fps
            let a = max(from, start), b = min(from + length, start + duration)
            guard b - a > 0.02 else { return nil }
            return Part(clip: clip, at: a - from, fileFrom: a - start, length: b - a)
        }
        var decoded = [[Float]?](repeating: nil, count: parts.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: parts.count) { i in
            let p = parts[i]
            let samples = (try? decodeAudio(url: p.clip.url, rate: rate, from: p.fileFrom, length: p.length))?.samples
            lock.lock(); decoded[i] = samples; lock.unlock()
        }
        var mix = [Float](repeating: 0, count: count)
        for (p, samples) in zip(parts, decoded) {
            guard let samples, !samples.isEmpty else { continue }
            var energy: Float = 0
            for s in samples { energy += s * s }
            let rms = (energy / Float(samples.count)).squareRoot()
            let gain = rms > 1e-5 ? min(40, 0.1 / rms) : 0
            let offset = Int((p.at * rate).rounded())
            for (i, s) in samples.enumerated() where offset + i < count && offset + i >= 0 { mix[offset + i] += s * gain }
        }
        // Several at once add up: kept below full scale without hard clipping.
        for i in mix.indices { mix[i] = mix[i] / (1 + abs(mix[i])) }
        return mix
    }
}

/// A mono 16-bit WAV file of `samples` (-1…1) at `rate`.
public func wavData(_ samples: [Float], rate: Double) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    let bytes = UInt32(samples.count * 2)
    d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
    d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
    u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
    d.append(contentsOf: Array("data".utf8)); u32(bytes)
    for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
    return d
}
