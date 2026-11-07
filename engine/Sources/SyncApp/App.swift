import AppKit
import SwiftUI

@main
struct SyncoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        Window("Synco", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 860, minHeight: 560)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    Scripted.run(model, updater: updater)
                    // A few seconds after opening, quietly look for a new version (not in test runs,
                    // except the update test itself).
                    let env = ProcessInfo.processInfo.environment
                    if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) || env["SYNCO_UPDATE_AUTO"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { updater.check(quiet: true) }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Buscar actualizaciones…") { updater.check(quiet: false) }
            }
            CommandGroup(replacing: .help) {
                Button("Sitio de Synco") { Contact.open(Contact.site) }
                Button("Escribinos por Instagram (\(Contact.handle))") { Contact.open(Contact.instagramChat) }
                Button("Reportar un problema…") { Contact.sendReport() }
                Divider()
                Button("Donar") { Contact.open(Contact.donate) }
                Button("Código fuente") { Contact.open(Contact.source) }
            }
            CommandGroup(replacing: .newItem) {
                Button("Abrir proyecto o XML…") { model.chooseFile() }.keyboardShortcut("o")
                Button("Armar desde carpetas…") { model.chooseFolders() }.keyboardShortcut("o", modifiers: [.command, .shift])
                Menu("Abrir reciente") {
                    ForEach(model.prefs.recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { model.userOpen(URL(fileURLWithPath: path)) }
                    }
                    if !model.prefs.recents.isEmpty {
                        Divider()
                        Button("Vaciar lista") { model.prefs.recents = [] }
                    }
                }
                Button("Volver a cargar") { model.reload() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.fileURL == nil)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Guardar proyecto") { model.saveProject() }
                    .keyboardShortcut("s")
                    .disabled(!model.canSave)
                Button("Guardar proyecto como…") { model.saveProject(choosing: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(!model.canSave)
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Exportar XML sincronizado…") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.phase != .done)
            }
            CommandMenu("Sincronización") {
                Button("Sincronizar") { model.synchronize() }
                    .keyboardShortcut("r")
                    .disabled(!model.canSync)
                Button("Detener") { model.stopByUser() }
                    .keyboardShortcut(".")
                    .disabled(!model.busy)
                Divider()
                Button("Ajustes de sincronización…") { model.showSyncSettings = true }
                Button("Ajustes de exportación…") { model.showExportSettings = true }
                Button("Reubicar archivos faltantes…") { model.showPathFixer = true }
                    .disabled(model.project == nil)
                Divider()
                Button("Ver informe") { model.showReport = true }
                    .disabled(model.phase != .done)
                Button("Quitar todas las correcciones") { model.clearFixes() }
                    .disabled(model.ignored.isEmpty)
            }
        }

        Settings {
            GeneralSettings()
                .environmentObject(model)
                .environmentObject(updater)
                .preferredColorScheme(.dark)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as a regular app with a Dock icon even when launched from the command line.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // A smaller screen than the one it was last used on: the window fits on it, whole.
        DispatchQueue.main.async { Self.fitOnScreen(); Self.guardCloseButton() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            Self.fitOnScreen()
        }
    }

    static func fitOnScreen() {
        for window in NSApp.windows where window.isVisible && window.styleMask.contains(.resizable) {
            guard let screen = window.screen ?? NSScreen.main else { continue }
            let room = screen.visibleFrame
            var frame = window.frame
            frame.size.width = min(frame.width, room.width)
            frame.size.height = min(frame.height, room.height)
            frame.origin.x = min(max(frame.minX, room.minX), room.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, room.minY), room.maxY - frame.height)
            if frame != window.frame { window.setFrame(frame, display: true) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Quitting with a sync not saved: asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { model?.confirmLeaving() ?? true } ? .terminateNow : .terminateCancel
    }

    /// The window's close button asks too (closing it quits the app).
    @MainActor static func guardCloseButton() {
        for window in NSApp.windows where window.styleMask.contains(.closable) {
            guard let button = window.standardWindowButton(.closeButton), !(button.target is CloseGuard) else { continue }
            let guardian = CloseGuard(window: window)
            CloseGuard.kept.append(guardian)
            button.target = guardian
            button.action = #selector(CloseGuard.close)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Task { @MainActor in self.model?.userOpen(url) } }
    }
}

@MainActor
final class CloseGuard: NSObject {
    static var kept = [CloseGuard]()
    weak var window: NSWindow?
    init(window: NSWindow) { self.window = window }

    @objc func close() {
        guard let delegate = NSApp.delegate as? AppDelegate, delegate.model?.confirmLeaving() ?? true else { return }
        delegate.model?.dirty = false
        window?.close()
    }
}
