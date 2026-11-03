import AppKit
import SwiftUI
import SyncCore

/// Command-line driving, for testing without clicking:
///   Synco --open a.xml [--sync] [--drone folder] [--export b.xml] [--select N] [--snapshot shot.png] [--quit]
///   Synco --folders cam1 cam2 audio [--drop-on N clip...] [--sync] ...   (like dropping them on the timeline:
///   below the tracks, each folder a new track; on track N, into it)
/// The snapshot is the app's own window drawn to a PNG (no screen recording involved).
@MainActor
enum Scripted {
    static func run(_ model: AppModel, updater: Updater) {
        let args = CommandLine.arguments
        func value(_ flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        guard args.contains(where: { $0.hasPrefix("--") && $0 != "--" }) else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        // A scripted run is usually in the background: keep App Nap from stretching the waits.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Prueba por línea de comandos")
        Task { @MainActor in
            defer { ProcessInfo.processInfo.endActivity(activity) }
            // Test runs leave the user's settings and recent files as they were.
            let saved = model.prefs
            if args.contains("--disable-unsynced") { model.prefs.export.disableUnsynced = true }
            try? await Task.sleep(nanoseconds: 500_000_000)
            // --window 900x600: the window at that size, as on a small screen.
            if let size = value("--window")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2,
               let w = NSApp.windows.first(where: { $0.isVisible }) {
                w.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            let t0 = Date()
            if let path = value("--open") {
                model.open(URL(fileURLWithPath: path))
                print("synco: abriendo, fase \(model.phase)")
                // --sync-early: Sincronizar pressed while it still opens and reads, as a hurried user does.
                if args.contains("--sync-early") {
                    model.synchronize()
                    print("synco: sincronizar apretado al abrir, espera la lectura: \(model.syncWhenRead)")
                    await waitWhile { model.busy }
                    print("synco: fase \(model.phase) · \(model.message)")
                }
                await waitWhile { model.phase == .reading }
                print(String(format: "synco: abierto y audio leído en %.1f s", Date().timeIntervalSince(t0)))
                print("synco: fase \(model.phase) · faltantes \(model.missing.count) · \(model.message)")
            }
            var built: URL?
            if let i = args.firstIndex(of: "--folders") {
                let folders = args[(i + 1)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
                model.drop(folders, onto: nil)
                await waitWhile { model.phase == .reading }
                if let j = args.firstIndex(of: "--drop-on"), j + 1 < args.count, let n = Int(args[j + 1]), n < model.tracks.count {
                    let more = args[(j + 2)...].prefix { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
                    print("synco: soltando \(more.count) en \(model.tracks[n].name)")
                    model.drop(more, onto: model.tracks[n])
                    await waitWhile { model.phase == .reading }
                }
                do {
                    built = model.fileURL
                    print(String(format: "synco: armado y audio leído en %.1f s", Date().timeIntervalSince(t0)))
                    print("synco: fase \(model.phase) · \(model.cameras) cámaras · \(model.recorders) grabadores · \(model.clipCount) clips")
                    for t in model.tracks { print("synco:   \(t.name) · \(t.folder) · \(t.clips.count) clips") }
                    print("synco: \(model.message)")
                }
            }
            if let n = value("--ignore").flatMap(Int.init), let clip = model.tracks.first?.clips.dropFirst(n).first {
                model.toggleIgnored(clip.fileID)
                print("synco: marcado como mal \(clip.name)")
            }
            if args.contains("--sync") {
                model.synchronize()
                print("synco: sincronizando, fase \(model.phase)")
                if let s = value("--stop-after").flatMap(Double.init) {
                    try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                    model.stop()
                }
                await waitWhile { model.busy }
                print("synco: fase \(model.phase)")
                for id in model.ignored { print("synco: corregido \(model.clip(id)?.name ?? id) → \(model.placements[id]?.method.rawValue ?? "-")") }
                print("synco: \(model.message)")
                print(String(format: "synco: hasta acá %.1f s", Date().timeIntervalSince(t0)))
            }
            // The extra step: --drone <folder> adds it as "Agregar dron" does.
            if let path = value("--drone") {
                model.addDrones([[URL(fileURLWithPath: path)]])
                await waitWhile { model.busy }
                print("synco: \(model.message)")
                for t in model.tracks where t.kind == .drone {
                    for c in t.clips { print("synco:   \(c.name) → \(model.placements[c.fileID].map(methodText) ?? "-")") }
                }
            }
            if let n = value("--select").flatMap(Int.init), let clip = model.tracks.first?.clips.dropFirst(n).first {
                model.selected = clip.fileID
            }
            // By hand: --nudge <frames> the selected clip, --move-to <track> it, --remove it.
            if let id = model.selected, let f = value("--nudge").flatMap(Int.init) {
                model.nudge(id, by: f)
                print("synco: \(model.message)")
            }
            if let id = model.selected, let n = value("--move-to").flatMap(Int.init), n < model.tracks.count {
                model.moveClip(id, to: model.tracks[n])
                print("synco: \(model.message)")
            }
            if let id = model.selected, args.contains("--remove") {
                model.removeClip(id)
                print("synco: \(model.message) · quedan \(model.clipCount) clips")
            }
            // --play <seconds>: plays from the selected clip, and says where it got to.
            if let s = value("--play").flatMap(Double.init) {
                model.play()
                let from = model.playhead ?? 0
                try? await Task.sleep(nanoseconds: UInt64(s * 1e9))
                print(String(format: "synco: reproduciendo desde %.2f s, va por %.2f s, imagen de %@", from, model.playhead ?? -1,
                             model.pictureClip.flatMap { model.clip($0)?.name } ?? "ninguna"))
                print(String(format: "synco: imagen en %.2f s del archivo, estado %d, velocidad %.1f", model.videoPlayer.currentTime().seconds,
                             model.videoPlayer.currentItem?.status.rawValue ?? -1, model.videoPlayer.rate))
            }
            if let path = value("--export") {
                model.export(to: URL(fileURLWithPath: path))
                print("synco: \(model.message)")
            }
            // Update card: --check-update shows it (manifest from SYNCO_UPDATE_MANIFEST);
            // --update-download then presses "Actualizar ahora".
            if args.contains("--check-update") {
                updater.check(quiet: false)
                await waitWhile { updater.state == .checking }
                if args.contains("--update-download") {
                    updater.download()
                    await waitWhile { updater.state == .downloading }
                }
                if let p = value("--update-progress").flatMap(Double.init) { updater.preview(step: .downloading, progress: p) }
                print("synco: actualización \(updater.state)")
            }
            if let path = value("--snapshot") {
                try? await Task.sleep(nanoseconds: 800_000_000)
                snapshot(to: URL(fileURLWithPath: path))
            }
            model.pause()
            model.prefs = saved
            // A test run's project is not kept among the user's.
            if let built, built.deletingLastPathComponent().standardizedFileURL.path == ProjectBuilder.projectsDir.standardizedFileURL.path {
                try? FileManager.default.removeItem(at: built)
            }
            if args.contains("--quit") {
                // An open sheet (missing files, settings) would keep the app from quitting.
                model.showPathFixer = false
                model.showSyncSettings = false
                model.showExportSettings = false
                model.showReport = false
                try? await Task.sleep(nanoseconds: 300_000_000)
                NSApp.terminate(nil)
            }
        }
    }

    static func waitWhile(_ condition: @escaping () -> Bool) async {
        while condition() { try? await Task.sleep(nanoseconds: 200_000_000) }
    }

    static func snapshot(to url: URL) {
        guard let main = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = (main.attachedSheet ?? main).contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("synco: captura \(url.path)")
    }
}
