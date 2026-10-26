import AppKit
import SwiftUI

/// Synco's own update card, over the window: what's new, then real progress while it
/// downloads, verifies and installs; also "up to date" and "couldn't update".
struct UpdateCard: View {
    @EnvironmentObject var updater: Updater

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { updater.dismiss() }
            card
                .frame(width: 460)
                .background(
                    RoundedRectangle(cornerRadius: 20).fill(Theme.surface)
                )
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.border, lineWidth: 1))
                // The brand's plate: a solid base under the card, in lime.
                .background(
                    RoundedRectangle(cornerRadius: 20).fill(Theme.accent).offset(y: 6)
                )
                .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .onExitCommand { updater.dismiss() }
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Size.space4) {
            switch updater.state {
            case .upToDate: upToDate
            case .failed(let why): failed(why)
            default: available
            }
        }
        .padding(Theme.Size.space5)
    }

    // MARK: Header

    private func header(_ title: String, _ subtitle: String) -> some View {
        HStack(spacing: Theme.Size.space3) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 19, weight: .bold)).foregroundStyle(Theme.brandWhite)
                Text(subtitle).font(Theme.Font.base).foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: New version

    @ViewBuilder private var available: some View {
        let info = updater.info
        header("Hay una versión nueva", "Synco \(info?.version ?? "") ya está lista para instalar.")
        HStack(spacing: Theme.Size.space2) {
            VersionChip(text: Contact.version, current: false)
            Image(systemName: "arrow.right").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.textMuted)
            VersionChip(text: info?.version ?? "", current: true)
        }
        if let notes = info?.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: Theme.Size.space2) {
                Text("NOVEDADES").font(.system(size: 11, weight: .semibold)).kerning(1.2).foregroundStyle(Theme.accent)
                let lines = noteLines(notes)
                let list = VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if line.bullet {
                                    Circle().fill(Theme.accent).frame(width: 5, height: 5).offset(y: -2)
                                }
                                Text(line.text).font(Theme.Font.base).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                // As tall as the text; long notes scroll.
                if lines.count > 7 {
                    ScrollView { list }.frame(height: 170)
                } else {
                    list
                }
            }
            .padding(Theme.Size.space3)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
        }
        if updater.state == .downloading || updater.state == .ready {
            progress
        } else {
            Text("Se descarga, se verifica y se instala sola en unos segundos. No hace falta reinstalar nada.")
                .font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                ActionButton(title: "Más tarde", systemImage: "clock", primary: false) { updater.dismiss() }
                    .keyboardShortcut(.cancelAction)
                ActionButton(title: "Actualizar ahora", systemImage: "arrow.down.circle.fill", primary: true) { updater.download() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: Theme.Size.space2) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(Theme.accent)
                        .frame(width: max(10, geo.size.width * CGFloat(updater.progress)))
                        .animation(.easeOut(duration: 0.25), value: updater.progress)
                }
            }
            .frame(height: 10)
            HStack {
                Text(stepText).font(Theme.Font.sm.weight(.semibold)).foregroundStyle(Theme.text)
                Spacer()
                if updater.step == .downloading {
                    Text("\(Int(updater.progress * 100)) %").font(Theme.Font.sm).monospacedDigit().foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.top, Theme.Size.space1)
    }

    private var stepText: String {
        switch updater.step {
        case .downloading: return "Descargando…"
        case .verifying: return "Verificando que sea la versión publicada…"
        case .installing: return "Instalando. Synco se vuelve a abrir sola."
        }
    }

    // MARK: Up to date

    @ViewBuilder private var upToDate: some View {
        header("Synco está al día", "Tenés la última versión.")
        HStack(spacing: Theme.Size.space2) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
            Text("Versión \(Contact.version)").font(Theme.Font.base).foregroundStyle(Theme.text)
        }
        .padding(Theme.Size.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
        HStack {
            Spacer()
            ActionButton(title: "Listo", systemImage: "checkmark", primary: true) { updater.dismiss() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Failed

    @ViewBuilder private func failed(_ why: String) -> some View {
        header("No se pudo actualizar", "Tu versión sigue intacta.")
        Label(why, systemImage: "exclamationmark.triangle.fill")
            .font(Theme.Font.base).foregroundStyle(Theme.text)
            .symbolRenderingMode(.multicolor)
            .padding(Theme.Size.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
        Text("Podés reintentar o bajar la versión nueva desde la página.")
            .font(Theme.Font.sm).foregroundStyle(Theme.textMuted)
        HStack {
            Button("Cerrar") { updater.dismiss() }
                .buttonStyle(.plain).font(Theme.Font.base).foregroundStyle(Theme.textMuted)
                .keyboardShortcut(.cancelAction)
            Spacer()
            ActionButton(title: "Ir a la página", systemImage: "safari", primary: false) { Contact.open(Contact.site) }
            ActionButton(title: "Reintentar", systemImage: "arrow.clockwise", primary: true) { updater.download() }
                .keyboardShortcut(.defaultAction)
        }
    }

    // MARK: Notes

    private struct NoteLine { let text: AttributedString; let bullet: Bool }

    /// Release notes are Markdown: "- item" lines become bullets, **bold** stays bold.
    private func noteLines(_ notes: String) -> [NoteLine] {
        notes.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            let bullet = line.hasPrefix("- ") || line.hasPrefix("* ")
            if bullet { line = String(line.dropFirst(2)) }
            let text = (try? AttributedString(markdown: line)) ?? AttributedString(line)
            return NoteLine(text: text, bullet: bullet)
        }
    }
}

private struct VersionChip: View {
    let text: String
    let current: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(current ? Theme.onAccent : Theme.textMuted)
            .background(Capsule().fill(current ? Theme.accent : Theme.surface2))
    }
}
