import Foundation

/// The global search's raw results, kept on disk: each clip's best match against one reference,
/// keyed by what the audio is (not the file's name or place), so the same project syncs again
/// in seconds and a search done in the background on opening is there when Sync is pressed.
/// Thresholds are applied after, so changing them in the settings still works on stored results.
public final class MatchStore {
    let dir: URL
    private let lock = NSLock()
    private var loaded = [String: [String: [Double]]]()   // reference key → clip key → match
    private var dirty = Set<String>()

    public init(dir: URL) {
        self.dir = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ reference: String) -> URL { dir.appendingPathComponent("\(reference).matches") }

    private func table(_ reference: String) -> [String: [Double]] {
        if let t = loaded[reference] { return t }
        let t = (try? Data(contentsOf: file(reference)))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [Double]] } ?? [:]
        loaded[reference] = t
        return t
    }

    /// nil: never searched. .some(nil): searched, nothing found.
    func get(_ reference: String, _ clip: String) -> Match?? {
        lock.lock(); defer { lock.unlock() }
        guard let v = table(reference)[clip] else { return nil }
        guard v.count == 5 else { return .some(nil) }
        return .some(Match(lag: v[0], z: Float(v[1]), z2: Float(v[2]), lag2: v[3], inverted: v[4] != 0))
    }

    func put(_ reference: String, _ clip: String, _ m: Match?) {
        lock.lock(); defer { lock.unlock() }
        _ = table(reference)
        loaded[reference]![clip] = m.map { [$0.lag, Double($0.z), Double($0.z2), $0.lag2, $0.inverted ? 1 : 0] } ?? []
        dirty.insert(reference)
    }

    func save() {
        lock.lock(); defer { lock.unlock() }
        for r in dirty {
            if let data = try? JSONSerialization.data(withJSONObject: loaded[r]!) { try? data.write(to: file(r), options: .atomic) }
        }
        dirty.removeAll()
    }
}

/// A fingerprint of a signal's samples (64-bit FNV-style over their bits), with its length.
func contentKey(_ samples: [Float]) -> String {
    var h: UInt64 = 1469598103934665603
    samples.withUnsafeBufferPointer { p in
        for x in p { h = (h ^ UInt64(x.bitPattern)) &* 1099511628211 }
    }
    return String(h, radix: 16) + "-" + String(samples.count)
}
