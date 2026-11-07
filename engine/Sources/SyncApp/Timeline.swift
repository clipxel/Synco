import AppKit
import SwiftUI
import SyncCore

/// Every track drawn in one canvas the size of the window; the view pans and zooms
/// over the timeline instead of laying out hours of clips as views.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel
    /// Seconds at the left edge of the lanes.
    @State private var viewStart = 0.0
    /// Pixels per second; nil means fit the whole timeline.
    @State private var zoom: Double?
    @State private var hoverPoint: CGPoint?
    @State private var dragFrom: (x: CGFloat, start: Double)?
    @State private var scrollMonitor: Any?
    @State private var laneWidth: CGFloat = 1
    /// The row a drop would land on while dragging files over (the strip under the tracks is `tracks.count`).
    @State private var dropRow: Int?
    /// The track a clip dragged up or down would go to.
    @State private var moveRow: Int?

    var body: some View {
        GeometryReader { geo in
            let laneW = max(1, geo.size.width - Theme.Size.trackHeaderW)
            let total = max(model.totalDuration, 1)
            let pps = zoom ?? Double(laneW) / total
            let empty = model.tracks.isEmpty
            let lanesH = geo.size.height - (empty ? 0 : Theme.Size.overviewH + 28)
            // Under the tracks, a strip to drop folders on for new tracks; with none yet, all of it.
            let newH: CGFloat = empty ? max(lanesH, 240) : 64
            let rowH = max(Theme.Size.trackMinH, (lanesH - newH) / CGFloat(max(model.tracks.count, 1)))
            VStack(spacing: 0) {
                if !empty {
                    ZoomBar(fit: { zoom = nil; viewStart = 0 },
                            zoomIn: { setZoom(pps * 2, laneW: laneW, total: total) },
                            zoomOut: { setZoom(pps / 2, laneW: laneW, total: total) },
                            pps: pps)
                    Ruler(viewStart: viewStart, pps: pps, width: laneW)
                }
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        if !empty {
                            HStack(spacing: 0) {
                                VStack(spacing: 0) {
                                    ForEach(model.tracks) { t in TrackHeader(track: t).frame(height: rowH) }
                                }
                                .frame(width: Theme.Size.trackHeaderW)
                                lanes(width: laneW, rowH: rowH, pps: pps)
                            }
                            .overlay(alignment: .topLeading) {
                                if let r = dropRow, r < model.tracks.count {
                                    RoundedRectangle(cornerRadius: Theme.Size.radiusMd)
                                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                                        .background(Theme.accent.opacity(0.08))
                                        .frame(height: rowH - 2)
                                        .offset(y: CGFloat(r) * rowH + 1)
                                        .allowsHitTesting(false)
                                }
                            }
                        }
                        NewTrackLane(targeted: dropRow == model.tracks.count).frame(height: newH)
                    }
                    .onDrop(of: [.fileURL], delegate: TimelineDrop(model: model, rowH: rowH, row: $dropRow))
                }
                if !empty {
                    Overview(viewStart: $viewStart, visible: Double(laneW) / pps, total: total, playhead: model.playhead)
                        .frame(height: Theme.Size.overviewH)
                        .padding(.leading, Theme.Size.trackHeaderW)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if model.pictureClip != nil, model.playhead != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        PictureView(player: model.videoPlayer)
                            .frame(width: 320, height: 180)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Size.radiusMd))
                        Text(model.pictureClip.flatMap { model.clip($0)?.name } ?? "")
                            .font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
                    }
                    .padding(Theme.Size.space2)
                    .background(RoundedRectangle(cornerRadius: Theme.Size.radiusMd).fill(Theme.surface2))
                    .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                    .padding(.trailing, Theme.Size.space3)
                    .padding(.bottom, Theme.Size.overviewH + Theme.Size.space3)
                }
            }
            .onAppear { laneWidth = laneW; installScrollMonitor(total: total) }
            .onChange(of: laneW) { laneWidth = $0 }
            .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m) } }
        }
        .background(Theme.trackBg)
    }

    private func setZoom(_ pps: Double, laneW: CGFloat, total: Double) {
        let fit = Double(laneW) / total
        let new = min(200, max(fit, pps))
        let center = viewStart + Double(laneW) / 2 / (zoom ?? fit)
        zoom = new <= fit * 1.001 ? nil : new
        viewStart = zoom == nil ? 0 : max(0, center - Double(laneW) / 2 / new)
    }

    private func lanes(width: CGFloat, rowH: CGFloat, pps: Double) -> some View {
        let hovered = hoverPoint.flatMap { clipAt($0, rowH: rowH, pps: pps) }
        return Canvas { ctx, size in
            for (row, track) in model.tracks.enumerated() {
                let y0 = CGFloat(row) * rowH
                ctx.fill(Path(CGRect(x: 0, y: y0, width: size.width, height: rowH)), with: .color(row % 2 == 0 ? Theme.trackBg : Theme.bg))
                ctx.fill(Path(CGRect(x: 0, y: y0 + rowH - 1, width: size.width, height: 1)), with: .color(Theme.border))
                for clip in track.clips {
                    let start = model.start(clip, in: track)
                    let dur = model.duration(clip)
                    let x = CGFloat((start - viewStart) * pps)
                    let w = max(1, CGFloat(dur * pps))
                    guard x + w >= 0, x <= size.width else { continue }
                    let rect = CGRect(x: x, y: y0 + 4, width: w, height: rowH - 9)
                    drawClip(ctx, clip: clip, rect: rect, pps: pps, visible: size.width,
                             hovered: hovered === clip, selected: model.selected == clip.fileID)
                }
            }
            // Where it plays from.
            if let t = model.playhead {
                let x = CGFloat((t - viewStart) * pps)
                if x >= 0, x <= size.width {
                    ctx.fill(Path(CGRect(x: x - 0.5, y: 0, width: 1.5, height: size.height)), with: .color(Theme.danger))
                }
            }
            // A clip being dragged onto another track: that track, outlined.
            if let r = moveRow, r < model.tracks.count {
                ctx.stroke(Path(roundedRect: CGRect(x: 1, y: CGFloat(r) * rowH + 1, width: size.width - 2, height: rowH - 2), cornerRadius: 4),
                           with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            }
        }
        .frame(width: width, height: rowH * CGFloat(model.tracks.count))
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            if case .active(let p) = phase { hoverPoint = p } else { hoverPoint = nil }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragFrom == nil { dragFrom = (g.startLocation.x, viewStart) }
                    // A clip dragged up or down goes to the track it is let go on.
                    if let clip = clipAt(g.startLocation, rowH: rowH, pps: pps), model.canEdit {
                        let row = Int(g.location.y / rowH), from = Int(g.startLocation.y / rowH)
                        let targets = model.moveTargets(clip)
                        moveRow = row != from && row >= 0 && row < model.tracks.count && targets.contains { $0.id == model.tracks[row].id } ? row : nil
                        if moveRow != nil || abs(g.translation.height) > abs(g.translation.width) { return }
                    }
                    guard let from = dragFrom, zoom != nil else { return }
                    viewStart = max(0, from.start - Double(g.location.x - from.x) / pps)
                }
                .onEnded { g in
                    if let r = moveRow, let clip = clipAt(g.startLocation, rowH: rowH, pps: pps) {
                        model.moveClip(clip.fileID, to: model.tracks[r])
                    } else if abs(g.translation.width) < 3 && abs(g.translation.height) < 3 {
                        model.selected = clipAt(g.location, rowH: rowH, pps: pps)?.fileID
                        if model.outcome != nil { model.seek(viewStart + Double(g.location.x) / pps) }
                    }
                    moveRow = nil
                    dragFrom = nil
                }
        )
        .contextMenu {
            if let clip = hovered { ClipMenu(clip: clip, at: hoverPoint.map { viewStart + Double($0.x) / pps }) }
        }
        .overlay(alignment: .topLeading) {
            if let clip = hovered, let p = hoverPoint {
                ClipTooltip(clip: clip)
                    .offset(x: min(p.x + 12, width - 280), y: p.y + 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private func drawClip(_ ctx: GraphicsContext, clip: ProjectClip, rect: CGRect, pps: Double, visible: CGFloat,
                          hovered: Bool, selected: Bool) {
        let fill: Color = {
            if !clip.exists { return Theme.clipMissing }
            guard let p = model.placements[clip.fileID] else { return Theme.clipIdle }
            switch model.outcome?.quality(p) ?? .guessed {
            case .exact: return Theme.clipExact
            case .approximate: return Theme.clipApprox
            case .guessed: return Theme.clipGuessed
            }
        }()
        let shape = Path(roundedRect: rect, cornerRadius: Theme.Size.radiusSm)
        ctx.fill(shape, with: .color(fill.opacity(model.ignored.contains(clip.fileID) ? 0.45 : 1)))

        // Waveform, one bar per screen pixel, only for the visible part.
        if let peaks = model.peaks[clip.fileID], !peaks.isEmpty, rect.width > 4 {
            let mid = rect.midY, half = rect.height / 2 - 3
            let from = max(rect.minX, 0), to = min(rect.maxX, visible)
            var wave = Path()
            var x = from
            while x < to {
                let t0 = Double(x - rect.minX) / pps * AppModel.peaksPerSecond
                let t1 = Double(x + 1 - rect.minX) / pps * AppModel.peaksPerSecond
                let a = max(0, Int(t0)), b = min(peaks.count, max(a + 1, Int(t1.rounded(.up))))
                var m: Float = 0
                if a < b { for i in a..<b { m = max(m, peaks[i]) } }
                let h = CGFloat(m) * half
                wave.addRect(CGRect(x: x, y: mid - h, width: 1, height: max(0.5, 2 * h)))
                x += 1
            }
            ctx.fill(wave, with: .color(ink(clip).opacity(0.55)))
        }

        if hovered || selected {
            ctx.stroke(shape, with: .color(Theme.accent), lineWidth: selected ? 2 : 1)
        } else {
            ctx.stroke(shape, with: .color(Theme.trackBg.opacity(0.8)), lineWidth: 1)
        }
        if rect.width > 70 {
            let label = Text(clip.name).font(Theme.Font.xs).foregroundColor(ink(clip))
            let resolved = ctx.resolve(label)
            let size = resolved.measure(in: rect.size)
            if size.width + 8 < rect.width {
                let cx = min(max(rect.midX, size.width / 2 + 6), visible - size.width / 2 - 6)
                let x = min(max(cx, rect.minX + size.width / 2 + 4), rect.maxX - size.width / 2 - 4)
                ctx.draw(resolved, at: CGPoint(x: x, y: rect.minY + 10))
            }
        }
    }

    /// Dark ink on yellow clips, white on the rest.
    private func ink(_ clip: ProjectClip) -> Color {
        model.quality(clip.fileID) == .approximate && clip.exists ? Theme.onClipApprox : Theme.onClip
    }

    private func clipAt(_ p: CGPoint, rowH: CGFloat, pps: Double) -> ProjectClip? {
        let row = Int(p.y / rowH)
        guard row >= 0, row < model.tracks.count else { return nil }
        let track = model.tracks[row]
        let t = viewStart + Double(p.x) / pps
        return track.clips.first { c in
            let s = model.start(c, in: track)
            return t >= s && t <= s + model.duration(c)
        }
    }

    /// Wheel pans; ⌘ + wheel zooms.
    private func installScrollMonitor(total: Double) {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard hoverPoint != nil else { return event }
            let laneW = laneWidth
            let total = max(model.totalDuration, 1)
            let pps = zoom ?? Double(laneW) / total
            if event.modifierFlags.contains(.command) {
                setZoom(pps * (event.scrollingDeltaY > 0 ? 1.25 : 0.8), laneW: laneW, total: total)
                return nil
            }
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : 0
            guard delta != 0, zoom != nil else { return event }
            let maxStart = max(0, total - Double(laneW) / pps)
            viewStart = min(maxStart, max(0, viewStart - Double(delta) * (event.hasPreciseScrollingDeltas ? 1 : 10) / pps))
            return nil
        }
    }
}

/// Files dragged over the timeline: onto a track they go into it, below the tracks they make new ones.
@MainActor
struct TimelineDrop: DropDelegate {
    let model: AppModel
    let rowH: CGFloat
    @Binding var row: Int?

    /// Only a project built from folders takes files into its tracks.
    private func target(_ y: CGFloat) -> Int {
        let count = model.tracks.count
        guard model.isBuilt else { return count }
        return min(count, max(0, Int(y / rowH)))
    }

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) && model.phase != .matching }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        row = target(info.location.y)
        return DropProposal(operation: .copy)
    }
    func dropExited(info: DropInfo) { row = nil }
    func performDrop(info: DropInfo) -> Bool {
        let r = target(info.location.y)
        row = nil
        let track = r < model.tracks.count ? model.tracks[r] : nil
        loadURLs(info.itemProviders(for: [.fileURL])) { model.drop($0, onto: track) }
        return true
    }
}

