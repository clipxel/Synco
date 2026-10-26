import AppKit
import CryptoKit
import Foundation

/// Self-update. On launch Synco reads the latest release's update.json (version + SHA-256 of the
/// installer, written by the release workflow). If it is newer, the user is offered "Actualizar
/// ahora / Más tarde". "Now" downloads the .dmg, checks its SHA-256, copies the new app out of it,
/// and a small script swaps it in once Synco quits and opens the new version. Nothing to do by hand.
@MainActor
final class Updater: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, available, downloading, ready, failed(String) }

    struct Info: Equatable {
        var version, notes, url, sha256, file: String
        var size: Int
    }

    static let defaultManifest = URL(string: "https://github.com/clipxel/Synco/releases/latest/download/update.json")!

    @Published private(set) var state = State.idle
    @Published private(set) var info: Info?
    @Published private(set) var progress = 0.0

    /// Tests point this at a local file (SYNCO_UPDATE_MANIFEST); the app at the latest release.
    var manifestURL: URL {
        ProcessInfo.processInfo.environment["SYNCO_UPDATE_MANIFEST"].flatMap { URL(string: $0) } ?? Self.defaultManifest
    }
    /// The app bundle being replaced (overridable for tests).
    var target: URL {
        ProcessInfo.processInfo.environment["SYNCO_UPDATE_TARGET"].map { URL(fileURLWithPath: $0) } ?? Bundle.main.bundleURL
    }
    private var staged: URL?
    private let work = FileManager.default.temporaryDirectory.appendingPathComponent("Synco-update")

    // MARK: Versions and manifest

    static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    static func parse(_ data: Data) -> Info? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mac = (root["assets"] as? [String: Any])?["mac"] as? [String: Any],
              let version = root["version"] as? String,
              let url = mac["url"] as? String, let sha = (mac["sha256"] as? String)?.lowercased(),
              let file = mac["file"] as? String else { return nil }
        // Only our releases (or a local file in tests), a real hash, a plain file name.
        let safe = url.hasPrefix("https://github.com/clipxel/Synco/releases/download/") || url.hasPrefix("file:")
        guard safe, sha.count == 64, !file.isEmpty, !file.contains("/") else { return nil }
        return Info(version: version, notes: root["notes"] as? String ?? "", url: url, sha256: sha,
                    file: file, size: mac["size"] as? Int ?? 0)
    }

    // MARK: Check

    /// `quiet`: on launch, say nothing unless there is something new (offline counts as nothing new).
    func check(quiet: Bool) {
        guard state != .checking, state != .downloading else { return }
        state = .checking
        let url = manifestURL
        Task {
            let data: Data? = await {
                if url.isFileURL { return try? Data(contentsOf: url) }
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
                request.setValue("Synco/\(Contact.version)", forHTTPHeaderField: "User-Agent")
                guard let (d, r) = try? await URLSession.shared.data(for: request),
                      (r as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return d
            }()
            if let found = data.flatMap(Self.parse), Self.compare(found.version, Contact.version) > 0 {
                info = found
                state = .available
                // Scripted update test: no dialog, straight to the download.
                if ProcessInfo.processInfo.environment["SYNCO_UPDATE_AUTO"] != nil { download() } else { offer(found) }
            } else {
                state = .upToDate
                if !quiet { tell("Synco está al día", "Tenés la última versión (\(Contact.version)).") }
            }
        }
    }

    private func offer(_ found: Info) {
        let alert = NSAlert()
        alert.messageText = "Hay una versión nueva de Synco: \(found.version)"
        let notes = found.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = (notes.isEmpty ? "" : String(notes.prefix(600)) + "\n\n")
            + "Tenés la \(Contact.version). Se descarga, se verifica y se reemplaza sola: no hace falta reinstalar."
        alert.addButton(withTitle: "Actualizar ahora")
        alert.addButton(withTitle: "Más tarde")
        if alert.runModal() == .alertFirstButtonReturn { download() }
    }

    // MARK: Download, verify, stage

    func download() {
        guard let info, state == .available || state.isFailure else { return }
        state = .downloading
        progress = 0
        let work = self.work
        Task {
            do {
                let app = try await Self.fetchAndStage(info, work: work) { p in
                    Task { @MainActor in self.progress = p }
                }
                staged = app
                state = .ready
                installAndRelaunch(relaunch: ProcessInfo.processInfo.environment["SYNCO_UPDATE_AUTO"] == nil)
            } catch {
                state = .failed("\(error)")
                tell("No se pudo actualizar", "\(error)\n\nPodés bajar la versión nueva desde la página de Synco.")
            }
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    nonisolated static func fetchAndStage(_ info: Info, work: URL, progress: @escaping (Double) -> Void) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let dmg = work.appendingPathComponent(info.file)
        let source = URL(string: info.url)!
        if source.isFileURL {
            try fm.copyItem(at: source, to: dmg)
        } else {
            let (tmp, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "la descarga falló") }
            try fm.moveItem(at: tmp, to: dmg)
        }
        progress(0.7)
        let data = try Data(contentsOf: dmg, options: .mappedIfSafe)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == info.sha256 else { throw Failure(description: "el archivo descargado no coincide con el publicado") }

        // Mount, copy the app out, unmount.
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        try run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        let staged = work.appendingPathComponent("Synco.app")
        try run("/usr/bin/ditto", [mount.appendingPathComponent("Synco.app").path, staged.path])
        progress(1)
        return staged
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw Failure(description: "\((tool as NSString).lastPathComponent): \(text)") }
        return text
    }

    // MARK: Swap

    /// Starts the swap script and quits. The script waits for this process to end, moves the old app
    /// aside, puts the new one in its place (restoring the old one if that fails) and opens it.
    func installAndRelaunch(relaunch: Bool = true) {
        guard let staged else { return }
        let script = work.appendingPathComponent("swap.sh")
        let t = target.path
        let body = """
        #!/bin/sh
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        T=\(shellQuote(t))
        rm -rf "$T.old"
        if mv "$T" "$T.old" && /usr/bin/ditto \(shellQuote(staged.path)) "$T"; then rm -rf "$T.old"; else rm -rf "$T"; mv "$T.old" "$T"; fi
        /usr/bin/xattr -dr com.apple.quarantine "$T" 2>/dev/null
        \(relaunch ? "/usr/bin/open \"$T\"" : "")
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = [script.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("\(error)")
        }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func tell(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}

extension Updater.State {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}
