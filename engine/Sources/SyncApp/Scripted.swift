import AppKit
import SwiftUI

/// Command-line driving, for testing without clicking:
///   Synco --open a.xml [--sync] [--export b.xml] [--select N] [--snapshot shot.png] [--quit]
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
            let t0 = Date()
            if let path = value("--open") {
                model.open(URL(fileURLWithPath: path))
                print("synco: abriendo, fase \(model.phase)")
                await waitWhile { model.phase == .reading }
                print(String(format: "synco: abierto y audio leído en %.1f s", Date().timeIntervalSince(t0)))
                print("synco: fase \(model.phase) · faltantes \(model.missing.count) · \(model.message)")
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
            if let n = value("--select").flatMap(Int.init), let clip = model.tracks.first?.clips.dropFirst(n).first {
                model.selected = clip.fileID
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
            model.prefs = saved
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
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("synco: captura \(url.path)")
    }
}
