import SwiftUI
import SceneKit
import simd
import UIKit

/// Loads a scan (USDZ from photogrammetry or OBJ from LiDAR) and lets the user
/// orbit it and measure point-to-point distances.
final class ViewerController: ObservableObject {
    @Published var isLoaded = false
    @Published var loadError: String?
    @Published var measuring = false { didSet { if !measuring { clearMeasurement() } } }
    @Published var distanceMM: Double?
    @Published var stats = ""
    /// "Remove table & noise" view (grey mesh) vs. original textured model.
    @Published private(set) var cleanOn = false
    @Published private(set) var cleaning = false
    @Published var cleanSummary: String?

    private var originalNode: SCNNode?
    private var cleanNode: SCNNode?

    let scene = SCNScene()
    /// Holds the model; its scale = project.scaleFactor.
    let container = SCNNode()
    private let measureRoot = SCNNode()
    private var points: [SCNVector3] = []
    private var markerRadius: CGFloat = 0.002
    weak var view: SCNView?

    init() {
        scene.rootNode.addChildNode(container)
        scene.rootNode.addChildNode(measureRoot)
        scene.background.contents = UIColor(red: 0.05, green: 0.07, blue: 0.10, alpha: 1)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)
    }

    func load(url: URL, scale: Double, autoClean: Bool = false) {
        container.childNodes.forEach { $0.removeFromParentNode() }
        originalNode = nil
        cleanNode = nil
        cleanOn = false
        cleanSummary = nil
        DispatchQueue.global(qos: .userInitiated).async {
            var node: SCNNode?
            var triangles = 0
            var error: String?
            if url.pathExtension.lowercased() == "obj", let mesh = MeshData.readOBJ(url: url) {
                node = mesh.makeNode()
                triangles = mesh.triangleCount
            } else {
                do {
                    let loaded = try SCNScene(url: url, options: [.checkConsistency: false])
                    let holder = SCNNode()
                    for child in loaded.rootNode.childNodes { holder.addChildNode(child) }
                    node = holder
                    triangles = MeshData.from(node: holder).triangleCount
                } catch let e {
                    error = e.localizedDescription
                }
            }
            DispatchQueue.main.async {
                guard let node else {
                    self.loadError = error ?? "Could not open model"
                    Log.e("Viewer load failed: \(self.loadError ?? "")")
                    return
                }
                // Centre the model at the origin.
                let (lo, hi) = node.boundingBox
                let centre = SCNVector3((lo.x + hi.x) / 2, (lo.y + hi.y) / 2, (lo.z + hi.z) / 2)
                node.position = SCNVector3(-centre.x, -centre.y, -centre.z)
                self.container.addChildNode(node)
                self.originalNode = node
                self.setScale(scale)
                let size = SIMD3<Float>(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z)
                self.markerRadius = CGFloat(max(simd_length(size), 0.01) * 0.006)
                self.stats = "\(triangles.formatted()) triangles"
                self.isLoaded = true
                self.view?.pointOfView = nil   // let SceneKit re-frame
                if autoClean { self.setClean(true) }
            }
        }
    }

    // MARK: Clean (remove support plane + floating noise)

    func setClean(_ on: Bool) {
        guard let originalNode, !cleaning else { return }
        clearMeasurement()
        if !on {
            cleanNode?.removeFromParentNode()
            if originalNode.parent == nil { container.addChildNode(originalNode) }
            cleanOn = false
            return
        }
        if let cleanNode {
            originalNode.removeFromParentNode()
            if cleanNode.parent == nil { container.addChildNode(cleanNode) }
            cleanOn = true
            return
        }
        cleaning = true
        let container = self.container
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = MeshData.from(node: originalNode, relativeTo: container)
            let (mesh, report) = raw.cleaned()
            DispatchQueue.main.async {
                self.cleaning = false
                self.cleanSummary = report.summary
                Log.i("Clean: \(report.summary)")
                guard report.trianglesAfter < report.trianglesBefore else { return }
                let node = mesh.makeNode()   // already in container space
                self.cleanNode = node
                originalNode.removeFromParentNode()
                container.addChildNode(node)
                self.cleanOn = true
                self.stats = "\(mesh.triangleCount.formatted()) triangles"
            }
        }
    }

    func setScale(_ s: Double) {
        container.scale = SCNVector3(Float(s), Float(s), Float(s))
        clearMeasurement()
    }

    /// Bounding box size (mm) of the scaled model.
    var sizeMM: SIMD3<Double> {
        let (lo, hi) = container.boundingBox
        let s = Double(container.scale.x)
        return SIMD3<Double>(Double(hi.x - lo.x), Double(hi.y - lo.y), Double(hi.z - lo.z)) * s * 1000
    }

    // MARK: Measuring

    func handleTap(at point: CGPoint) {
        guard measuring, let view else { return }
        let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue,
                                                 .rootNode: container])
        guard let hit = hits.first else { return }
        if points.count >= 2 { clearMeasurement() }
        let p = hit.worldCoordinates
        points.append(p)
        addMarker(at: p)
        if points.count == 2 {
            let a = points[0], b = points[1]
            let d = simd_distance(SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(b.x, b.y, b.z))
            distanceMM = Double(d) * 1000
            addLine(from: a, to: b)
            Log.i(String(format: "Measured %.2f mm", distanceMM ?? 0))
        }
    }

    func clearMeasurement() {
        points.removeAll()
        distanceMM = nil
        measureRoot.childNodes.forEach { $0.removeFromParentNode() }
    }

    private func addMarker(at p: SCNVector3) {
        let s = SCNSphere(radius: markerRadius)
        s.firstMaterial?.diffuse.contents = UIColor(red: 0.18, green: 0.85, blue: 0.76, alpha: 1)
        s.firstMaterial?.lightingModel = .constant
        s.firstMaterial?.readsFromDepthBuffer = false
        let n = SCNNode(geometry: s)
        n.position = p
        n.renderingOrder = 100
        measureRoot.addChildNode(n)
    }

    private func addLine(from a: SCNVector3, to b: SCNVector3) {
        let src = SCNGeometrySource(vertices: [a, b])
        let el = SCNGeometryElement(indices: [UInt16(0), UInt16(1)], primitiveType: .line)
        let g = SCNGeometry(sources: [src], elements: [el])
        g.firstMaterial?.diffuse.contents = UIColor.white
        g.firstMaterial?.lightingModel = .constant
        g.firstMaterial?.readsFromDepthBuffer = false
        let n = SCNNode(geometry: g)
        n.renderingOrder = 99
        measureRoot.addChildNode(n)
    }

    /// Export the scaled model as STL/OBJ/PLY in millimetres.
    func exportMesh(_ format: MeshData.Format, to url: URL) throws -> MeshData {
        let mesh = MeshData.from(node: container)
        guard !mesh.isEmpty else {
            throw NSError(domain: "Mizan3D", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model has no triangles"])
        }
        try mesh.write(format, to: url)
        return mesh
    }
}

struct ModelViewer: UIViewRepresentable {
    @ObservedObject var controller: ViewerController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> SCNView {
        let v = SCNView()
        v.scene = controller.scene
        v.allowsCameraControl = true
        v.autoenablesDefaultLighting = true
        v.antialiasingMode = .multisampling4X
        v.backgroundColor = .clear
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        controller.view = v
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        return v
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject {
        let controller: ViewerController
        init(controller: ViewerController) { self.controller = controller }
        @objc func tapped(_ g: UITapGestureRecognizer) {
            controller.handleTap(at: g.location(in: g.view))
        }
    }
}
