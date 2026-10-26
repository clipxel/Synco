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
                .frame(minWidth: 1100, minHeight: 640)
                .preferredColorScheme(.dark)
                .onAppear {
                    delegate.model = model
                    Scripted.run(model)
                    // A few seconds after opening, quietly look for a new version (not in test runs,
                    // except the update test itself).
                    let env = ProcessInfo.processInfo.environment
                    if !CommandLine.arguments.contains(where: { $0.hasPrefix("--") }) || env["SYNCO_UPDATE_AUTO"] != nil {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { updater.check(quiet: true) }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
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
                Button("Abrir XML…") { model.chooseFile() }.keyboardShortcut("o")
                Menu("Abrir reciente") {
                    ForEach(model.prefs.recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) { model.open(URL(fileURLWithPath: path)) }
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
            CommandGroup(after: .newItem) {
                Divider()
                Button("Exportar XML sincronizado…") { model.export() }
                    .keyboardShortcut("e")
                    .disabled(model.phase != .done)
            }
            CommandMenu("Sincronización") {
                Button("Sincronizar") { model.synchronize() }
                    .keyboardShortcut("r")
                    .disabled(model.project == nil || model.busy)
                Button("Detener") { model.stop() }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let url = urls.first { Task { @MainActor in self.model?.open(url) } }
    }
}
