import SwiftUI
import SyncCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var updater: Updater
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            ActionBar()
            StatusBar()
            Divider().overlay(Theme.border)
            ZStack {
                if model.project == nil {
                    EmptyState(targeted: dropTargeted)
                } else {
                    TimelineView()
                }
            }
            if model.project != nil {
                ClipInspector()
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        .foregroundStyle(Theme.text)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.pathExtension.lowercased() == "xml" {
                    Task { @MainActor in model.open(url) }
                }
            }
            return true
        }
        .overlay {
            if updater.showCard { UpdateCard() }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: updater.showCard)
        .sheet(isPresented: $model.showSyncSettings) { SyncSettingsSheet() }
        .sheet(isPresented: $model.showExportSettings) { ExportSettingsSheet() }
        .sheet(isPresented: $model.showPathFixer) { PathFixerSheet() }
        .sheet(isPresented: $model.showReport) { ReportSheet() }
    }
}

// MARK: Header

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Size.space3) {
            BrandMark()
            Rectangle().fill(Theme.border).frame(width: 1, height: 18)
            if let url = model.fileURL, let project = model.project {
                Text(url.lastPathComponent).font(Theme.Font.lg).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.right").font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
                Text(project.sequenceName).font(Theme.Font.base).foregroundStyle(Theme.textMuted).lineLimit(1)
                Text(formatLength(model.totalDuration)).font(Theme.Font.base).foregroundStyle(Theme.textMuted)
                Text("\(project.fps) cps").font(Theme.Font.base).foregroundStyle(Theme.textMuted)
                PhaseBadge()
            } else {
                Text("sincroniza cámaras y grabadores por el audio").font(Theme.Font.base).foregroundStyle(Theme.textMuted)
            }
            Spacer()
        }
        .padding(.leading, 80) // room for the window buttons
        .overlay(alignment: .trailing) { SupportButtons().padding(.trailing, Theme.Size.space4) }
        .padding(.trailing, Theme.Size.space4)
        .frame(height: 38)
        .background(Theme.surface)
    }
}

struct PhaseBadge: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let (text, color): (String, Color) = {
            switch model.phase {
            case .empty: return ("", Theme.textMuted)
            case .reading: return ("leyendo audio", Theme.accent)
            case .ready: return ("sin sincronizar", Theme.textMuted)
            case .matching: return ("sincronizando", Theme.accent)
            case .done: return ("sincronizado", Theme.success)
            case .stopped: return ("detenido", Theme.warning)
            case .failed: return ("error", Theme.danger)
            }
        }()
        Text(text)
            .font(Theme.Font.xs)
            .padding(.horizontal, Theme.Size.space2)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .overlay(RoundedRectangle(cornerRadius: Theme.Size.radiusSm).stroke(color.opacity(0.6)))
    }
}

/// Donate and Instagram, top right.
struct SupportButtons: View {
    var body: some View {
        HStack(spacing: Theme.Size.space2) {
            Button { Contact.open(Contact.instagram) } label: {
                Label(Contact.handle, systemImage: "camera").font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)
            .help("Instagram: novedades, dudas y pedidos")
            Button { Contact.open(Contact.donate) } label: {
                Label("Donar", systemImage: "heart.fill")
                    .font(Theme.Font.sm.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .foregroundStyle(Theme.onAccent)
                    .background(Capsule().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .help(Contact.donateNote)
        }
    }
}

/// The S mark and the SYNCO wordmark, the user's own white artwork (brand/ in the engine).
struct BrandMark: View {
    private static func art(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png").flatMap(NSImage.init(contentsOf:))
    }
    private static let mark = art("mark")
    private static let wordmark = art("wordmark")

    var body: some View {
        HStack(spacing: 7) {
            if let mark = Self.mark, let wordmark = Self.wordmark {
                Image(nsImage: mark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 22)
                Image(nsImage: wordmark).resizable().interpolation(.high).aspectRatio(contentMode: .fit).frame(height: 14)
            } else {
                Text("SYNCO").font(Theme.Font.lg).foregroundStyle(Theme.brandWhite)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Synco")
    }
}

// MARK: Actions and counters

struct ActionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Size.space3) {
            HStack(spacing: Theme.Size.space1) {
                ActionButton(title: "Abrir XML", systemImage: "square.and.arrow.down", primary: model.project == nil) {
                    model.chooseFile()
                }
                .disabled(model.busy)
            }
            Chevron()
            Counter(value: model.cameras, label: "cámaras")
            Counter(value: model.recorders, label: "grabadores")
            Counter(value: model.clipCount, label: "clips")
            Chevron()
            HStack(spacing: Theme.Size.space1) {
                IconButton(systemImage: "gearshape", help: "Ajustes de sincronización") { model.showSyncSettings = true }
                if model.busy {
                    ActionButton(title: "Detener", systemImage: "stop.fill", primary: false) { model.stop() }
                } else {
                    ActionButton(title: "Sincronizar",
                                 systemImage: "waveform.path", primary: model.project != nil && model.phase != .done) {
                        model.synchronize()
                    }
                    .disabled(model.project == nil)
                }
            }
            Chevron()
            Counter(value: model.remainingCount, label: "sin sincronizar", large: true)
            Counter(value: model.syncedCount, label: "sincronizados", large: true, highlight: model.syncedCount > 0)
            Spacer()
            HStack(spacing: Theme.Size.space1) {
                IconButton(systemImage: "gearshape", help: "Ajustes de exportación") { model.showExportSettings = true }
                ActionButton(title: "Exportar", systemImage: "square.and.arrow.up", primary: model.phase == .done) {
                    model.export()
                }
                .disabled(model.phase != .done)
            }
        }
        .padding(.horizontal, Theme.Size.space4)
        .padding(.vertical, Theme.Size.space3)
        .background(Theme.surface)
    }
}

struct StatusBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Size.space3) {
            StatusLight(on: model.phase == .reading, label: "lectura")
            StatusLight(on: model.phase == .matching, label: "búsqueda")
            if model.phase == .reading, model.readTotal > 0 {
                ProgressView(value: Double(model.readDone), total: Double(model.readTotal))
                    .frame(width: 160)
                    .tint(Theme.accent)
                Text("\(model.readDone)/\(model.readTotal)").font(Theme.Font.sm).foregroundStyle(Theme.textMuted).monospacedDigit()
            } else if model.phase == .matching {
                ProgressView().controlSize(.small)
            }
            Text(model.message)
                .font(Theme.Font.sm)
                .foregroundStyle(model.phase.isFailure ? Theme.danger : Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if !model.missing.isEmpty {
                Button {
                    model.showPathFixer = true
                } label: {
                    Label("\(model.missing.count) archivo(s) no encontrados", systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.Font.sm)
                        .foregroundStyle(Theme.danger)
                }
                .buttonStyle(.plain)
            }
            if !model.ignored.isEmpty {
                Text("\(model.ignored.count) corrección(es) pendiente(s)").font(Theme.Font.sm).foregroundStyle(Theme.warning)
            }
            if model.phase == .done {
                Button("Ver informe") { model.showReport = true }
                    .buttonStyle(.link)
                    .font(Theme.Font.sm)
            }
        }
        .padding(.horizontal, Theme.Size.space4)
        .frame(height: 30)
        .background(Theme.surface)
    }
}

