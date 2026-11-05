import SwiftUI
import ARKit
import RealityKit

/// Large-object / room mode: live LiDAR mesh drawn over the camera image.
final class LidarController: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isRunning = false
    @Published var meshCount = 0
    @Published var trackingText = "Starting…"
    @Published var isSaving = false

    weak var arView: ARView?
    private var lastUIUpdate = Date.distantPast

    static var isSupported: Bool {
        ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
    }

    func attach(_ view: ARView) {
        arView = view
        view.session.delegate = self
        view.debugOptions.insert(.showSceneUnderstanding)
        view.renderOptions.insert(.disableMotionBlur)
    }

    func start() {
        guard let arView, Self.isSupported else {
            trackingText = "LiDAR not available on this device"
            return
        }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        config.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            config.frameSemantics.insert(.smoothedSceneDepth)
        }
        arView.session.run(config, options: [.resetTracking, .removeExistingAnchors])
        isRunning = true
        Log.i("LiDAR session started")
    }

    func pause() {
        arView?.session.pause()
        isRunning = false
        Log.i("LiDAR session paused")
    }

    func resume() {
        guard let arView, let config = arView.session.configuration else { return }
        arView.session.run(config)   // keep existing anchors
        isRunning = true
    }

    func stop() {
        arView?.session.pause()
        isRunning = false
    }

    var meshAnchors: [ARMeshAnchor] {
        arView?.session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor } ?? []
    }

    func snapshot(_ completion: @escaping (UIImage?) -> Void) {
        guard let arView else { completion(nil); return }
        arView.snapshot(saveToHDR: false) { completion($0) }
    }

    // MARK: ARSessionDelegate (main queue)

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) { throttledUpdate(session) }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) { throttledUpdate(session) }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        switch camera.trackingState {
        case .normal: trackingText = "Tracking OK"
        case .notAvailable: trackingText = "Tracking unavailable"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion: trackingText = "Slow down"
            case .insufficientFeatures: trackingText = "Point at more detail"
            case .initializing: trackingText = "Initializing…"
            case .relocalizing: trackingText = "Relocalizing…"
            @unknown default: trackingText = "Limited tracking"
            }
        }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        Log.e("ARSession error: \(error.localizedDescription)")
        trackingText = "Error: \(error.localizedDescription)"
    }

    private func throttledUpdate(_ session: ARSession) {
        guard Date().timeIntervalSince(lastUIUpdate) > 0.5 else { return }
        lastUIUpdate = Date()
        meshCount = session.currentFrame?.anchors.filter { $0 is ARMeshAnchor }.count ?? 0
    }
}

struct LidarARView: UIViewRepresentable {
    let controller: LidarController

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        controller.attach(view)
        controller.start()
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
    }
}

struct LidarScanScreen: View {
    let project: ScanProject
    let onClose: (_ saved: Bool) -> Void

    @EnvironmentObject private var store: ProjectStore
    @StateObject private var controller = LidarController()
    @State private var errorText: String?

    var body: some View {
        ZStack {
            LidarARView(controller: controller).ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Button {
                        controller.stop()
                        onClose(false)
                    } label: {
                        Image(systemName: "xmark").font(.headline).padding(12)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    Spacer()
                    Text("\(controller.trackingText)  ·  \(controller.meshCount) mesh blocks")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                Spacer()
                if let errorText {
                    Text(errorText).font(.footnote).padding(10)
                        .background(Color.red.opacity(0.8), in: RoundedRectangle(cornerRadius: 10))
                }
                Text("Sweep slowly. Coloured mesh = scanned surface.")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                HStack(spacing: 14) {
                    Button {
                        controller.isRunning ? controller.pause() : controller.resume()
                    } label: {
                        Label(controller.isRunning ? "Pause" : "Resume",
                              systemImage: controller.isRunning ? "pause.fill" : "play.fill")
                            .font(.headline)
                            .padding(.horizontal, 20).padding(.vertical, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .foregroundStyle(.white)

                    Button(action: save) {
                        Group {
                            if controller.isSaving { ProgressView().tint(.black) }
                            else { Label("Save scan", systemImage: "checkmark") }
                        }
                        .font(.headline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 22).padding(.vertical, 14)
                        .background(Theme.accent, in: Capsule())
                    }
                    .disabled(controller.isSaving || controller.meshCount == 0)
                }
            }
            .padding()
        }
        .statusBarHidden()
    }

    private func save() {
        controller.isSaving = true
        let anchors = controller.meshAnchors
        controller.snapshot { image in
            controller.pause()
            let p = project
            let url = store.folder(for: p).appendingPathComponent("model.obj")
            DispatchQueue.global(qos: .userInitiated).async {
                let mesh = MeshData.from(meshAnchors: anchors)
                do {
                    // Stored in metres internally (scale 1); exports convert to mm.
                    try mesh.write(.obj, to: url, metresToOutput: 1)
                    DispatchQueue.main.async {
                        if let image { store.saveThumbnail(image, for: p) }
                        var updated = store.project(id: p.id) ?? p
                        updated.modelFileName = "model.obj"
                        updated.status = .ready
                        store.save(updated)
                        Log.i("LiDAR scan saved: \(mesh.vertexCount) vertices, \(mesh.triangleCount) triangles")
                        controller.isSaving = false
                        onClose(true)
                    }
                } catch {
                    DispatchQueue.main.async {
                        Log.e("LiDAR save failed: \(error.localizedDescription)")
                        errorText = error.localizedDescription
                        controller.isSaving = false
                    }
                }
            }
        }
    }
}
