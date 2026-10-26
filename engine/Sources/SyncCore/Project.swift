import Foundation

/// One media file in the project and every timeline item that uses it
/// (a video item plus its audio channel items, linked together).
public final class ProjectClip {
    public let fileID: String
    public let name: String
    public internal(set) var url: URL
    /// The folder the file lives in: one camera, phone or recorder card.
    public var device: String { url.deletingLastPathComponent().path }
    public var exists: Bool { FileManager.default.fileExists(atPath: url.path) }
    /// Whether the editor says the file has a picture (a camera or phone, not a recorder).
    public let hasVideo: Bool
    /// Media length in sequence frames, as the editor reported it.
    public let frames: Int
    let items: [XMLElement]

    init(fileID: String, name: String, url: URL, frames: Int, hasVideo: Bool, items: [XMLElement]) {
        self.fileID = fileID
        self.name = name
        self.url = url
        self.hasVideo = hasVideo
        self.frames = frames
        self.items = items
    }
}

public enum ProjectError: Error, CustomStringConvertible {
    case notFCP7(String)

    public var description: String {
        switch self {
        case .notFCP7(let m): return "no es un XML de Final Cut Pro 7 / Premiere: \(m)"
        }
    }
}

/// A Final Cut Pro 7 XML project (what Premiere, Resolve and Vegas export),
/// edited in place so everything the sync does not touch is written back as is.
public final class FCP7Project {
    let document: XMLDocument
    let sequence: XMLElement
    public let fps: Int
    public let sequenceName: String
    public private(set) var clips: [ProjectClip] = []

    public init(url: URL) throws {
        document = try XMLDocument(contentsOf: url, options: [.nodePreserveAll])
        // The sequence can sit right under <xmeml> or inside a <project> (bins, other editors).
        guard let root = document.rootElement(), root.name == "xmeml",
              let seq = root.elements(forName: "sequence").first
                ?? (try? root.nodes(forXPath: ".//sequence"))?.first as? XMLElement else {
            throw ProjectError.notFCP7("falta <xmeml><sequence>")
        }
        sequence = seq
        sequenceName = seq.elements(forName: "name").first?.stringValue ?? "Secuencia"
        let timebase = seq.elements(forName: "rate").first?.elements(forName: "timebase").first?.stringValue
        fps = Int(timebase ?? "") ?? 24

        var paths = [String: (name: String, url: URL)]()
        var itemsByFile = [String: [XMLElement]]()
        var order = [String]()
        var video = Set<String>()
        for item in clipItems() {
            guard let file = item.elements(forName: "file").first,
                  let id = file.attribute(forName: "id")?.stringValue else { continue }
            if let path = file.elements(forName: "pathurl").first?.stringValue,
               let url = URL(string: path) {
                let name = file.elements(forName: "name").first?.stringValue ?? url.lastPathComponent
                paths[id] = (name, URL(fileURLWithPath: url.path))
            }
            if file.elements(forName: "media").first?.elements(forName: "video").first != nil
                || tracks("video").contains(where: { $0 == item.parent }) { video.insert(id) }
            if itemsByFile[id] == nil { order.append(id) }
            itemsByFile[id, default: []].append(item)
        }
        // A file can be described in full anywhere in the document (a bin, another
        // sequence) and only referenced by id in this one.
        if paths.count < order.count, let all = try? root.nodes(forXPath: ".//file[pathurl]") {
            for case let file as XMLElement in all {
                guard let id = file.attribute(forName: "id")?.stringValue, paths[id] == nil,
                      let path = file.elements(forName: "pathurl").first?.stringValue, let url = URL(string: path) else { continue }
                let name = file.elements(forName: "name").first?.stringValue ?? url.lastPathComponent
                paths[id] = (name, URL(fileURLWithPath: url.path))
            }
        }
        for id in order {
            guard let (name, url) = paths[id], let items = itemsByFile[id] else { continue }
            let frames = items.compactMap { Int($0.elements(forName: "duration").first?.stringValue ?? "") }.max() ?? 0
            clips.append(ProjectClip(fileID: id, name: name, url: url, frames: frames, hasVideo: video.contains(id), items: items))
        }
    }

    func tracks(_ kind: String) -> [XMLElement] {
        sequence.elements(forName: "media").first?.elements(forName: kind).first?.elements(forName: "track") ?? []
    }

    func clipItems() -> [XMLElement] {
        (tracks("video") + tracks("audio")).flatMap { $0.elements(forName: "clipitem") }
    }