extension AppModel.Phase {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

// MARK: Empty state

struct EmptyState: View {
    @EnvironmentObject var model: AppModel
    let targeted: Bool

    var body: some View {
        VStack(spacing: Theme.Size.space4) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(targeted ? Theme.accent : Theme.textMuted)
            Text("Soltá acá el XML de tu línea de tiempo")
                .font(Theme.Font.lg)
            Text("En Premiere: Archivo › Exportar › Final Cut Pro XML. Una pista por cámara o grabador, con los clips sin ordenar.")
                .font(Theme.Font.base)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 460)
            ActionButton(title: "Elegir archivo…", systemImage: "folder", primary: true) { model.chooseFile() }
            let recents = model.prefs.recents.filter { FileManager.default.fileExists(atPath: $0) }
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Size.space1) {
                    Text("Recientes").font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
                    ForEach(recents, id: \.self) { path in
                        Button {
                            model.open(URL(fileURLWithPath: path))
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                Text((path as NSString).lastPathComponent)
                                Text((path as NSString).deletingLastPathComponent)
                                    .foregroundStyle(Theme.textMuted).lineLimit(1).truncationMode(.head)
                            }
                            .font(Theme.Font.base)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 460, alignment: .leading)
                .padding(.top, Theme.Size.space4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.trackBg)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Size.radiusMd)
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(Theme.Size.space4)
                .opacity(targeted ? 1 : 0)
        )
    }
}

// MARK: Inspector (correction tool)

struct ClipInspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: Theme.Size.space3) {
            if let id = model.selected, let clip = model.clip(id) {
                Image(systemName: clip.hasVideo ? "video" : "mic").foregroundStyle(Theme.textMuted)
                Text(clip.name).font(Theme.Font.lg)
                Text("\(clip.track) · \((clip.folder as NSString).lastPathComponent)").font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                Text(formatLength(model.duration(clip))).font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                if let p = model.placements[id] {
                    Text(methodText(p)).font(Theme.Font.sm).foregroundStyle(p.method.synced ? Theme.success : Theme.clipUnsynced)
                    if let starts = model.starts, let f = starts[id] {
                        Text("en \(formatTimecode(Double(f) / model.fps))").font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                    }
                }
                if !clip.exists {
                    Text("archivo no encontrado").font(Theme.Font.sm).foregroundStyle(Theme.danger)
                }
                Spacer()
                Button(model.ignored.contains(id) ? "Deshacer corrección" : "Está mal: ubicarlo por su hora") {
                    model.toggleIgnored(id)
                }
                .help("Deja de usar el audio de este clip y lo ubica por la hora del archivo. Se aplica al volver a sincronizar.")
                .disabled(model.busy)
                Button("Mostrar en Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.url]) }
                    .disabled(!clip.exists)
            } else {
                Text("Hacé clic en un clip para ver cómo se ubicó. Arrastrá para moverte; ⌘ + rueda o los botones para acercar.")
                    .font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                Spacer()
            }
        }
        .padding(.horizontal, Theme.Size.space4)
        .frame(height: 40)
        .background(Theme.surface)
    }
}

func methodText(_ p: Placement) -> String {
    switch p.method {
    case .reference: return "referencia (grabador principal)"
    case .audio: return String(format: "por audio · z %.1f", p.z)
    case .audioNear: return String(format: "por audio, cerca de su hora · z %.1f", p.z)
    case .clock: return "por la hora del archivo (sin audio en común)"
    case .unplaced: return "sin ubicar: al final"
    }
}

func formatLength(_ s: Double) -> String {
    let m = Int(s / 60)
    return m >= 60 ? "\(m / 60) h \(m % 60) min" : (m > 0 ? "\(m) min \(Int(s) % 60) s" : "\(Int(s)) s")
}

func formatTimecode(_ s: Double) -> String {
    String(format: "%02d:%02d:%05.2f", Int(s) / 3600, Int(s) / 60 % 60, s.truncatingRemainder(dividingBy: 60))
}
