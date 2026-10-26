import SwiftUI

/// Colour roles and sizes from replica/design/tokens.json. Views use these, never raw values.
enum Theme {
    static let bg = Color(hex: 0x121417)
    static let surface = Color(hex: 0x1C1F22)  // brand: dark slate
    static let surface2 = Color(hex: 0x252930)
    static let trackBg = Color(hex: 0x0B0C0E)
    static let border = Color(hex: 0x30353D)
    static let borderInput = Color(hex: 0x6B7380)
    static let text = Color(hex: 0xE8EAED)
    static let textMuted = Color(hex: 0x9AA1AC)
    static let accent = Color(hex: 0xADF802)   // brand: vibrant lime
    static let onAccent = Color(hex: 0x1C1F22)
    static let brandWhite = Color.white
    static let danger = Color(hex: 0xEF6B6B)
    static let success = Color(hex: 0x4CC38A)
    static let warning = Color(hex: 0xE6C84F)
    /// Blue: found by its audio, exact. Yellow: found by its audio near where its date points,
    /// worth a look. Red: not found, placed by dates and neighbours.
    static let clipExact = Color(hex: 0x2F6FD6)
    static let clipApprox = Color(hex: 0xD9B532)
    static let clipGuessed = Color(hex: 0xC23B3B)
    static let onClipApprox = Color(hex: 0x1C1F22)
    static let clipIdle = Color(hex: 0x5B626D)
    static let clipMissing = Color(hex: 0xB33A3A)
    static let onClip = Color.white

    enum Size {
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16
        static let space5: CGFloat = 24
        static let radiusSm: CGFloat = 4
        static let radiusMd: CGFloat = 6
        static let trackHeaderW: CGFloat = 96
        static let trackMinH: CGFloat = 56
        static let overviewH: CGFloat = 12
        static let buttonH: CGFloat = 32
    }

    enum Font {
        static let xs = SwiftUI.Font.system(size: 11, weight: .medium)
        static let sm = SwiftUI.Font.system(size: 12)
        static let base = SwiftUI.Font.system(size: 13)
        static let lg = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let counter = SwiftUI.Font.system(size: 28, weight: .semibold, design: .monospaced)
        static let counterLg = SwiftUI.Font.system(size: 40, weight: .semibold, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
