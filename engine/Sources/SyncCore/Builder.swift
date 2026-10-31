import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
#if canImport(AVFoundation) && !SYNCO_PORTABLE
import AVFoundation
#endif

/// What a media file holds: enough to describe it to an editor.
public struct MediaInfo {
    public var duration = 0.0
    public var hasVideo = false
    public var width = 0
    public var height = 0
    public var fps = 0.0
    public var channels = 0
    public var sampleRate = 0.0
    public var hasAudio: Bool { channels > 0 }
}

/// Reads a file's length, picture size (as it is shown: a phone's portrait clip is taller than wide),
/// frame rate and audio channels. nil when it has neither picture nor sound.
public func probeMedia(_ url: URL) -> MediaInfo? {
    var info = MediaInfo()
#if canImport(AVFoundation) && !SYNCO_PORTABLE
    let asset = AVURLAsset(url: url)
    info.duration = asset.duration.seconds.isFinite ? asset.duration.seconds : 0
    if let v = asset.tracks(withMediaType: .video).first {
        let size = v.naturalSize.applying(v.preferredTransform)
        info.hasVideo = true
        info.width = Int(abs(size.width).rounded())
        info.height = Int(abs(size.height).rounded())
        info.fps = Double(v.nominalFrameRate)
    }
    for a in asset.tracks(withMediaType: .audio) {
        guard let desc = a.formatDescriptions.first,
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc as! CMAudioFormatDescription)?.pointee else { continue }
        info.channels += Int(basic.mChannelsPerFrame)
        info.sampleRate = max(info.sampleRate, basic.mSampleRate)
    }
#else
    let text = (try? FFmpeg.run(["-hide_banner", "-nostdin", "-i", url.path], stderrOnly: true)) ?? ""
    info = parseFFmpegInfo(text)
#endif
    return info.hasVideo || info.hasAudio ? info : nil
}

/// For the self-test: ffmpeg's description of a file, read (on every system).
public func parseMediaInfoForTest(_ text: String) -> MediaInfo { parseFFmpegInfo(text) }

