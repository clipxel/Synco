import AppKit
import AVFoundation
import SwiftUI
import SyncCore

/// What the user fixes by hand once synced, and listening to the result.
extension AppModel {
    /// Clips can be taken out, moved and nudged while nothing runs.
    var canEdit: Bool { project != nil && !busy }

    // MARK: Take out, move

    /// Takes a clip out of the project (the file stays where it is). Synced clips stay put.
    func removeClip(_ id: String) {
        guard canEdit, let session, let clip = clip(id) else { return }
        pause()
        session.removeClip(id, from: &outcome)
        if project?.clips.isEmpty == true { close(); return }
        if let o = outcome {
            placements = Dictionary(uniqueKeysWithValues: o.placements.map { ($0.id, $0) })
            starts = o.starts
        }
        peaks[id] = nil
        ignored.remove(id)
        if selected == id { selected = nil }
        buildTracks()
        saveBuilt()
        message = "Quitado del proyecto: \(clip.name). El archivo sigue en su carpeta; soltalo de nuevo para volver a sumarlo."
    }

    /// Moves a clip onto another track: from then on it is that camera's or recorder's.
    /// Where it sits on the timeline does not change.
    func moveClip(_ id: String, to track: TrackRow) {
        guard canEdit, let session, let clip = clip(id), let target = track.clips.first,
              track.kind != .drone, !droneClips.contains(where: { $0.fileID == id }) else { return }
        do {
            try session.project.move(id, like: target.fileID)
        } catch {
            message = "\(error)"
            return
        }
        buildTracks()
        saveBuilt()
        message = "\(clip.name) pasó a la pista de \(target.name). "
            + "Sigue en el mismo lugar; al volver a sincronizar cuenta como de esa pista."
    }

    /// The tracks a clip can move to: others of its kind (a clip with picture only where there is picture).
    func moveTargets(_ clip: ProjectClip) -> [TrackRow] {
        guard !droneClips.contains(where: { $0 === clip }) else { return [] }
        return tracks.filter { t in
            t.kind != .drone && !t.clips.contains { $0 === clip } && (clip.hasVideo ? t.kind == .camera : true)
        }
    }

    /// A project built from folders is Synco's own file: saved again as it is now, so it opens so.
    private func saveBuilt() {
        guard isBuilt, let project, let url = fileURL, let sources = ProjectBuilder.sources(of: project) else { return }
        let name = project.sequenceName
        Task.detached(priority: .utility) { _ = try? ProjectBuilder.build(sources, name: name, to: url) }
    }

    // MARK: Nudge

    /// Moves a synced clip `frames` later (earlier when negative), by hand.
    func nudge(_ id: String, by frames: Int) {
        guard !busy, var o = outcome, o.starts[id] != nil, let clip = clip(id) else { return }
        o.nudge(id, by: frames)
        outcome = o
        starts = o.starts
        let total = o.manual[id] ?? 0
        message = total == 0 ? "\(clip.name): de nuevo donde lo puso Synco."
            : "\(clip.name): corrido a mano \(total > 0 ? "+" : "")\(total) cuadro(s). Escuchalo con la barra espaciadora."
        if playing { play() }
    }

    /// Back to where the sync put it.
    func resetNudge(_ id: String) {
        guard let f = outcome?.manual[id] else { return }
        nudge(id, by: -f)
    }

    func manualFrames(_ id: String) -> Int { outcome?.manual[id] ?? 0 }

    // MARK: Listen

    /// Plays the synced result from the playhead: every clip's sound where it was put (two a
    /// little off sound like an echo), and a camera's picture.
    func togglePlay() { playing ? pause() : play() }

    func play() {
        guard let session, let outcome, !busy else {
            message = "Para reproducir, primero sincronizá."
            return
        }
        let from = playhead ?? selected.flatMap { outcome.starts[$0] }.map { Double($0) / fps } ?? 0
        playhead = min(max(0, from), totalDuration)
        playing = true
        playback.start(session: session, outcome: outcome, from: playhead!, muted: mutedClips) { [weak self] t in
            guard let self else { return }
            if let t { self.playhead = t; self.showPicture(at: t) } else { self.pause() }
        }
    }

    func pause() {
        guard playing else { return }
        playing = false
        playback.stop()
        videoPlayer.pause()
    }

    /// Where to listen from: a click on the timeline.
    func seek(_ t: Double) {
        playhead = max(0, t)
        if playing { play() } else { showPicture(at: playhead!) }
    }

    /// The clips of the tracks switched off.
    var mutedClips: Set<String> {
        Set(tracks.filter { mutedTracks.contains($0.id) || (soloTrack != nil && soloTrack != $0.id) }.flatMap { $0.clips.map(\.fileID) })
    }

    func toggleMute(_ track: TrackRow) {
        if mutedTracks.contains(track.id) { mutedTracks.remove(track.id) } else { mutedTracks.insert(track.id) }
        if playing { play() }
    }

    func toggleSolo(_ track: TrackRow) {
        soloTrack = soloTrack == track.id ? nil : track.id
        if playing { play() }
    }

