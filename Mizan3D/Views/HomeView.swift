import SwiftUI

/// A capture in progress, presented full screen.
final class ActiveCapture: Identifiable {
    let id = UUID()
    let project: ScanProject
    let objectModel: ObjectCaptureModel?
    init(project: ScanProject, objectModel: ObjectCaptureModel?) {
        self.project = project
        self.objectModel = objectModel
    }
}

struct HomeView: View {
    @EnvironmentObject private var store: ProjectStore
    @State private var path: [UUID] = []
    @State private var active: ActiveCapture?
    @State private var showLog = false
    @State private var showMat = false
    @State private var alertText: String?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    hero
                    VStack(spacing: 12) {
                        ForEach(ScanMode.allCases) { mode in
                            ModeCard(mode: mode, supported: isSupported(mode)) { startScan(mode) }
                        }
                    }
                    Button { showMat = true } label: {
                        Label("Print the Mizan scale mat for true-scale scans", systemImage: "ruler")
                            .font(.subheadline.weight(.semibold))
                    }
                    scansSection
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Mizan 3D")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showLog = true } label: { Image(systemName: "text.alignleft") }
                }
            }
            .navigationDestination(for: UUID.self) { id in
                ProjectDetailView(projectID: id)
            }
        }
        .fullScreenCover(item: $active) { capture in
            captureScreen(capture)
                .environmentObject(store)
        }
        .sheet(isPresented: $showLog) { LogView() }
        .sheet(isPresented: $showMat) { ScaleMatView() }
        .alert("Not available", isPresented: Binding(get: { alertText != nil }, set: { if !$0 { alertText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(alertText ?? "") }
    }

    // MARK: Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Precision 3D scanning")
                .font(.system(size: 30, weight: .bold, design: .rounded))
            Text("LiDAR + 48 MP photogrammetry. Measure, scale and export to STL for printing and CAD.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var scansSection: some View {
        Text("Your scans").font(.title3.weight(.bold))
        if store.projects.isEmpty {
            Text("No scans yet. Start with Object mode on a small part.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 80)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(store.projects) { p in
                    NavigationLink(value: p.id) { ProjectTile(project: p) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func captureScreen(_ capture: ActiveCapture) -> some View {
        if let model = capture.objectModel {
            ObjectCaptureScreen(model: model) { captured in finishCapture(capture.project, captured: captured) }
        } else {
            LidarScanScreen(project: capture.project) { saved in finishCapture(capture.project, captured: saved) }
        }
    }

    // MARK: Actions

    @MainActor
    private func isSupported(_ mode: ScanMode) -> Bool {
        switch mode {
        case .object: return ObjectCaptureModel.isSupported
        case .large: return LidarController.isSupported
        }
    }

    @MainActor
    private func startScan(_ mode: ScanMode) {
        guard isSupported(mode) else {
            alertText = "\(mode.title) mode needs an iPhone Pro with LiDAR (iOS 17+)."
            return
        }
        let project = store.create(mode: mode)
        let model: ObjectCaptureModel? = (mode == .object) ? ObjectCaptureModel(project: project) : nil
        active = ActiveCapture(project: project, objectModel: model)
    }

    @MainActor
    private func finishCapture(_ project: ScanProject, captured: Bool) {
        active = nil
        guard var p = store.project(id: project.id) else { return }
        store.refreshImageCount(&p)
        let hasData = p.imageCount > 0 || p.modelFileName != nil
        if !captured && !hasData {
            store.delete(p)
            return
        }
        store.save(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { path = [p.id] }
    }
}

struct ModeCard: View {
    let mode: ScanMode
    let supported: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 56, height: 56)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.headline)
                    Text(mode.subtitle).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .opacity(supported ? 1 : 0.5)
        }
        .buttonStyle(.plain)
    }
}

struct ProjectTile: View {
    @EnvironmentObject private var store: ProjectStore
    let project: ScanProject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(Color.white.opacity(0.04))
                if let img = store.thumbnail(for: project) {
                    Image(uiImage: img).resizable().scaledToFill()
                } else {
                    Image(systemName: project.mode.symbol).font(.largeTitle).foregroundStyle(.secondary)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            StatusBadge(status: project.status)
        }
    }
}

struct StatusBadge: View {
    let status: ScanStatus
    var body: some View {
        let (text, color): (String, Color) = {
            switch status {
            case .captured: return ("Photos ready", .orange)
            case .processing: return ("Processing", .blue)
            case .ready: return ("3D model", Theme.accent)
            case .failed: return ("Failed", .red)
            }
        }()
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}