/// The strip under the tracks: drop folders or clips here for new tracks. With no project, the
/// whole timeline, with what to do and the recent projects.
struct NewTrackLane: View {
    @EnvironmentObject var model: AppModel
    let targeted: Bool

    var body: some View {
        let empty = model.tracks.isEmpty
        HStack(spacing: 0) {
            if !empty {
                Image(systemName: "plus")
                    .font(.system(size: 16))
                    .foregroundStyle(targeted ? Theme.accent : Theme.textMuted)
                    .frame(width: Theme.Size.trackHeaderW)
                    .frame(maxHeight: .infinity)
                    .background(Theme.surface)
            }
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Size.radiusMd)
                    .stroke(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: Theme.Size.radiusMd).fill(targeted ? Theme.accent.opacity(0.08) : .clear))
                    .padding(empty ? Theme.Size.space4 : Theme.Size.space2)
                if empty { start } else {
                    Text(model.isBuilt ? "Soltá acá una carpeta o clips para crear otra pista"
                                       : "Soltá acá carpetas para empezar un proyecto nuevo con ellas")
                        .font(Theme.Font.base)
                        .foregroundStyle(targeted ? Theme.accent : Theme.textMuted)
                }
            }
        }
        .background(Theme.trackBg)
    }

    @ViewBuilder private var start: some View {
        if model.phase == .reading {
            // Opening or building a project: what it is doing, where the eye is.
            VStack(spacing: Theme.Size.space3) {
                ProgressView().controlSize(.large)
                Text(model.message).font(Theme.Font.lg)
                if model.readTotal > 0 {
                    ProgressView(value: Double(model.readDone), total: Double(model.readTotal))
                        .frame(width: 280)
                        .tint(Theme.accent)
                }
            }
        } else {
            welcome
        }
    }

    private var welcome: some View {
        VStack(spacing: Theme.Size.space4) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(targeted ? Theme.accent : Theme.textMuted)
            Text("Soltá acá las carpetas de tus cámaras y grabadores")
                .font(Theme.Font.lg)
            Text("Cada carpeta es una pista, con sus tomas en el orden en que se grabaron. Después podés soltar más carpetas o clips sobre una pista para sumarlos, o abajo de todo para crear otra. También podés soltar el XML de tu editor.")
                .font(Theme.Font.base)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            HStack(spacing: Theme.Size.space2) {
                ActionButton(title: "Elegir carpetas…", systemImage: "folder.badge.plus", primary: true) { model.chooseFolders() }
                ActionButton(title: "Abrir proyecto o XML…", systemImage: "doc.text", primary: false) { model.chooseFile() }
            }
            let recents = model.prefs.recents.filter { FileManager.default.fileExists(atPath: $0) }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Size.space1) {
                    Text("Recientes").font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
                    ForEach(recents, id: \.self) { path in
                        Button {
                            model.userOpen(URL(fileURLWithPath: path))
                        } label: {
                            HStack {
                                Image(systemName: path.hasSuffix("." + SavedProject.fileExtension) ? "square.stack.3d.up"
                                      : path.hasPrefix(ProjectBuilder.projectsDir.path) ? "folder" : "doc.text")
                                Text((path as NSString).lastPathComponent)
                                if !path.hasPrefix(ProjectBuilder.projectsDir.path) {
                                    Text((path as NSString).deletingLastPathComponent)
                                        .foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.head)
                                }
                            }
                            .font(Theme.Font.base)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(.top, Theme.Size.space4)
            }
        }
        .padding(Theme.Size.space5)
    }
}

