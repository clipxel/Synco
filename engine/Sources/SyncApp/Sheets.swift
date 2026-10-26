import AppKit
import SwiftUI
import SyncCore

/// Edits a copy and only keeps it on Aceptar; Esc or Cancelar leave everything as it was.
struct SheetFrame<Content: View>: View {
    let title: String
    let onSave: (() -> Void)?
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Size.space4) {
            Text(title).font(Theme.Font.lg)
            content
            HStack {
                Spacer()
                if let onSave {
                    Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Aceptar") { onSave(); dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cerrar") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(Theme.Size.space5)
        .frame(width: 520)
        .background(Theme.surface)
    }
}

struct SyncSettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = SyncPrefs()

    var body: some View {
        SheetFrame(title: "Ajustes de sincronización", onSave: { model.prefs.sync = draft }) {
            Form {
                Picker("Exigencia de coincidencia", selection: $draft.strictness) {
                    ForEach(Strictness.allCases) { Text($0.label).tag($0) }
                }
                Picker("Frecuencias que compara", selection: $draft.band) {
                    ForEach(Band.allCases) { Text($0.label).tag($0) }
                }
                Picker("Búsqueda cerca de la hora del archivo", selection: $draft.window) {
                    Text("±10 s (relojes bien puestos)").tag(10.0)
                    Text("±20 s").tag(20.0)
                    Text("±60 s (relojes desajustados)").tag(60.0)
                }
                Text("El grabador con más audio se usa de referencia. Cada clip se busca primero en todo el audio y después cerca de donde lo pone la hora de su archivo. Lo que no coincide con nada se ubica por su hora y queda marcado.")
                    .font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Volver a los valores por defecto") { draft = SyncPrefs() }
            }
        }
        .onAppear { draft = model.prefs.sync }
    }
}

/// Premiere's own label names, written in the XML as is.
let premiereLabels: [(String, String)] = [
    ("", "sin cambiar"), ("Violet", "violeta"), ("Iris", "lirio"), ("Caribbean", "caribe"), ("Lavender", "lavanda"),
    ("Cerulean", "celeste"), ("Forest", "verde bosque"), ("Rose", "rosa"), ("Mango", "mango"), ("Purple", "púrpura"),
    ("Blue", "azul"), ("Teal", "verde azulado"), ("Magenta", "magenta"), ("Tan", "beige"), ("Green", "verde"),
    ("Brown", "marrón"), ("Yellow", "amarillo"),
]

struct ExportSettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ExportOptions()

    var body: some View {
        SheetFrame(title: "Ajustes de exportación", onSave: { model.prefs.export = draft }) {
            Form {
                Section("Secuencia") {
                    TextField("Agregar al nombre", text: $draft.sequenceSuffix)
                    Toggle("Guardar un informe (.md) junto al XML", isOn: $draft.writeReport)
                }
                Section("Exactos: encontrados por su audio") {
                    Picker("Etiqueta de color", selection: $draft.syncedLabel) {
                        ForEach(premiereLabels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Section("Aproximados: por audio, buscando cerca de su fecha y sus vecinos") {
                    Picker("Etiqueta de color", selection: $draft.approxLabel) {
                        ForEach(premiereLabels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }
                Section("No encontrados: ubicados por fecha, hora y vecinos") {
                    Picker("Etiqueta de color", selection: $draft.unsyncedLabel) {
                        ForEach(premiereLabels, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    Toggle("Deshabilitarlos en la línea de tiempo", isOn: $draft.disableUnsynced)
                    Text("Apagado (lo normal): quedan habilitados, marcados solo con su color.")
                        .font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
                }
            }
        }
        .onAppear { draft = model.prefs.export }
    }
}

struct PathFixerSheet: View {
    @EnvironmentObject var model: AppModel
    @State private var note = ""

    var body: some View {
        SheetFrame(title: "Archivos no encontrados", onSave: nil) {
            if model.missing.isEmpty {
                Label("Todos los archivos del proyecto están en su lugar.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.success)
            } else {
                Text("Elegí la carpeta donde están ahora: se buscan por nombre en ella y en sus subcarpetas, y se corrigen todos los que aparezcan.")
                    .font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                List(model.missing, id: \.fileID) { clip in
                    VStack(alignment: .leading) {
                        Text(clip.name).font(Theme.Font.base)
                        Text(clip.url.deletingLastPathComponent().path).font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
                            .lineLimit(1).truncationMode(.head)
                    }
                }
                .frame(height: 220)
                HStack {
                    Button("Buscar en una carpeta…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            let n = model.relink(searching: url)
                            note = n == 0 ? "No apareció ninguno en esa carpeta." : "Se encontraron \(n)."
                        }
                    }
                    Text(note).font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                }
                Text("Los faltantes igual se pueden sincronizar: quedan al final, marcados.")
                    .font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
            }
        }
    }
}

struct ReportSheet: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SheetFrame(title: "Informe de la sincronización", onSave: nil) {
            ScrollView {
                Text(model.report)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 420)
            Button("Copiar") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.report, forType: .string)
            }
        }
        .frame(width: 760)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var size: Int64 = 0

    var body: some View {
        Form {
            Section("Synco \(Contact.version)") {
                Text(Contact.donateNote).font(Theme.Font.sm).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Donar") { Contact.open(Contact.donate) }
                    Button("Instagram \(Contact.handle)") { Contact.open(Contact.instagram) }
                    Button("Reportar un problema…") { Contact.sendReport() }
                }
            }
            Section("Al terminar") {
                Toggle("Hacer un sonido cuando termina la sincronización", isOn: $model.prefs.soundWhenDone)
            }
            Section("Audio guardado") {
                Text("El audio leído se guarda para que volver a sincronizar tarde segundos. Ocupa \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).")
                    .font(Theme.Font.sm)
                    .fixedSize(horizontal: false, vertical: true)
                Stepper("Borrar lo que no se use en \(model.prefs.cacheDays) días", value: $model.prefs.cacheDays, in: 7...365, step: 7)
                HStack {
                    Button("Borrar lo viejo ahora") {
                        AppModel.clearCache(olderThan: model.prefs.cacheDays)
                        size = AppModel.cacheSize()
                    }
                    Button("Borrar todo") {
                        AppModel.clearCache(olderThan: nil)
                        size = AppModel.cacheSize()
                    }
                    Button("Mostrar en Finder") { NSWorkspace.shared.open(defaultCacheDir) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 400)
        .onAppear {
            AppModel.clearCache(olderThan: model.prefs.cacheDays)
            size = AppModel.cacheSize()
        }
    }
}
