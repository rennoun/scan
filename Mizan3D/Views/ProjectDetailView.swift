import SwiftUI

struct ProjectDetailView: View {
    let projectID: UUID

    @EnvironmentObject private var store: ProjectStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewer = ViewerController()
    @StateObject private var recon = ReconstructionModel()

    @State private var share: ShareItem?
    @State private var busyText: String?
    @State private var errorText: String?
    @State private var showScaleAlert = false
    @State private var realLengthText = ""
    @State private var showRename = false
    @State private var newName = ""
    @State private var confirmDelete = false
    @State private var loadedModelURL: URL?

    private var project: ScanProject? { store.project(id: projectID) }

    var body: some View {
        Group {
            if let project {
                content(project)
            } else {
                Text("Scan not found").foregroundStyle(.secondary)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(project?.name ?? "Scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename", systemImage: "pencil") {
                        newName = project?.name ?? ""
                        showRename = true
                    }
                    Button("Delete scan", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $share) { item in ShareSheet(urls: item.urls) }
        .alert("Set real length", isPresented: $showScaleAlert) {
            TextField("Real length in mm", text: $realLengthText).keyboardType(.decimalPad)
            Button("Apply") { applyRealLength() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(String(format: "Measured: %.2f mm. Type the true distance (e.g. 100 for the mat's scale bar). The whole model will be rescaled.", viewer.distanceMM ?? 0))
        }
        .alert("Rename", isPresented: $showRename) {
            TextField("Name", text: $newName)
            Button("Save") {
                if var p = project, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    p.name = newName
                    store.save(p)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this scan and all its photos?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = project { store.delete(p) }
                dismiss()
            }
        }
        .alert("Error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .onAppear { loadModelIfNeeded() }
        .onChange(of: project?.status) { _, _ in loadModelIfNeeded() }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ p: ScanProject) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if p.status == .ready {
                    viewerCard(p)
                    exportCard(p)
                } else {
                    buildCard(p)
                }
                if p.imageCount > 0 { photosCard(p) }
                infoCard(p)
            }
            .padding()
        }
        .overlay {
            if let busyText {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    ProgressView(busyText).padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }

    private func viewerCard(_ p: ScanProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .top) {
                ModelViewer(controller: viewer)
                    .frame(height: 400)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                if !viewer.isLoaded {
                    ProgressView().frame(height: 400)
                }
                if let d = viewer.distanceMM {
                    Text(String(format: "%.2f mm", d))
                        .font(.title3.monospacedDigit().weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                } else if viewer.measuring {
                    Text("Tap two points on the model")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                }
            }
            HStack(spacing: 10) {
                Toggle(isOn: $viewer.measuring) {
                    Label("Measure", systemImage: "ruler")
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)

                Button {
                    realLengthText = ""
                    showScaleAlert = true
                } label: { Label("Set real length", systemImage: "arrow.left.and.right") }
                .buttonStyle(.bordered)
                .disabled(viewer.distanceMM == nil)

                if p.scaleFactor != 1 {
                    Button("Reset") { applyScale(1) }.buttonStyle(.bordered)
                }
            }
            .font(.footnote.weight(.semibold))
            if viewer.isLoaded {
                let s = viewer.sizeMM
                Text(String(format: "Size: %.1f × %.1f × %.1f mm  ·  %@%@", s.x, s.y, s.z, viewer.stats,
                            p.scaleFactor != 1 ? String(format: "  ·  scale ×%.4f", p.scaleFactor) : ""))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let e = viewer.loadError {
                Text(e).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func exportCard(_ p: ScanProject) -> some View {
        card(title: "Export", subtitle: "Mesh exports are in millimetres, with your scale correction applied.") {
            HStack(spacing: 10) {
                ForEach(MeshData.Format.allCases) { f in
                    Button(f.label) { exportMesh(f, p) }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                }
                if let url = store.modelURL(for: p), url.pathExtension == "usdz" {
                    Button("USDZ") { share = ShareItem(urls: [url]) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    @ViewBuilder
    private func buildCard(_ p: ScanProject) -> some View {
        card(title: "Build the 3D model",
             subtitle: "Runs on your iPhone (a few minutes, keep the app open). For maximum detail, export the photos and process them on a Mac or PC instead.") {
            if recon.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: recon.progress)
                    HStack {
                        Text(verbatim: "\(recon.stage)  \(Int(recon.progress * 100))%")
                            .font(.footnote.monospacedDigit())
                        Spacer()
                        Button("Cancel", role: .destructive) { recon.cancel() }.font(.footnote)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if p.mode == .object {
                        Button {
                            recon.run(projectID: p.id, store: store)
                        } label: {
                            Label(p.status == .failed ? "Try again" : "Build 3D model", systemImage: "cube.transparent")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                        .disabled(p.imageCount == 0)
                    } else {
                        Text("This LiDAR scan has no saved mesh.").font(.footnote)
                    }
                    if let e = recon.errorText ?? p.lastError {
                        Text(e).font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func photosCard(_ p: ScanProject) -> some View {
        card(title: "\(p.imageCount) photos",
             subtitle: "HEIC with depth and gravity data. Use them in Object Capture on a Mac (Full/Raw detail), RealityScan, Metashape or COLMAP.") {
            Button {
                exportPhotos(p)
            } label: { Label("Export photos (.zip)", systemImage: "photo.stack") }
            .buttonStyle(.bordered)
        }
    }

    private func infoCard(_ p: ScanProject) -> some View {
        card(title: "Details", subtitle: nil) {
            VStack(alignment: .leading, spacing: 4) {
                row("Mode", p.mode.title)
                row("Created", p.createdAt.formatted(date: .abbreviated, time: .shortened))
                row("Status", p.status.rawValue.capitalized)
                if let url = store.modelURL(for: p) {
                    row("Model file", "\(url.lastPathComponent) · \(FileUtils.sizeString(of: url))")
                }
            }
            .font(.footnote)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v) }
    }

    private func card<Content: View>(title: String, subtitle: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    // MARK: Actions

    private func loadModelIfNeeded() {
        guard let p = project, p.status == .ready, let url = store.modelURL(for: p) else { return }
        guard loadedModelURL != url else { return }
        loadedModelURL = url
        viewer.load(url: url, scale: p.scaleFactor)
    }

    private func applyRealLength() {
        let text = realLengthText.replacingOccurrences(of: ",", with: ".")
        guard let real = Double(text), real > 0, let measured = viewer.distanceMM, measured > 0,
              let p = project else {
            errorText = "Enter a valid length in mm."
            return
        }
        applyScale(p.scaleFactor * real / measured)
    }

    private func applyScale(_ s: Double) {
        guard var p = project else { return }
        p.scaleFactor = s
        store.save(p)
        viewer.setScale(s)
        Log.i(String(format: "Scale factor set to %.5f", s))
    }

    private func exportMesh(_ format: MeshData.Format, _ p: ScanProject) {
        let dir = store.exportsFolder(for: p)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(FileUtils.safeName(p.name))_mm.\(format.rawValue)")
        busyText = "Exporting \(format.label)…"
        let viewer = self.viewer
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let mesh = try viewer.exportMesh(format, to: url)
                DispatchQueue.main.async {
                    busyText = nil
                    Log.i("Exported \(format.label): \(mesh.triangleCount) triangles, \(FileUtils.sizeString(of: url))")
                    share = ShareItem(urls: [url])
                }
            } catch {
                DispatchQueue.main.async {
                    busyText = nil
                    errorText = error.localizedDescription
                }
            }
        }
    }

    private func exportPhotos(_ p: ScanProject) {
        let src = store.imagesFolder(for: p)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(FileUtils.safeName(p.name))_photos.zip")
        busyText = "Zipping \(p.imageCount) photos…"
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try FileUtils.zipFolder(src, to: dest)
                DispatchQueue.main.async {
                    busyText = nil
                    share = ShareItem(urls: [dest])
                }
            } catch {
                DispatchQueue.main.async {
                    busyText = nil
                    errorText = error.localizedDescription
                }
            }
        }
    }
}
