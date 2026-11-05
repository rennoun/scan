import Foundation
import UIKit

/// Stores every scan in Documents/Scans/<uuid>/ (visible in the Files app,
/// so photos and models can also be copied to a PC by cable).
///
///   meta.json      project info
///   Images/        captured photos (HEIC with depth + gravity)
///   Checkpoints/   reconstruction cache
///   model.usdz / model.obj
/// Used from the main thread only.
final class ProjectStore: ObservableObject {
    static let shared = ProjectStore()

    @Published private(set) var projects: [ScanProject] = []
    let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Paths

    func folder(for p: ScanProject) -> URL { root.appendingPathComponent(p.id.uuidString, isDirectory: true) }
    func imagesFolder(for p: ScanProject) -> URL { folder(for: p).appendingPathComponent("Images", isDirectory: true) }
    func checkpointFolder(for p: ScanProject) -> URL { folder(for: p).appendingPathComponent("Checkpoints", isDirectory: true) }
    func exportsFolder(for p: ScanProject) -> URL { folder(for: p).appendingPathComponent("Exports", isDirectory: true) }
    func modelURL(for p: ScanProject) -> URL? {
        guard let name = p.modelFileName else { return nil }
        let url = folder(for: p).appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: CRUD

    func create(mode: ScanMode) -> ScanProject {
        let f = DateFormatter()
        f.dateFormat = "dd MMM HH:mm"
        let p = ScanProject(name: "\(mode.title) scan \(f.string(from: Date()))", mode: mode)
        let fm = FileManager.default
        for dir in [folder(for: p), imagesFolder(for: p), checkpointFolder(for: p), exportsFolder(for: p)] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        save(p)
        Log.i("Created project \(p.id) mode=\(mode.rawValue)")
        return p
    }

    func save(_ p: ScanProject) {
        do {
            let data = try encoder.encode(p)
            try data.write(to: folder(for: p).appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            Log.e("Save failed: \(error.localizedDescription)")
        }
        if let i = projects.firstIndex(where: { $0.id == p.id }) {
            projects[i] = p
        } else {
            projects.insert(p, at: 0)
        }
    }

    func project(id: UUID) -> ScanProject? { projects.first { $0.id == id } }

    func delete(_ p: ScanProject) {
        try? FileManager.default.removeItem(at: folder(for: p))
        projects.removeAll { $0.id == p.id }
        Log.i("Deleted project \(p.id)")
    }

    func reload() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var loaded: [ScanProject] = []
        for dir in dirs {
            let meta = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: meta),
                  var p = try? decoder.decode(ScanProject.self, from: data) else { continue }
            // An app kill during processing leaves a stale status.
            if p.status == .processing { p.status = .captured }
            loaded.append(p)
        }
        projects = loaded.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Helpers

    func imageFiles(for p: ScanProject) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: imagesFolder(for: p), includingPropertiesForKeys: nil)) ?? []
        let exts: Set<String> = ["heic", "jpg", "jpeg", "png"]
        return urls.filter { exts.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func refreshImageCount(_ p: inout ScanProject) {
        p.imageCount = imageFiles(for: p).count
    }

    func thumbnail(for p: ScanProject) -> UIImage? {
        let thumbURL = folder(for: p).appendingPathComponent("thumb.jpg")
        if let img = UIImage(contentsOfFile: thumbURL.path) { return img }
        guard let first = imageFiles(for: p).first,
              let img = UIImage(contentsOfFile: first.path),
              let small = img.preparingThumbnail(of: CGSize(width: 240, height: 240 * img.size.height / max(img.size.width, 1))) else { return nil }
        try? small.jpegData(compressionQuality: 0.8)?.write(to: thumbURL)
        return small
    }

    func saveThumbnail(_ image: UIImage, for p: ScanProject) {
        let thumbURL = folder(for: p).appendingPathComponent("thumb.jpg")
        try? image.jpegData(compressionQuality: 0.8)?.write(to: thumbURL)
    }
}
