import Foundation

enum ScanMode: String, Codable, CaseIterable, Identifiable {
    case object   // guided photogrammetry (Object Capture) — highest detail
    case large    // live LiDAR mesh — furniture, car parts, rooms

    var id: String { rawValue }

    var title: String {
        switch self {
        case .object: return "Object"
        case .large: return "Large / Room"
        }
    }

    var subtitle: String {
        switch self {
        case .object: return "Guided photo scan with LiDAR assist. Best detail for parts 5 cm – 1 m. Works with or without the Mizan scale mat."
        case .large: return "Live LiDAR mesh you can watch grow. Best for furniture, car interiors, rooms. ~1 cm accuracy."
        }
    }

    var symbol: String {
        switch self {
        case .object: return "cube.transparent"
        case .large: return "square.3.layers.3d"
        }
    }
}

enum ScanStatus: String, Codable {
    case captured    // photos taken, model not built yet
    case processing
    case ready       // model file available
    case failed
}

struct ScanProject: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var createdAt: Date
    var mode: ScanMode
    var status: ScanStatus
    var imageCount: Int
    /// Multiplier applied on top of the raw model (from "Set real length" calibration).
    var scaleFactor: Double
    var modelFileName: String?
    var lastError: String?

    init(name: String, mode: ScanMode) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.mode = mode
        self.status = .captured
        self.imageCount = 0
        self.scaleFactor = 1.0
        self.modelFileName = nil
        self.lastError = nil
    }
}