    /// The picture at timeline second `t`: the selected clip's track if it has picture and
    /// something there, else the first track with picture that does.
    func showPicture(at t: Double) {
        let withPicture = tracks.filter { $0.kind != .recorder }
        let preferred = selected.flatMap { id in withPicture.first { $0.clips.contains { $0.fileID == id } } }
        let found = ([preferred].compactMap { $0 } + withPicture).lazy.compactMap { track -> (ProjectClip, Double)? in
            track.clips.first { c in
                let s = self.start(c, in: track)
                return c.hasVideo && c.exists && t >= s && t < s + self.duration(c)
            }.map { ($0, t - self.start($0, in: track)) }
        }.first
        guard let (clip, offset) = found else {
            if pictureClip != nil { videoPlayer.replaceCurrentItem(with: nil); pictureClip = nil }
            return
        }
        if pictureClip != clip.fileID {
            pictureClip = clip.fileID
            videoPlayer.replaceCurrentItem(with: AVPlayerItem(url: readableURL(clip.url)))
            videoPlayer.isMuted = true
        }
        let now = videoPlayer.currentTime().seconds
        // Picture follows the sound: put back only when it drifts, so it plays smoothly.
        if !playing || !now.isFinite || abs(now - offset) > 0.12 {
            videoPlayer.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if playing && videoPlayer.rate == 0 { videoPlayer.play() } else if !playing { videoPlayer.pause() }
    }
}

/// The sound of the synced timeline, made by the engine a stretch at a time (each clip decoded
/// where it plays), played one stretch after the other.
@MainActor
final class Playback {
    private let chunk = 15.0
    private let rate = 24000.0
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var token = UUID()
    private var from = 0.0
    private var next: (from: Double, data: Data)?
    private var preparing = false

    func start(session: SyncSession, outcome: SyncOutcome, from: Double, muted: Set<String>, tick: @escaping (Double?) -> Void) {
        stop()
        let token = UUID()
        self.token = token
        let end = outcome.starts.compactMap { id, f in
            (session.project.clips.first { $0.fileID == id }?.frames).map { Double(f + $0) / session.project.fps }
        }.max() ?? 0
        func render(_ at: Double, _ done: @escaping (Data) -> Void) {
            let length = chunk, rate = rate
            Task.detached(priority: .userInitiated) {
                let data = wavData(session.preview(outcome, from: at, length: length, muted: muted, rate: rate), rate: rate)
                await MainActor.run { done(data) }
            }
        }
        func begin(_ at: Double, _ data: Data) {
            guard self.token == token else { return }
            self.from = at
            player = try? AVAudioPlayer(data: data)
            player?.play()
            next = nil
            preparing = false
        }
        render(from) { begin(from, $0) }
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.token == token, let player = self.player else { return }
                let t = self.from + player.currentTime
                if t >= end { tick(nil); return }
                // The next stretch, made while this one plays.
                if player.duration - player.currentTime < 6, self.next == nil, !self.preparing {
                    self.preparing = true
                    let at = self.from + self.chunk
                    render(at) { data in if self.token == token { self.next = (at, data) } }
                }
                if !player.isPlaying {
                    if let n = self.next { begin(n.from, n.data) } else { return }
                }
                tick(self.from + (self.player?.currentTime ?? 0))
            }
        }
    }

    func stop() {
        token = UUID()
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        next = nil
        preparing = false
    }
}

/// A camera's picture, no controls: the timeline drives it.
struct PictureView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Right click on a clip: what can be done with it.
struct ClipMenu: View {
    @EnvironmentObject var model: AppModel
    let clip: ProjectClip
    /// The timeline second under the pointer.
    let at: Double?

    var body: some View {
        let id = clip.fileID
        let synced = model.outcome?.starts[id] != nil
        let isDrone = model.droneClips.contains { $0 === clip }
        if synced {
            Button("Reproducir desde acá") { model.selected = id; model.seek(at ?? 0); model.play() }
                .disabled(model.busy)
            Menu("Correr a mano") {
                Button("1 cuadro antes") { model.nudge(id, by: -1) }
                Button("1 cuadro después") { model.nudge(id, by: 1) }
                Button("10 cuadros antes") { model.nudge(id, by: -10) }
                Button("10 cuadros después") { model.nudge(id, by: 10) }
            }
            .disabled(model.busy)
            if model.manualFrames(id) != 0 {
                Button("Volver a donde lo puso Synco") { model.resetNudge(id) }.disabled(model.busy)
            }
        }
        let targets = model.moveTargets(clip)
        if !targets.isEmpty {
            Menu("Mover a la pista") {
                ForEach(targets) { t in Button(t.name) { model.moveClip(id, to: t) } }
            }
            .disabled(!model.canEdit)
        }
        if !isDrone {
            Button(model.ignored.contains(id) ? "Deshacer: volver a usar su audio" : "Está mal: ubicarlo por su hora") {
                model.toggleIgnored(id)
            }
            .disabled(model.busy)
        }
        Divider()
        Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
            .disabled(!clip.exists)
        Button("Abrir el archivo") { NSWorkspace.shared.open(clip.url) }
            .disabled(!clip.exists)
        Button("Copiar la ruta del archivo") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(clip.url.path, forType: .string)
        }
        Divider()
        Button("Quitar del proyecto", role: .destructive) { model.removeClip(id) }
            .disabled(!model.canEdit)
    }
}

/// Play and pause (space bar), and where the playhead is.
struct PlayControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.outcome != nil {
            HStack(spacing: Theme.Size.space1) {
                IconButton(systemImage: model.playing ? "pause.fill" : "play.fill",
                           help: model.playing ? "Pausa (espacio)" : "Reproducir lo sincronizado (espacio): si dos clips no están bien, se escucha como un eco") {
                    model.togglePlay()
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.busy)
                if let t = model.playhead {
                    Text(formatTimecode(t)).font(Theme.Font.xs).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            }
        }
    }
}
