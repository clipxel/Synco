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

    var body: some View {
        GeometryReader { geo in
            let laneW = max(1, geo.size.width - Theme.Size.trackHeaderW)
            let total = max(model.totalDuration, 1)
            let pps = zoom ?? Double(laneW) / total
            let lanesH = geo.size.height - Theme.Size.overviewH - 28
            let rowH = max(Theme.Size.trackMinH, lanesH / CGFloat(max(model.tracks.count, 1)))
            VStack(spacing: 0) {
                ZoomBar(fit: { zoom = nil; viewStart = 0 },
                        zoomIn: { setZoom(pps * 2, laneW: laneW, total: total) },
                        zoomOut: { setZoom(pps / 2, laneW: laneW, total: total) },
                        pps: pps)
                ScrollView(.vertical) {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.tracks) { t in TrackHeader(track: t).frame(height: rowH) }
                        }
                        .frame(width: Theme.Size.trackHeaderW)
                        lanes(width: laneW, rowH: rowH, pps: pps)
                    }
                }
                Overview(viewStart: $viewStart, visible: Double(laneW) / pps, total: total)
                    .frame(height: Theme.Size.overviewH)
                    .padding(.leading, Theme.Size.trackHeaderW)
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
                    guard let from = dragFrom, zoom != nil else { return }
                    viewStart = max(0, from.start - Double(g.location.x - from.x) / pps)
                }
                .onEnded { g in
                    if abs(g.translation.width) < 3 {
                        model.selected = clipAt(g.location, rowH: rowH, pps: pps)?.fileID
                    }
                    dragFrom = nil
                }
        )
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
            return p.method.synced ? Theme.clipSynced : Theme.clipUnsynced
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
            ctx.fill(wave, with: .color(Theme.onClip.opacity(0.55)))
        }

        if hovered || selected {
            ctx.stroke(shape, with: .color(Theme.accent), lineWidth: selected ? 2 : 1)
        } else {
            ctx.stroke(shape, with: .color(Theme.trackBg.opacity(0.8)), lineWidth: 1)
        }
        if rect.width > 70 {
            let label = Text(clip.name).font(Theme.Font.xs).foregroundColor(Theme.onClip)
            let resolved = ctx.resolve(label)
            let size = resolved.measure(in: rect.size)
            if size.width + 8 < rect.width {
                let cx = min(max(rect.midX, size.width / 2 + 6), visible - size.width / 2 - 6)
                let x = min(max(cx, rect.minX + size.width / 2 + 4), rect.maxX - size.width / 2 - 4)
                ctx.draw(resolved, at: CGPoint(x: x, y: rect.minY + 10))
            }
        }
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

struct TrackHeader: View {
    let track: TrackRow

    var body: some View {
        VStack(spacing: Theme.Size.space1) {
            Image(systemName: track.kind == .camera ? "video.fill" : "mic.fill")
                .font(.system(size: 16))
            Text(track.name).font(Theme.Font.xs)
            Text(track.folder).font(Theme.Font.xs).foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, Theme.Size.space1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
        .help("\(track.clips.count) clips en \(track.id)")
        .accessibilityElement(children: .combine)
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

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(viewStart / total) * w
            let vw = max(8, CGFloat(min(1, visible / total)) * w)
            ZStack(alignment: .leading) {
                Rectangle().fill(Theme.surface2)
                RoundedRectangle(cornerRadius: 3).fill(Theme.textMuted).frame(width: vw).offset(x: x)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let center = Double(g.location.x / w) * total
                viewStart = min(max(0, total - visible), max(0, center - visible / 2))
            })
        }
    }
}
