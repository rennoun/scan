import Foundation
import simd

/// Automatic clean-up, like "remove plane / remove noise" in Creality Scan:
/// 1. finds the flat surface the object stands on (table, floor, mat) and removes it,
/// 2. removes small floating pieces (background, dust, mat edges).
/// Works on gravity-aligned meshes (Y up), which is what ARKit and Object Capture produce.
extension MeshData {
    struct CleanReport {
        var planeRemoved = false
        var trianglesBefore = 0
        var trianglesAfter = 0
        var piecesRemoved = 0
        var summary: String {
            var parts: [String] = []
            if planeRemoved { parts.append("support surface removed") }
            if piecesRemoved > 0 { parts.append("\(piecesRemoved) floating pieces removed") }
            if parts.isEmpty { parts.append("nothing to remove") }
            return parts.joined(separator: ", ") + " · \(trianglesBefore.formatted()) → \(trianglesAfter.formatted()) triangles"
        }
    }

    func cleaned(removePlane: Bool = true, removeNoise: Bool = true) -> (MeshData, CleanReport) {
        var report = CleanReport()
        report.trianglesBefore = triangleCount
        guard !isEmpty else { return (self, report) }

        let b = bounds
        let diag = simd_length(b.max - b.min)
        var keepTri = [Bool](repeating: true, count: triangleCount)

        // 1. Support plane (RANSAC on near-horizontal planes)
        if removePlane, let plane = findSupportPlane(diagonal: diag) {
            let tol = plane.tolerance
            var removed = 0
            for t in 0..<triangleCount {
                var outside = 0  // vertices on or below the plane
                for k in 0..<3 {
                    let p = positions[Int(indices[t * 3 + k])]
                    if simd_dot(plane.normal, p) - plane.d < tol { outside += 1 }
                }
                if outside == 3 { keepTri[t] = false; removed += 1 }
            }
            report.planeRemoved = removed > 0
            Log.i("Clean: plane n=\(plane.normal) inliers=\(plane.inlierRatio) removed \(removed) tris")
        }

        // 2. Connected components; keep the big ones
        if removeNoise {
            var parent = Array(0..<positions.count)
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r] != r { r = parent[r] }
                var c = x
                while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
                return r
            }
            for t in 0..<triangleCount where keepTri[t] {
                let a = find(Int(indices[t * 3])), b2 = find(Int(indices[t * 3 + 1])), c = find(Int(indices[t * 3 + 2]))
                if a != b2 { parent[b2] = a }
                let a2 = find(a)
                if a2 != c { parent[c] = a2 }
            }
            var compTris: [Int: Int] = [:]
            var triComp = [Int](repeating: -1, count: triangleCount)
            for t in 0..<triangleCount where keepTri[t] {
                let r = find(Int(indices[t * 3]))
                triComp[t] = r
                compTris[r, default: 0] += 1
            }
            if let largest = compTris.values.max() {
                // Keep pieces at least 8 % of the largest (keeps real separate parts, drops crumbs)
                let minKeep = max(1, Int(Double(largest) * 0.08))
                let dropped = Set(compTris.filter { $0.value < minKeep }.keys)
                report.piecesRemoved = dropped.count
                if !dropped.isEmpty {
                    for t in 0..<triangleCount where keepTri[t] && dropped.contains(triComp[t]) { keepTri[t] = false }
                }
            }
        }

        // 3. Compact
        var out = MeshData()
        var remap = [Int32](repeating: -1, count: positions.count)
        for t in 0..<triangleCount where keepTri[t] {
            for k in 0..<3 {
                let v = Int(indices[t * 3 + k])
                if remap[v] < 0 {
                    remap[v] = Int32(out.positions.count)
                    out.positions.append(positions[v])
                }
                out.indices.append(UInt32(remap[v]))
            }
        }
        report.trianglesAfter = out.triangleCount
        if out.isEmpty { return (self, CleanReport(trianglesBefore: triangleCount, trianglesAfter: triangleCount)) }
        return (out, report)
    }

    private struct Plane {
        var normal: SIMD3<Float>
        var d: Float
        var tolerance: Float
        var inlierRatio: Float
    }

    /// Finds a large horizontal plane with the bulk of the model above it.
    private func findSupportPlane(diagonal: Float) -> Plane? {
        let n = positions.count
        guard n >= 50 else { return nil }
        let tol = max(0.0008, diagonal * 0.004)   // e.g. 1.2 mm for a 30 cm object
        // Work on a sample for speed
        let step = max(1, n / 20000)
        let sample = stride(from: 0, to: n, by: step).map { positions[$0] }
        var rng = SystemRandomNumberGenerator()
        var best: (normal: SIMD3<Float>, d: Float, count: Int)?

        for _ in 0..<400 {
            let a = sample[Int.random(in: 0..<sample.count, using: &rng)]
            let b = sample[Int.random(in: 0..<sample.count, using: &rng)]
            let c = sample[Int.random(in: 0..<sample.count, using: &rng)]
            var nrm = simd_cross(b - a, c - a)
            let len = simd_length(nrm)
            guard len > 1e-9 else { continue }
            nrm /= len
            if nrm.y < 0 { nrm = -nrm }            // point up
            guard nrm.y > 0.94 else { continue }   // within ~20° of horizontal
            let d = simd_dot(nrm, a)
            var count = 0
            for p in sample where abs(simd_dot(nrm, p) - d) < tol { count += 1 }
            if count > (best?.count ?? 0) { best = (nrm, d, count) }
        }
        guard let best else { return nil }
        let ratio = Float(best.count) / Float(sample.count)
        guard ratio > 0.04 else { return nil }    // too small to be a table

        // The object must be mostly ABOVE the plane, otherwise it's a top face, not a support.
        var above = 0, below = 0
        for p in sample {
            let h = simd_dot(best.normal, p) - best.d
            if h > tol { above += 1 } else if h < -tol { below += 1 }
        }
        guard above > below * 3 else { return nil }

        // A table/mat sticks out around the object; the object's own flat bottom does not.
        // So require a good share of plane points outside the footprint of the object above it.
        var lo = SIMD2<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude)
        var hi = -lo
        for p in sample where simd_dot(best.normal, p) - best.d > tol * 3 {
            lo = simd_min(lo, SIMD2(p.x, p.z)); hi = simd_max(hi, SIMD2(p.x, p.z))
        }
        var inliers = 0, outsideFootprint = 0
        for p in sample where abs(simd_dot(best.normal, p) - best.d) < tol {
            inliers += 1
            let q = SIMD2(p.x, p.z)
            if q.x < lo.x - tol || q.y < lo.y - tol || q.x > hi.x + tol || q.y > hi.y + tol { outsideFootprint += 1 }
        }
        guard inliers > 0, Float(outsideFootprint) / Float(inliers) > 0.2 else {
            Log.i("Clean: flat face found but it's the object's own base — kept")
            return nil
        }
        return Plane(normal: best.normal, d: best.d, tolerance: tol, inlierRatio: ratio)
    }
}
