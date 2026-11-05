import Foundation
import simd
import SceneKit
import ARKit
import UIKit

/// Plain triangle mesh used for export. Positions are in metres (ARKit / RealityKit units).
struct MeshData {
    var positions: [SIMD3<Float>] = []
    var indices: [UInt32] = []

    var vertexCount: Int { positions.count }
    var triangleCount: Int { indices.count / 3 }
    var isEmpty: Bool { indices.isEmpty }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>) {
        guard var lo = positions.first else { return (.zero, .zero) }
        var hi = lo
        for p in positions { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        return (lo, hi)
    }

    // MARK: Builders

    /// Collect LiDAR mesh anchors into one world-space mesh.
    static func from(meshAnchors: [ARMeshAnchor]) -> MeshData {
        var mesh = MeshData()
        for anchor in meshAnchors {
            let g = anchor.geometry
            let base = UInt32(mesh.positions.count)
            let vb = g.vertices
            let vptr = vb.buffer.contents().advanced(by: vb.offset)
            mesh.positions.reserveCapacity(mesh.positions.count + vb.count)
            for i in 0..<vb.count {
                // .float3 = 12 bytes; read components one by one (SIMD3<Float> is 16 bytes in memory)
                let vp = vptr.advanced(by: vb.stride * i)
                let x = vp.loadUnaligned(fromByteOffset: 0, as: Float.self)
                let y = vp.loadUnaligned(fromByteOffset: 4, as: Float.self)
                let z = vp.loadUnaligned(fromByteOffset: 8, as: Float.self)
                let w = anchor.transform * SIMD4<Float>(x, y, z, 1)
                mesh.positions.append(SIMD3<Float>(w.x, w.y, w.z))
            }
            let f = g.faces
            let fptr = f.buffer.contents()
            let n = f.count * f.indexCountPerPrimitive
            mesh.indices.reserveCapacity(mesh.indices.count + n)
            for i in 0..<n {
                let idx: UInt32
                if f.bytesPerIndex == 4 {
                    idx = fptr.advanced(by: i * 4).loadUnaligned(as: UInt32.self)
                } else {
                    idx = UInt32(fptr.advanced(by: i * 2).loadUnaligned(as: UInt16.self))
                }
                mesh.indices.append(base + idx)
            }
        }
        return mesh
    }

    /// Flatten every triangle geometry under a SceneKit node into world space.
    static func from(node root: SCNNode) -> MeshData {
        var mesh = MeshData()
        root.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry,
                  let source = geometry.sources(for: .vertex).first else { return }
            let world = node.simdWorldTransform
            let base = UInt32(mesh.positions.count)
            for v in readVectors(source) {
                let w = world * SIMD4<Float>(v.x, v.y, v.z, 1)
                mesh.positions.append(SIMD3<Float>(w.x, w.y, w.z))
            }
            for element in geometry.elements {
                guard element.primitiveType == .triangles else {
                    Log.w("Skipping non-triangle element (\(element.primitiveType.rawValue))")
                    continue
                }
                let count = element.primitiveCount * 3
                let bpi = element.bytesPerIndex
                element.data.withUnsafeBytes { raw in
                    guard raw.count >= count * bpi else { return }
                    for i in 0..<count {
                        let idx: UInt32
                        switch bpi {
                        case 1: idx = UInt32(raw.load(fromByteOffset: i, as: UInt8.self))
                        case 2: idx = UInt32(raw.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
                        default: idx = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)
                        }
                        mesh.indices.append(base + idx)
                    }
                }
            }
        }
        return mesh
    }

    private static func readVectors(_ src: SCNGeometrySource) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(src.vectorCount)
        let stride = src.dataStride, offset = src.dataOffset, bpc = src.bytesPerComponent
        guard src.usesFloatComponents, src.componentsPerVector >= 3 else { return out }
        src.data.withUnsafeBytes { raw in
            for i in 0..<src.vectorCount {
                let b = offset + i * stride
                guard b + bpc * 3 <= raw.count else { break }
                if bpc == 8 {
                    out.append(SIMD3<Float>(Float(raw.loadUnaligned(fromByteOffset: b, as: Double.self)),
                                            Float(raw.loadUnaligned(fromByteOffset: b + 8, as: Double.self)),
                                            Float(raw.loadUnaligned(fromByteOffset: b + 16, as: Double.self))))
                } else {
                    out.append(SIMD3<Float>(raw.loadUnaligned(fromByteOffset: b, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: b + 4, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: b + 8, as: Float.self)))
                }
            }
        }
        return out
    }

    // MARK: Writers (output in millimetres — what slicers and CAD expect)

    enum Format: String, CaseIterable, Identifiable {
        case stl, obj, ply
        var id: String { rawValue }
        var label: String { rawValue.uppercased() }
    }

    func write(_ format: Format, to url: URL, metresToOutput scale: Float = 1000) throws {
        switch format {
        case .stl: try writeSTL(to: url, scale: scale)
        case .obj: try writeOBJ(to: url, scale: scale)
        case .ply: try writePLY(to: url, scale: scale)
        }
    }

    private func writeSTL(to url: URL, scale: Float) throws {
        var data = Data(capacity: 84 + triangleCount * 50)
        var header = Data("Mizan3D scan, units: mm".utf8)
        header.append(Data(count: 80 - header.count))
        data.append(header)
        appendLE(&data, UInt32(triangleCount))
        for t in 0..<triangleCount {
            let a = positions[Int(indices[t * 3])] * scale
            let b = positions[Int(indices[t * 3 + 1])] * scale
            let c = positions[Int(indices[t * 3 + 2])] * scale
            var n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            n = len > 0 ? n / len : .zero
            for v in [n, a, b, c] { appendLE(&data, v.x); appendLE(&data, v.y); appendLE(&data, v.z) }
            appendLE(&data, UInt16(0))
        }
        try data.write(to: url, options: .atomic)
    }

    private func writeOBJ(to url: URL, scale: Float) throws {
        var s = "# Mizan3D scan, units: mm\n"
        s.reserveCapacity(vertexCount * 32 + triangleCount * 24)
        for p in positions {
            let q = p * scale
            s += "v \(q.x) \(q.y) \(q.z)\n"
        }
        for t in 0..<triangleCount {
            s += "f \(indices[t * 3] + 1) \(indices[t * 3 + 1] + 1) \(indices[t * 3 + 2] + 1)\n"
        }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writePLY(to url: URL, scale: Float) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment Mizan3D scan, units: mm
        element vertex \(vertexCount)
        property float x
        property float y
        property float z
        element face \(triangleCount)
        property list uchar int vertex_indices
        end_header

        """
        var data = Data(header.utf8)
        for p in positions {
            let q = p * scale
            appendLE(&data, q.x); appendLE(&data, q.y); appendLE(&data, q.z)
        }
        for t in 0..<triangleCount {
            data.append(UInt8(3))
            appendLE(&data, Int32(indices[t * 3]))
            appendLE(&data, Int32(indices[t * 3 + 1]))
            appendLE(&data, Int32(indices[t * 3 + 2]))
        }
        try data.write(to: url, options: .atomic)
    }

    // OBJ (our own format) re-import, used to display LiDAR scans.
    static func readOBJ(url: URL) -> MeshData? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var mesh = MeshData()
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard let tag = parts.first else { continue }
            if tag == "v", parts.count >= 4,
               let x = Float(parts[1]), let y = Float(parts[2]), let z = Float(parts[3]) {
                mesh.positions.append(SIMD3<Float>(x, y, z))
            } else if tag == "f", parts.count >= 4 {
                let ids = parts[1...].compactMap { UInt32($0.split(separator: "/").first ?? "") }
                guard ids.count >= 3 else { continue }
                for k in 1..<(ids.count - 1) { // fan-triangulate
                    mesh.indices.append(contentsOf: [ids[0] - 1, ids[k] - 1, ids[k + 1] - 1])
                }
            }
        }
        return mesh
    }

    /// SceneKit node for viewing (positions kept in metres).
    func makeNode(color: UIColor = UIColor(white: 0.82, alpha: 1)) -> SCNNode {
        let vSource = SCNGeometrySource(vertices: positions.map { SCNVector3($0.x, $0.y, $0.z) })
        // Smooth-ish normals for nicer shading
        var normals = [SIMD3<Float>](repeating: .zero, count: positions.count)
        for t in 0..<triangleCount {
            let i0 = Int(indices[t * 3]), i1 = Int(indices[t * 3 + 1]), i2 = Int(indices[t * 3 + 2])
            let n = simd_cross(positions[i1] - positions[i0], positions[i2] - positions[i0])
            normals[i0] += n; normals[i1] += n; normals[i2] += n
        }
        let nSource = SCNGeometrySource(normals: normals.map {
            let l = simd_length($0); let u = l > 0 ? $0 / l : SIMD3<Float>(0, 1, 0)
            return SCNVector3(u.x, u.y, u.z)
        })
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [vSource, nSource], elements: [element])
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .physicallyBased
        m.roughness.contents = 0.55
        m.isDoubleSided = true
        geo.materials = [m]
        return SCNNode(geometry: geo)
    }
}

private func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
    var v = value.littleEndian
    withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
}

private func appendLE(_ data: inout Data, _ value: Float) {
    appendLE(&data, value.bitPattern)
}
