import Foundation

/// A Synco project saved to a file (.synco): the tracks as they are (clips moved or taken out),
/// the sync with its hand corrections and drones, and how it was being looked at. Opened again,
/// it is as it was left, without syncing again; the audio comes back from the cache.
/// JSON, so it can be read and kept with the shoot.
public struct SavedProject: Codable {
    public static let fileExtension = "synco"
    public var format = "synco-proyecto"
    public var version = 1
    public var app: String?
    public var saved = Date()
    /// The project's XML as it is now.
    public var xml: String
    /// Where its XML came from: the file Synco built from folders, or the editor's XML.
    public var source: String
    public var outcome: Outcome?
    /// Clips marked as wrongly synced (placed by their time on the next sync).
    public var ignored: [String] = []
    /// The files of each drone added, to add them again after another sync.
    public var droneFiles: [[String]] = []
    public var mutedTracks: [String] = []
    public var soloTrack: String?
    public var playhead: Double?
    public var selected: String?

    public init(xml: String, source: String) {
        self.xml = xml
        self.source = source
    }

    public struct Outcome: Codable {
        public struct Place: Codable {
            var id: String, time: Double, method: String, z: Float, ratio: Float, clockError: Double?, note: String
        }
        public struct Check: Codable { var a: String, b: String, error: Double?, z: Float }
        public struct Clip: Codable { var id: String, name: String, path: String, frames: Int, track: String, device: String? }
        public struct Media: Codable {
            var duration: Double, hasVideo: Bool, width: Int, height: Int, fps: Double, channels: Int, sampleRate: Double
        }
        public struct Drone: Codable { var name: String, folder: String, summary: String, clips: [Clip], media: [String: Media] }

        var placements: [Place]
        var starts: [String: Int]
        var checks: [Check]
        var overlaps: [String]
        var seconds: Double
        var confirmed: [String]
        var referenceIsRecorder: Bool
        var warnings: [String]
        var strongNear: [Float]?
        var drones: [Drone]
        var manual: [String: Int]
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    public static func read(_ url: URL) throws -> SavedProject {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try Data(contentsOf: url)
        guard let saved = try? decoder.decode(SavedProject.self, from: data), saved.format == "synco-proyecto" else {
            throw ProjectError.notFCP7("no es un proyecto de Synco")
        }
        guard saved.version <= 1 else {
            throw ProjectError.notFCP7("lo guardó una versión más nueva de Synco: actualizá la app para abrirlo")
        }
        return saved
    }

    /// The project it holds.
    public func project() throws -> FCP7Project { try FCP7Project(xml: xml) }

    /// The sync it holds, for this project (what no longer matches a clip in it is left out).
    public func outcome(for project: FCP7Project) -> SyncOutcome? {
        guard let o = outcome else { return nil }
        let drones = o.drones.map { d in
            DroneGroup(name: d.name, folder: d.folder,
                       clips: d.clips.map { c in
                           ProjectClip(fileID: c.id, name: c.name, url: URL(fileURLWithPath: c.path), frames: c.frames,
                                       hasVideo: true, track: c.track, deviceName: c.device, items: [])
                       },
                       media: d.media.mapValues { m in
                           var info = MediaInfo()
                           info.duration = m.duration; info.hasVideo = m.hasVideo; info.width = m.width; info.height = m.height
                           info.fps = m.fps; info.channels = m.channels; info.sampleRate = m.sampleRate
                           return info
                       },
                       summary: d.summary)
        }
        let known = Set(project.clips.map(\.fileID) + drones.flatMap { $0.clips.map(\.fileID) })
        let placements = o.placements.filter { known.contains($0.id) }.map { p in
            Placement(id: p.id, time: p.time, method: SyncMethod(rawValue: p.method) ?? .clock, z: p.z, ratio: p.ratio,
                      clockError: p.clockError, note: p.note)
        }
        var outcome = SyncOutcome(placements: placements, starts: o.starts.filter { known.contains($0.key) },
                                  checks: o.checks.filter { known.contains($0.a) && known.contains($0.b) }
                                      .map { Syncer.Crosscheck(a: $0.a, b: $0.b, error: $0.error, z: $0.z) },
                                  overlaps: o.overlaps, seconds: o.seconds, confirmed: Set(o.confirmed).intersection(known),
                                  referenceIsRecorder: o.referenceIsRecorder, warnings: o.warnings)
        if let s = o.strongNear, s.count == 2 { outcome.strongNear = (s[0], s[1]) }
        outcome.drones = drones
        outcome.manual = o.manual.filter { known.contains($0.key) }
        return outcome
    }
}

extension SyncOutcome {
    /// What a saved project keeps of it.
    public var saved: SavedProject.Outcome {
        typealias O = SavedProject.Outcome
        return O(placements: placements.map { O.Place(id: $0.id, time: $0.time, method: $0.method.rawValue, z: $0.z, ratio: $0.ratio,
                                                      clockError: $0.clockError, note: $0.note) },
                 starts: starts,
                 checks: checks.map { O.Check(a: $0.a, b: $0.b, error: $0.error, z: $0.z) },
                 overlaps: overlaps, seconds: seconds, confirmed: confirmed.sorted(),
                 referenceIsRecorder: referenceIsRecorder, warnings: warnings,
                 strongNear: strongNear.map { [$0.z, $0.ratio] },
                 drones: drones.map { d in
                     O.Drone(name: d.name, folder: d.folder, summary: d.summary,
                             clips: d.clips.map { O.Clip(id: $0.fileID, name: $0.name, path: $0.url.path, frames: $0.frames,
                                                         track: $0.track, device: $0.deviceName) },
                             media: d.media.mapValues { O.Media(duration: $0.duration, hasVideo: $0.hasVideo, width: $0.width,
                                                                height: $0.height, fps: $0.fps, channels: $0.channels,
                                                                sampleRate: $0.sampleRate) })
                 },
                 manual: manual)
    }
}