struct TrackHeader: View {
    @EnvironmentObject var model: AppModel
    let track: TrackRow

    var body: some View {
        VStack(spacing: Theme.Size.space1) {
            HStack(spacing: 6) {
                Image(systemName: track.kind == .drone ? "airplane" : track.kind == .camera ? "video.fill" : "mic.fill")
                    .font(.system(size: 16))
                if model.outcome != nil, track.kind != .drone {
                    Button { model.toggleMute(track) } label: {
                        Image(systemName: model.mutedTracks.contains(track.id) ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundStyle(model.mutedTracks.contains(track.id) ? Theme.warning : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Silenciar esta pista al reproducir")
                    Button { model.toggleSolo(track) } label: {
                        Text("S").font(Theme.Font.xs.weight(.bold))
                            .foregroundStyle(model.soloTrack == track.id ? Theme.accent : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Escuchar solo esta pista")
                }
            }
            Text(track.name).font(Theme.Font.xs)
            Text(track.folder).font(Theme.Font.xs).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Size.space1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help("\(track.clips.count) clips en \(track.id)")
        .accessibilityElement(children: .combine)
        .contextMenu {
            if model.outcome != nil, track.kind != .drone {
                Button(model.mutedTracks.contains(track.id) ? "Volver a escuchar esta pista" : "Silenciar esta pista") { model.toggleMute(track) }
                Button(model.soloTrack == track.id ? "Escuchar todas" : "Escuchar solo esta pista") { model.toggleSolo(track) }
                Divider()
            }
            if let first = track.clips.first {
                Button("Mostrar la carpeta en Finder") { NSWorkspace.shared.activateFileViewerSelecting([first.url]) }
                    .disabled(!first.exists)
            }
            if track.kind == .drone {
                Button("Quitar este dron") { model.removeTrack(track) }.disabled(model.busy)
            } else if model.isBuilt {
                Button("Quitar esta pista") { model.removeTrack(track) }.disabled(model.busy)
            }
        }
    }
}

struct ClipTooltip: View {
    @EnvironmentObject var model: AppModel
    let clip: ProjectClip

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(clip.name).font(Theme.Font.base.weight(.semibold))
            if let date = recordingStart(url: clip.url) {
                Text(date.formatted(date: .abbreviated, time: .standard)).font(Theme.Font.sm)
            }
            Text(formatLength(model.duration(clip))).font(Theme.Font.sm)
            if let p = model.placements[clip.fileID] {
                Text(methodText(p)).font(Theme.Font.sm)
                if let e = p.clockError { Text(String(format: "%+.2f s respecto de su hora", e)).font(Theme.Font.sm) }
            }
            if !clip.exists { Text("archivo no encontrado").font(Theme.Font.sm).foregroundStyle(Theme.danger) }
            if model.ignored.contains(clip.fileID) { Text("marcado como mal sincronizado").font(Theme.Font.sm).foregroundStyle(Theme.warning) }
        }
        .padding(Theme.Size.space2)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Size.radiusMd).fill(Theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: Theme.Size.radiusMd).stroke(Theme.border))
        .shadow(color: .black.opacity(0.45), radius: 12, y: 6)
    }
}

struct ZoomBar: View {
    let fit: () -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let pps: Double

    var body: some View {
        HStack(spacing: Theme.Size.space1) {
            PlayControls()
            Spacer()
            Text(pps >= 1 ? String(format: "%.0f px/s", pps) : String(format: "%.0f s por punto", 1 / pps))
                .font(Theme.Font.xs).foregroundStyle(Theme.textMuted).monospacedDigit()
            IconButton(systemImage: "minus.magnifyingglass", help: "Alejar (⌘−)", action: zoomOut)
                .keyboardShortcut("-")
            IconButton(systemImage: "plus.magnifyingglass", help: "Acercar (⌘+)", action: zoomIn)
                .keyboardShortcut("+")
            IconButton(systemImage: "arrow.left.and.right.square", help: "Ver todo (⌘0)", action: fit)
                .keyboardShortcut("0")
        }
        .padding(.horizontal, Theme.Size.space2)
        .frame(height: 28)
        .background(Theme.surface)
    }
}

/// The whole timeline in one strip; the bright part is what is on screen. Drag it to move.
struct Overview: View {
    @Binding var viewStart: Double
    let visible: Double
    let total: Double
    var playhead: Double? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(viewStart / total) * w
            let vw = max(8, CGFloat(min(1, visible / total)) * w)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.surface2)
                RoundedRectangle(cornerRadius: 3).fill(Theme.textMuted).frame(width: vw).offset(x: x)
                if let p = playhead {
                    Rectangle().fill(Theme.danger).frame(width: 2).offset(x: CGFloat(p / total) * w)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let center = Double(g.location.x / w) * total
                viewStart = min(max(0, total - visible), max(0, center - visible / 2))
            })
        }
    }
}

