import AppKit

/// Where people reach us (header, Ayuda menu, settings). One place to change them.
enum Contact {
    static let instagram = URL(string: "https://www.instagram.com/nanobrunetti/")!
    static let instagramChat = URL(string: "https://ig.me/m/nanobrunetti")!
    static let handle = "@nanobrunetti"
    static let site = URL(string: "https://clipxel.github.io/Synco/")!
    static let source = URL(string: "https://github.com/clipxel/Synco")!
    static let donate = URL(string: "https://onetouch.astropay.com/payment?external_reference_id=AERRP6sKfsrGdRunEEa6gJ7V5fQ1E0gO")!
    static let donateNote = "Synco es gratis y siempre lo va a ser. Tu aporte ayuda a seguir mejorándolo."

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var about: String {
        "Synco \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
    }

    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// A ready message in the clipboard (version + system) and the Instagram chat opens: paste, tell, send.
    static func sendReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("Synco\n\(about)\n\nQué pasó / qué te gustaría:\n", forType: .string)
        open(instagramChat)
    }
}
