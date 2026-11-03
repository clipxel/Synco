import SwiftUI

/// How much room the window gives: the bars put away words before anything gets cut.
enum Room: Int, Comparable {
    case tight, compact, roomy
    static func < (a: Room, b: Room) -> Bool { a.rawValue < b.rawValue }
    init(width: CGFloat) { self = width < 1040 ? .tight : width < 1320 ? .compact : .roomy }
}

private struct RoomKey: EnvironmentKey { static let defaultValue = Room.roomy }
extension EnvironmentValues {
    var room: Room {
        get { self[RoomKey.self] }
        set { self[RoomKey.self] = newValue }
    }
}

struct ActionButton: View {
    let title: String
    let systemImage: String
    let primary: Bool
    /// Kept with its words however little room there is (the main action).
    var keepTitle = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @Environment(\.room) private var room
    @State private var hover = false

    var body: some View {
        let iconOnly = !keepTitle && room < .roomy
        Button(action: action) {
            Group {
                if iconOnly { Image(systemName: systemImage) } else { Label(title, systemImage: systemImage) }
            }
                .font(Theme.Font.lg)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, iconOnly ? 10 : 14)
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
        .help(iconOnly ? title : "")
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
    @Environment(\.room) private var room

    var body: some View {
        VStack(spacing: 0) {
            Text("\(value)")
                .font(large ? Theme.Font.counterLg : Theme.Font.counter)
                .foregroundStyle(value == 0 ? Theme.textMuted : (tint ?? (highlight ? Theme.success : Theme.text)))
                .monospacedDigit()
            Text(label).font(Theme.Font.xs).foregroundStyle(Theme.textMuted).lineLimit(1).fixedSize()
        }
        .frame(minWidth: room == .roomy ? (large ? 84 : 56) : (large ? 64 : 44))
        .accessibilityElement(children: .combine)
    }
}

struct Chevron: View {
    @Environment(\.room) private var room

    var body: some View {
        if room == .roomy { Image(systemName: "chevron.right").font(Theme.Font.sm).foregroundStyle(Theme.border) }
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
