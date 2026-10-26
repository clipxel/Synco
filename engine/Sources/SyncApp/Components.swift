import SwiftUI

struct ActionButton: View {
    let title: String
    let systemImage: String
    let primary: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(Theme.Font.lg)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 14)
                .frame(height: Theme.Size.buttonH)
                .foregroundStyle(primary ? Theme.onAccent : Theme.text)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Size.radiusMd)
                        .fill(primary ? Theme.accent : Theme.surface2)
                        .brightness(hover && enabled ? 0.08 : 0)
                )
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title)
    }
}

struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .frame(width: 28, height: 28)
                .foregroundStyle(hover ? Theme.text : Theme.textMuted)
                .background(RoundedRectangle(cornerRadius: Theme.Size.radiusSm).fill(hover ? Theme.surface2 : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct Counter: View {
    let value: Int
    let label: String
    var large = false
    var highlight = false
    /// The number's colour when it is not zero (the clip colours: blue, yellow, red).
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(large ? Theme.Font.counterLg : Theme.Font.counter)
                .foregroundStyle(value == 0 ? Theme.textMuted : (tint ?? (highlight ? Theme.success : Theme.text)))
                .monospacedDigit()
            Text(label).font(Theme.Font.xs).foregroundStyle(Theme.textMuted)
        }
        .frame(minWidth: large ? 84 : 56)
        .accessibilityElement(children: .combine)
    }
}

struct Chevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(Theme.Font.sm).foregroundStyle(Theme.border)
    }
}

struct StatusLight: View {
    let on: Bool
    let label: String

    var body: some View {
        HStack(spacing: Theme.Size.space1) {
            Circle()
                .fill(on ? Theme.accent : Theme.border)
                .frame(width: 8, height: 8)
                .shadow(color: on ? Theme.accent : .clear, radius: 4)
            Text(label).font(Theme.Font.xs).foregroundStyle(on ? Theme.text : Theme.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(on ? "activa" : "inactiva")
    }
}
