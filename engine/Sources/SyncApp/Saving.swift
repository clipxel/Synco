import AppKit
import SwiftUI
import SyncCore
import UniformTypeIdentifiers

extension UTType {
    /// A Synco project (.synco), declared in the app's Info.plist.
    static let syncoProject = UTType(filenameExtension: SavedProject.fileExtension, conformingTo: .json) ?? .json
}

/// Saving the project to a file of its own and opening it again as it was left: the tracks,
/// the sync with its hand corrections and drones, and what was heard. The audio already read
/// comes back from the cache, so it opens in moments and there is no need to sync again.
extension AppModel {
    var canSave: Bool { project != nil && phase != .matching && !addingDrone }

    /// Whether closing now would lose work: a sync, or corrections, not saved.
    var hasUnsaved: Bool { dirty && project != nil && (outcome != nil || !ignored.isEmpty) }

    var projectTitle: String {
        savedURL?.deletingPathExtension().lastPathComponent ?? project?.sequenceName ?? "Proyecto"
    }

    /// Opening something else, as the user asked: first, what is not saved.
    func userOpen(_ url: URL) {
        guard confirmLeaving() else { return }
        open(url)
    }

    /// Saves to its file, or asks where the first time (or always, with `choosing`).
    @discardableResult
    func saveProject(choosing: Bool = false, to chosen: URL? = nil) -> Bool {
        guard let project, let fileURL, canSave else { return false }
        var target = chosen ?? (choosing ? nil : savedURL)
        if target == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.syncoProject]
            panel.directoryURL = savedURL?.deletingLastPathComponent() ?? saveFolder
            panel.nameFieldStringValue = projectTitle + "." + SavedProject.fileExtension
            panel.message = "Se guarda todo: las pistas, lo sincronizado y lo corregido a mano. Los videos y audios quedan donde están."
            panel.prompt = "Guardar"
            guard panel.runModal() == .OK else { return false }
            target = panel.url
        }
        guard let url = target else { return false }
        var saved = SavedProject(xml: project.xmlString, source: fileURL.path)
        saved.app = "Synco \(Contact.version) · macOS"
        saved.outcome = outcome?.saved
        saved.ignored = ignored.sorted()
        saved.droneFiles = droneSources.map { $0.map(\.path) }
        saved.mutedTracks = mutedTracks.sorted()
        saved.soloTrack = soloTrack
        saved.playhead = playhead
        saved.selected = selected
        do {
            try saved.write(to: url)
        } catch {
            message = "No se pudo guardar el proyecto: \(error.localizedDescription)"
            return false
        }
        savedURL = url
        dirty = false
        prefs.recents = ([url.path] + prefs.recents.filter { $0 != url.path && $0 != fileURL.path }).prefix(8).map { $0 }
        message = "Proyecto guardado: \(url.lastPathComponent). Abrilo cuando quieras y sigue como está, sin volver a sincronizar."
        return true
    }

    /// Where a new project file goes: next to the shoot (the folder that holds all its files).
    private var saveFolder: URL? {
        let folders = Array(Set(project?.clips.map { $0.url.deletingLastPathComponent() } ?? []))
        return ProjectBuilder.commonFolder(folders) ?? fileURL?.deletingLastPathComponent()
    }

    /// A saved project, back as it was (called when its file was opened).
    func restore(_ saved: SavedProject, from url: URL) {
        savedURL = url
        dirty = false
        // A project built from folders keeps its XML in Synco's folder: written again if it is gone.
        if let fileURL, isBuilt, !FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.createDirectory(at: ProjectBuilder.projectsDir, withIntermediateDirectories: true)
            try? saved.xml.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        guard let project else { return }
        if let o = saved.outcome(for: project) {
            outcome = o
            placements = Dictionary(uniqueKeysWithValues: o.placements.map { ($0.id, $0) })
            starts = o.starts
        }
        let known = Set(project.clips.map(\.fileID))
        ignored = Set(saved.ignored).intersection(known)
        droneSources = saved.droneFiles.map { $0.map { URL(fileURLWithPath: $0) } }
        mutedTracks = Set(saved.mutedTracks)
        soloTrack = saved.soloTrack
        playhead = saved.playhead
        selected = saved.selected.flatMap { clip($0) == nil ? nil : $0 }
    }

    /// Before leaving the project (opening another, closing, quitting): saves it if the user wants.
    /// False when the user cancels.
    func confirmLeaving() -> Bool {
        guard hasUnsaved, persist else { return true }
        let alert = NSAlert()
        alert.messageText = "¿Guardás los cambios de “\(projectTitle)”?"
        alert.informativeText = "Si no lo guardás, al volver a abrirlo vas a tener que sincronizar de nuevo, y se pierde lo que corregiste a mano."
        alert.addButton(withTitle: "Guardar")
        alert.addButton(withTitle: "No guardar")
        alert.addButton(withTitle: "Cancelar")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return saveProject()
        case .alertSecondButtonReturn: dirty = false; return true
        default: return false
        }
    }
}
