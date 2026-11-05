import Foundation
import RealityKit
import UIKit

/// Builds a 3D model from the captured photos, on the iPhone itself
/// (RealityKit PhotogrammetrySession). Keep the app open while it runs.
@MainActor
final class ReconstructionModel: ObservableObject {
    @Published var isRunning = false
    @Published var progress: Double = 0
    @Published var stage = ""
    @Published var errorText: String?

    private var session: PhotogrammetrySession?
    private var task: Task<Void, Never>?

    static var isSupported: Bool { PhotogrammetrySession.isSupported }

    func run(projectID: UUID, store: ProjectStore) {
        guard !isRunning, var project = store.project(id: projectID) else { return }
        guard Self.isSupported else {
            errorText = "On-device reconstruction isn't supported on this device. Export the photos and process them on a Mac or PC."
            return
        }
        let input = store.imagesFolder(for: project)
        let output = store.folder(for: project).appendingPathComponent("model.usdz")
        try? FileManager.default.removeItem(at: output)

        var config = PhotogrammetrySession.Configuration()
        config.checkpointDirectory = store.checkpointFolder(for: project)
        config.isObjectMaskingEnabled = true

        do {
            let session = try PhotogrammetrySession(input: input, configuration: config)
            self.session = session
            try session.process(requests: [.modelFile(url: output)])
            isRunning = true
            progress = 0
            stage = "Aligning photos…"
            errorText = nil
            project.status = .processing
            store.save(project)
            Log.i("Reconstruction started for \(projectID)")
            UIApplicationIdle.set(disabled: true)

            task = Task { [weak self] in
                do {
                    for try await out in session.outputs {
                        guard let self else { return }
                        switch out {
                        case .requestProgress(_, let fraction):
                            self.progress = fraction
                            self.stage = fraction < 0.3 ? "Aligning photos…" : (fraction < 0.8 ? "Building geometry…" : "Texturing…")
                        case .requestComplete(_, _):
                            Log.i("Model file written")
                        case .requestError(_, let error):
                            self.fail(projectID: projectID, store: store, message: error.localizedDescription)
                        case .processingComplete:
                            self.complete(projectID: projectID, store: store)
                        case .processingCancelled:
                            self.fail(projectID: projectID, store: store, message: "Cancelled")
                        default:
                            Log.i("Photogrammetry: \(String(describing: out))")
                        }
                    }
                } catch {
                    self?.fail(projectID: projectID, store: store, message: error.localizedDescription)
                }
            }
        } catch {
            fail(projectID: projectID, store: store, message: error.localizedDescription)
        }
    }

    func cancel() {
        session?.cancel()
    }

    private func complete(projectID: UUID, store: ProjectStore) {
        guard isRunning else { return }
        isRunning = false
        progress = 1
        stage = "Done"
        UIApplicationIdle.set(disabled: false)
        if var p = store.project(id: projectID) {
            p.modelFileName = "model.usdz"
            p.status = .ready
            p.lastError = nil
            store.save(p)
        }
        Log.i("Reconstruction complete")
        session = nil
    }

    private func fail(projectID: UUID, store: ProjectStore, message: String) {
        isRunning = false
        errorText = message
        UIApplicationIdle.set(disabled: false)
        if var p = store.project(id: projectID) {
            p.status = .failed
            p.lastError = message
            store.save(p)
        }
        Log.e("Reconstruction failed: \(message)")
        session = nil
    }
}

enum UIApplicationIdle {
    /// Keep the screen awake during long processing.
    static func set(disabled: Bool) {
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = disabled }
    }
}