/// The stream list ffmpeg prints for a file: "Duration: 00:01:02.03", "Video: h264 ..., 1920x1080 ...,
/// 29.97 fps", "Audio: aac ..., 48000 Hz, stereo", and a rotation for portrait phone clips.
func parseFFmpegInfo(_ text: String) -> MediaInfo {
    var info = MediaInfo()
    var rotated = false
    func first(_ pattern: String, in s: Substring) -> String? {
        s.range(of: pattern, options: .regularExpression).map { String(s[$0]) }
    }
    for line in text.split(separator: "\n") {
        if line.contains("Duration:"), let d = first(#"\d+:\d{2}:\d{2}(\.\d+)?"#, in: line) {
            let p = d.split(separator: ":").compactMap { Double($0) }
            if p.count == 3 { info.duration = p[0] * 3600 + p[1] * 60 + p[2] }
        } else if line.contains("Stream #"), line.contains("Video:"), !info.hasVideo,
                  !line.contains("attached pic"), !line.contains("mjpeg"), !line.contains("png") {
            info.hasVideo = true
            if let s = first(#" \d{2,5}x\d{2,5}"#, in: line) {
                let wh = s.trimmingCharacters(in: .whitespaces).split(separator: "x").compactMap { Int($0) }
                if wh.count == 2 { info.width = wh[0]; info.height = wh[1] }
            }
            if let f = first(#"[\d.]+ fps"#, in: line) { info.fps = Double(f.split(separator: " ")[0]) ?? 0 }
            else if let f = first(#"[\d.]+ tbr"#, in: line) { info.fps = Double(f.split(separator: " ")[0]) ?? 0 }
        } else if line.contains("Stream #"), line.contains("Audio:") {
            let layout: [(String, Int)] = [("mono", 1), ("stereo", 2), ("2.1", 3), ("quad", 4), ("4.0", 4), ("5.0", 5), ("5.1", 6), ("7.1", 8)]
            var n = layout.first { line.contains(", \($0.0)") }?.1 ?? 0
            if n == 0, let c = first(#"\d+ channels"#, in: line) { n = Int(c.split(separator: " ")[0]) ?? 0 }
            info.channels += max(1, n)
            if let r = first(#"\d+ Hz"#, in: line) { info.sampleRate = max(info.sampleRate, Double(r.split(separator: " ")[0]) ?? 0) }
        } else if line.contains("rotate"), let r = first(#"-?\d+"#, in: line), abs(Int(r) ?? 0) % 180 == 90 {
            rotated = true
        } else if line.contains("rotation of"), let r = first(#"-?\d+(\.\d+)? degrees"#, in: line),
                  let deg = Double(r.split(separator: " ")[0]), Int(abs(deg).rounded()) % 180 == 90 {
            rotated = true
        }
    }
    if rotated { swap(&info.width, &info.height) }
    return info
}

/// A project made from folders instead of an editor's XML: each folder is one camera, phone or
/// recorder and goes on its own track (its files end to end, in the order they were recorded),
/// written as the same kind of XML Premiere exports, so everything after it works as with one.
public enum ProjectBuilder {
    /// One track to build: its name and every file in it.
    public struct Source {
        public var name: String
        public let folder: URL
        public var files: [URL]
        public init(name: String, folder: URL, files: [URL]) {
            self.name = name
            self.folder = folder
            self.files = files
        }

        /// Whether it has picture (by the files' extensions, before reading them).
        public var isCamera: Bool { files.contains { videoExtensions.contains($0.pathExtension.lowercased()) } }
    }

    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "mxf", "mts", "m2ts", "avi", "mkv", "3gp", "webm", "insv"]

    /// Where projects built from folders are kept (the editor's XML is exported apart, by the user).
    public static let projectsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Synco/Proyectos")

    /// The deepest folder that holds all of them (the shoot's folder, for its name and to save the result in).
    public static func commonFolder(_ folders: [URL]) -> URL? {
        guard var parts = folders.first?.standardizedFileURL.pathComponents else { return nil }
        for f in folders.dropFirst() {
            let other = f.standardizedFileURL.pathComponents
            parts = Array(zip(parts, other).prefix { $0 == $1 }.map(\.0))
        }
        guard parts.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: parts))
    }

    /// A free file name for a new project in `projectsDir`.
    public static func newProjectURL(name: String) -> URL {
        let clean = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var url = projectsDir.appendingPathComponent(clean + ".xml")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = projectsDir.appendingPathComponent("\(clean) \(n).xml")
            n += 1
        }
        return url
    }

    static let mediaExtensions: Set<String> = videoExtensions.union([
        "wav", "bwf", "aif", "aiff", "mp3", "m4a", "aac", "flac", "caf", "ogg", "opus", "wma",
    ])
    /// Folders a camera fills with copies or thumbnails that are not the footage.
    static let skippedFolders: Set<String> = ["proxy", "proxies", "thmbnl", "thumbnails", "sub", "general", "cache"]

    public static func isMedia(_ url: URL) -> Bool {
        mediaExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix("._")
    }

    /// The media files in a folder and its subfolders, by name.
    public static func mediaFiles(in folder: URL) -> [URL] {
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        var out = [URL]()
        while let url = walker?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if skippedFolders.contains(url.lastPathComponent.lowercased()) { walker?.skipDescendants() }
                continue
            }
            if mediaExtensions.contains(url.pathExtension.lowercased()) && !url.lastPathComponent.hasPrefix("._") { out.append(url) }
        }
        return out.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The tracks for what was dropped: a folder with media of its own is one track; a folder that
    /// only holds folders (a shoot with CAM A, CAM B, SONIDO) gives one track per subfolder.
    /// Loose files dropped together make one more track.
    public static func sources(from urls: [URL]) -> [Source] {
        var out = [Source]()
        var loose = [URL]()
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if mediaExtensions.contains(url.pathExtension.lowercased()) { loose.append(url) }
                continue
            }
            let own = ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil,
                                                                     options: [.skipsHiddenFiles])) ?? [])
            let hasOwnMedia = own.contains { mediaExtensions.contains($0.pathExtension.lowercased()) }
            let subfolders = own.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter { !mediaFiles(in: $0).isEmpty }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if !hasOwnMedia && subfolders.count > 1 {
                for sub in subfolders { out.append(Source(name: sub.lastPathComponent, folder: sub, files: mediaFiles(in: sub))) }
            } else {
                let files = mediaFiles(in: url)
                if !files.isEmpty { out.append(Source(name: url.lastPathComponent, folder: url, files: files)) }
            }
        }
        if !loose.isEmpty {
            let folder = loose[0].deletingLastPathComponent()
            out.append(Source(name: folder.lastPathComponent, folder: folder, files: loose))
        }
        return out
    }

    /// The tracks of a project Synco built, as the folders they came from (nil for an editor's XML).
    public static func sources(of project: FCP7Project) -> [Source]? {
        guard !project.clips.isEmpty, project.clips.allSatisfy({ $0.deviceName != nil }) else { return nil }
        var order = [String](), files = [String: [URL]]()
        for c in project.clips {
            let name = c.deviceName!
            if files[name] == nil { order.append(name) }
            files[name, default: []].append(c.url)
        }
        return order.map { name in
            let f = files[name]!
            let folder = commonFolder(Array(Set(f.map { $0.deletingLastPathComponent() }))) ?? f[0].deletingLastPathComponent()
            return Source(name: name, folder: folder, files: f)
        }
    }

    public struct NothingToAdd: Error, CustomStringConvertible {
        public let description: String
    }

    /// The tracks after a drop: everything dropped into the track named `track`, or, with none,
    /// each folder as a new track (names kept apart: a track's name is what makes it one device).
    public static func adding(_ urls: [URL], to sources: [Source], track: String?) throws -> [Source] {
        var sources = sources
        if let track, let i = sources.firstIndex(where: { $0.name == track }) {
            let have = Set(sources[i].files.map(\.standardizedFileURL.path))
            let added = urls.flatMap { url -> [URL] in
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                return isDir.boolValue ? mediaFiles(in: url) : [url]
            }.filter { isMedia($0) && !have.contains($0.standardizedFileURL.path) }
            guard !added.isEmpty else { throw NothingToAdd(description: "Esos archivos ya están en la pista, o no son video ni audio.") }
            sources[i].files += added
            return sources
        }
        var new = self.sources(from: urls)
        guard !new.isEmpty else { throw NothingToAdd(description: "No hay videos ni audios en lo que soltaste.") }
        for j in new.indices {
            var name = new[j].name, n = 2
            while (sources + new[..<j]).contains(where: { $0.name == name }) { name = "\(new[j].name) \(n)"; n += 1 }
            new[j].name = name
        }
        return sources + new
    }

    /// Writes the project's XML to `url`. Files that are neither picture nor sound are left out
    /// and returned, so they can be named. Calls `progress` as files are looked at.
    @discardableResult
    public static func build(_ sources: [Source], name: String, to url: URL,
                             progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        // Look at every file first: the sequence takes the frame rate and size most of the footage has.
        let all = sources.flatMap(\.files)
        var infos = [URL: MediaInfo]()
        let lock = NSLock()
        var done = 0
        DispatchQueue.concurrentPerform(iterations: all.count) { i in
            let info = probeMedia(all[i])
            lock.lock()
            infos[all[i]] = info
            done += 1
            progress(done, all.count)
            lock.unlock()
        }
        let skipped = all.filter { infos[$0] == nil }
        let videos = infos.values.filter { $0.hasVideo && $0.fps > 0 }
        func mostCommon<T: Hashable>(_ key: (MediaInfo) -> T) -> T? {
            Dictionary(grouping: videos, by: key).max { a, b in
                a.value.reduce(0) { $0 + $1.duration } < b.value.reduce(0) { $0 + $1.duration }
            }?.key
        }
        let seqRate = Rate(mostCommon { (($0.fps * 100).rounded() / 100) } ?? 25)
        let size = mostCommon { [$0.width, $0.height] } ?? [1920, 1080]

        let doc = XMLDocument(rootElement: XMLElement(name: "xmeml"))
        doc.version = "1.0"
        doc.characterEncoding = "UTF-8"
        doc.dtd = XMLDTD()
        doc.dtd?.name = "xmeml"
        let root = doc.rootElement()!
        root.addAttribute(XMLNode.attribute(withName: "version", stringValue: "4") as! XMLNode)
        let sequence = el("sequence", attrs: ["id": "sequence-1"])
        root.addChild(sequence)
        sequence.addChild(el("name", name))
        let durationNode = el("duration", "0")
        sequence.addChild(durationNode)
        sequence.addChild(seqRate.element())
        let media = el("media")
        sequence.addChild(media)
        let video = el("video")
        video.addChild(el("format", [el("samplecharacteristics", [
            seqRate.element(), el("width", String(size[0])), el("height", String(size[1])),
            el("anamorphic", "FALSE"), el("pixelaspectratio", "square"), el("fielddominance", "none"),
        ])]))
        let audio = el("audio")
        audio.addChild(el("format", [el("samplecharacteristics", [el("depth", "16"), el("samplerate", "48000")])]))
        media.addChild(video)
        media.addChild(audio)

        struct Item { let element: XMLElement; let kind: String; let track: Int; let index: Int }
        var videoTracks = [XMLElement](), audioTracks = [XMLElement]()
        var cameraAudio = [XMLElement](), recorderAudio = [XMLElement]()
        var fileNumber = 0, itemNumber = 0
        var end = 0
        // Cameras first (their picture on V1, V2…, their sound right under), recorders after.
        let ordered = sources.filter { s in s.files.contains { infos[$0]?.hasVideo == true } }
            + sources.filter { s in !s.files.contains { infos[$0]?.hasVideo == true } }
        var pending = [(items: [Item], file: URL)]()
        for source in ordered {
            let files = source.files.filter { infos[$0] != nil }
                .sorted { (recordingStart(url: $0) ?? .distantFuture, $0.path) < (recordingStart(url: $1) ?? .distantFuture, $1.path) }
            guard !files.isEmpty else { continue }
            let isCamera = files.contains { infos[$0]!.hasVideo }
            let channels = min(8, max(1, files.map { infos[$0]!.channels }.max() ?? 1))
            var vTrack: XMLElement?
            if isCamera {
                vTrack = el("track", attrs: ["SyncoDevice": source.name])
                videoTracks.append(vTrack!)
            }
            let aTracks = (0..<channels).map { _ in el("track", attrs: ["SyncoDevice": source.name]) }
            if isCamera { cameraAudio += aTracks } else { recorderAudio += aTracks }
            var at = 0
            for file in files {
                let info = infos[file]!
                let frames = max(1, Int((info.duration * seqRate.actual).rounded()))
                fileNumber += 1
                let fileRate = info.hasVideo && info.fps > 0 ? Rate(info.fps) : seqRate
                let fileElement = el("file", attrs: ["id": "file-\(fileNumber)"])
                fileElement.addChild(el("name", file.lastPathComponent))
                fileElement.addChild(el("pathurl", file.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")))
                fileElement.addChild(fileRate.element())
                fileElement.addChild(el("duration", String(max(1, Int((info.duration * fileRate.actual).rounded())))))
                let fileMedia = el("media")
                if info.hasVideo {
                    fileMedia.addChild(el("video", [el("samplecharacteristics", [
                        fileRate.element(), el("width", String(info.width)), el("height", String(info.height)),
                        el("anamorphic", "FALSE"), el("pixelaspectratio", "square"), el("fielddominance", "none"),
                    ])]))
                }
                if info.hasAudio {
                    fileMedia.addChild(el("audio", [
                        el("samplecharacteristics", [el("depth", "16"), el("samplerate", String(Int(info.sampleRate > 0 ? info.sampleRate : 48000)))]),
                        el("channelcount", String(info.channels)),
                    ]))
                }
                fileElement.addChild(fileMedia)

                var fullFileWritten = false
                func clipItem() -> XMLElement {
                    itemNumber += 1
                    let item = el("clipitem", attrs: ["id": "clipitem-\(itemNumber)"])
                    item.addChild(el("masterclipid", "masterclip-\(fileNumber)"))
                    item.addChild(el("name", file.lastPathComponent))
                    item.addChild(el("enabled", "TRUE"))
                    item.addChild(el("duration", String(frames)))
                    item.addChild(seqRate.element())
                    item.addChild(el("start", String(at)))
                    item.addChild(el("end", String(at + frames)))
                    item.addChild(el("in", "0"))
                    item.addChild(el("out", String(frames)))
                    // The file in full once, then by its id.
                    item.addChild(fullFileWritten ? el("file", attrs: ["id": "file-\(fileNumber)"]) : fileElement)
                    fullFileWritten = true
                    return item
                }
                var items = [Item]()
                if info.hasVideo, let vTrack {
                    let item = clipItem()
                    vTrack.addChild(item)
                    items.append(Item(element: item, kind: "video", track: videoTracks.count, index: vTrack.elements(forName: "clipitem").count))
                }
                for ch in 0..<min(info.channels, channels) {
                    let item = clipItem()
                    item.addChild(el("sourcetrack", [el("mediatype", "audio"), el("trackindex", String(ch + 1))]))
                    aTracks[ch].addChild(item)
                    items.append(Item(element: item, kind: "audio", track: ch, index: aTracks[ch].elements(forName: "clipitem").count))
                }
                pending.append((items, file))
                at += frames
            }
            end = max(end, at)
        }
        audioTracks = cameraAudio + recorderAudio
        for t in videoTracks { video.addChild(t) }
        for t in audioTracks { audio.addChild(t) }
        durationNode.stringValue = String(end)

        // Every item of a file linked to the others, as editors write it.
        func position(_ e: XMLElement) -> (kind: String, track: Int, index: Int)? {
            for (i, t) in videoTracks.enumerated() {
                if let j = t.elements(forName: "clipitem").firstIndex(where: { $0 === e }) { return ("video", i + 1, j + 1) }
            }
            for (i, t) in audioTracks.enumerated() {
                if let j = t.elements(forName: "clipitem").firstIndex(where: { $0 === e }) { return ("audio", i + 1, j + 1) }
            }
            return nil
        }
        for group in pending where group.items.count > 1 {
            let places = group.items.map { ($0.element, position($0.element)) }
            for item in group.items {
                for (other, p) in places {
                    guard let p, let id = other.attribute(forName: "id")?.stringValue else { continue }
                    var parts = [el("linkclipref", id), el("mediatype", p.kind), el("trackindex", String(p.track)), el("clipindex", String(p.index))]
                    if p.kind == "audio" { parts.append(el("groupindex", "1")) }
                    item.element.addChild(el("link", parts))
                }
            }
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try doc.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement]).write(to: url, options: .atomic)
        return skipped
    }

    /// An editor frame rate: whole-number timebase, with NTSC for 23.976, 29.97 and 59.94.
    struct Rate {
        let timebase: Int
        let ntsc: Bool
        var actual: Double { ntsc ? Double(timebase) * 1000 / 1001 : Double(timebase) }

        init(_ fps: Double) {
            let whole = Int(fps.rounded())
            if abs(fps - Double(whole)) > 0.005, abs(fps - Double(whole) * 1000 / 1001) < 0.01 {
                timebase = whole; ntsc = true
            } else {
                timebase = max(1, whole); ntsc = false
            }
        }

        func element() -> XMLElement {
            el("rate", [el("timebase", String(timebase)), el("ntsc", ntsc ? "TRUE" : "FALSE")])
        }
    }
}

private func el(_ name: String, _ text: String) -> XMLElement { XMLElement(name: name, stringValue: text) }

private func el(_ name: String, _ children: [XMLElement] = [], attrs: [String: String] = [:]) -> XMLElement {
    let e = XMLElement(name: name)
    for (k, v) in attrs.sorted(by: { $0.key < $1.key }) {
        e.addAttribute(XMLNode.attribute(withName: k, stringValue: v) as! XMLNode)
    }
    for c in children { e.addChild(c) }
    return e
}

private func el(_ name: String, attrs: [String: String]) -> XMLElement { el(name, [], attrs: attrs) }