    /// Moves each clip so its media starts at `starts[fileID]` (sequence frames),
    /// keeping each item's trim, then fixes the track order and the links.
    public func apply(starts: [String: Int], labels: [String: String] = [:], disabled: Set<String> = []) {
        for clip in clips {
            guard let start = starts[clip.fileID] else { continue }
            for item in clip.items {
                let inPoint = int(item, "in") ?? 0
                // Keep the editor's own length: with non-integer frame rates it
                // rounds end - start and out - in differently.
                let length = (int(item, "end") ?? 0) - (int(item, "start") ?? 0)
                let outPoint = int(item, "out") ?? clip.frames
                set(item, "start", start + inPoint)
                set(item, "end", start + inPoint + (length > 0 ? length : outPoint - inPoint))
                if let label = labels[clip.fileID] { setLabel(item, label) }
                if disabled.contains(clip.fileID) { setText(item, "enabled", "FALSE") }
            }
        }
        // Every track in timeline order, then link indexes rebuilt from it.
        var position = [String: (track: Int, clip: Int)]()
        var lastFrame = 0
        for kind in ["video", "audio"] {
            for (t, track) in tracks(kind).enumerated() {
                let items = track.elements(forName: "clipitem")
                for item in items { item.detach() }
                let sorted = items.sorted { (int($0, "start") ?? 0) < (int($1, "start") ?? 0) }
                let insertAt = track.children?.firstIndex { $0.kind == .element } ?? track.childCount
                for (i, item) in sorted.enumerated() {
                    track.insertChild(item, at: insertAt + i)
                    if let id = item.attribute(forName: "id")?.stringValue { position[id] = (t + 1, i + 1) }
                    lastFrame = max(lastFrame, int(item, "end") ?? 0)
                }
            }
        }
        for item in clipItems() {
            for link in item.elements(forName: "link") {
                guard let ref = link.elements(forName: "linkclipref").first?.stringValue,
                      let p = position[ref] else { continue }
                set(link, "trackindex", p.track)
                set(link, "clipindex", p.clip)
            }
        }
        set(sequence, "duration", lastFrame)
    }

    /// Names the sequence in the written XML (the project keeps its original name).
    public func rename(_ name: String) {
        setText(sequence, "name", name)
    }

    /// Points a clip at a file somewhere else, in the model and in the XML.
    public func relink(_ clip: ProjectClip, to url: URL) {
        clip.url = url
        let path = url.absoluteString.replacingOccurrences(of: "file:///", with: "file://localhost/")
        for item in clip.items {
            for file in item.elements(forName: "file") {
                file.elements(forName: "pathurl").first?.stringValue = path
            }
        }
    }

    /// The clip's label as the editor wrote it ("" when none).
    public func label(_ clip: ProjectClip) -> String {
        clip.items.first?.elements(forName: "labels").first?.elements(forName: "label2").first?.stringValue ?? ""
    }

    /// Where each clip's media starts on the timeline as the XML has it now, in seconds.
    public func mediaStarts() -> [String: Double] {
        var out = [String: Double]()
        for clip in clips {
            for item in clip.items {
                guard let start = int(item, "start"), start >= 0 else { continue }
                out[clip.fileID] = Double(start - (int(item, "in") ?? 0)) / Double(fps)
                break
            }
        }
        return out
    }

    public func write(to url: URL) throws {
        let data = document.xmlData(options: [.nodePrettyPrint, .nodeCompactEmptyElement])
        try data.write(to: url, options: .atomic)
    }

    private func int(_ e: XMLElement, _ name: String) -> Int? {
        Int(e.elements(forName: name).first?.stringValue ?? "")
    }

    private func set(_ e: XMLElement, _ name: String, _ value: Int) {
        if let child = e.elements(forName: name).first {
            child.stringValue = String(value)
        } else {
            e.addChild(XMLElement(name: name, stringValue: String(value)))
        }
    }

    private func setText(_ e: XMLElement, _ name: String, _ value: String) {
        if let child = e.elements(forName: name).first {
            child.stringValue = value
        } else {
            e.addChild(XMLElement(name: name, stringValue: value))
        }
    }

    private func setLabel(_ item: XMLElement, _ label: String) {
        let labels = item.elements(forName: "labels").first ?? {
            let l = XMLElement(name: "labels")
            item.addChild(l)
            return l
        }()
        if let l2 = labels.elements(forName: "label2").first {
            l2.stringValue = label
        } else {
            labels.addChild(XMLElement(name: "label2", stringValue: label))
        }
    }
}