/// Time along the top, like an editor's: click or drag on it to put the playhead there.
struct Ruler: View {
    @EnvironmentObject var model: AppModel
    let viewStart: Double
    let pps: Double
    let width: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Theme.surface).frame(width: Theme.Size.trackHeaderW)
            Canvas { ctx, size in
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.surface))
                let step = [1.0, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200].first { $0 * pps >= 80 } ?? 7200
                var t = (viewStart / step).rounded(.down) * step
                while t <= viewStart + Double(size.width) / pps {
                    let x = CGFloat((t - viewStart) * pps)
                    ctx.fill(Path(CGRect(x: x, y: size.height - 7, width: 1, height: 7)), with: .color(Theme.textMuted))
                    let label = Text(rulerLabel(t)).font(Theme.Font.xs).foregroundColor(Theme.textMuted)
                    ctx.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                    t += step
                }
                if let p = model.playhead {
                    let x = CGFloat((p - viewStart) * pps)
                    var head = Path()
                    head.move(to: CGPoint(x: x - 6, y: 0)); head.addLine(to: CGPoint(x: x + 6, y: 0)); head.addLine(to: CGPoint(x: x, y: 9))
                    ctx.fill(head, with: .color(Theme.danger))
                    ctx.fill(Path(CGRect(x: x - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(Theme.danger))
                }
            }
            .frame(width: width)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    guard model.outcome != nil else { return }
                    if model.playing { model.pause() }
                    model.playhead = max(0, viewStart + Double(g.location.x) / pps)
                    model.showPicture(at: model.playhead!)
                }
                .onEnded { g in
                    guard model.outcome != nil else { return }
                    model.seek(viewStart + Double(g.location.x) / pps)
                })
            .help(model.outcome == nil ? "" : "Hacé clic o arrastrá para elegir desde dónde reproducir")
        }
        .frame(height: 22)
    }

    private func rulerLabel(_ t: Double) -> String {
        let s = Int(t.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
