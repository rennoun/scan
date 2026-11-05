import SwiftUI
import RealityKit

struct ObjectCaptureScreen: View {
    @ObservedObject var model: ObjectCaptureModel
    let onClose: (_ captured: Bool) -> Void
    @State private var showTips = true

    var body: some View {
        ZStack {
            ObjectCaptureView(session: model.session)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                topBar
                feedbackChips
                Spacer()
                if showTips, case .ready = model.phase { tipsCard }
                bottomControls
            }
            .padding()
        }
        .background(Color.black)
        .onAppear {
            model.onCompleted = { onClose(true) }
            model.start()
        }
        .statusBarHidden()
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack {
            Button {
                model.cancel()
                onClose(model.shots > 0)
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Circle())
            }
            Spacer()
            if case .capturing = model.phase {
                HStack(spacing: 6) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Pass \(model.pass)  ·  \(model.shots)\(model.maxShots > 0 ? " / \(model.maxShots)" : "") shots")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }

    private var feedbackChips: some View {
        VStack(spacing: 6) {
            ForEach(model.feedback, id: \.self) { msg in
                Text(msg)
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Color.orange.opacity(0.85), in: Capsule())
            }
        }
        .animation(.easeInOut, value: model.feedback)
    }

    private var tipsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("For best precision").font(.headline)
            Label("Put the part on the Mizan scale mat (or any textured surface)", systemImage: "square.grid.3x3")
            Label("Soft, even light — no hard shadows or reflections", systemImage: "sun.max")
            Label("Shiny or black parts: dust with scanning spray / talc", systemImage: "sparkles")
            Label("Walk slowly around it; do 2–3 passes at different heights", systemImage: "figure.walk")
            Button("Got it") { showTips = false }.padding(.top, 4)
        }
        .font(.footnote)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var bottomControls: some View {
        switch model.phase {
        case .initializing:
            ProgressView("Starting camera…").padding().background(.ultraThinMaterial, in: Capsule())
        case .ready:
            VStack(spacing: 8) {
                hint("Aim the dot at the object")
                bigButton("Continue", systemImage: "viewfinder") { model.continueToDetect() }
            }
        case .detecting:
            VStack(spacing: 8) {
                hint("Drag the box edges to fit the object")
                HStack(spacing: 12) {
                    smallButton("Reset box", systemImage: "arrow.counterclockwise") { model.resetBox() }
                    bigButton("Start capture", systemImage: "record.circle") { model.startCapturing() }
                }
            }
        case .capturing:
            VStack(spacing: 8) {
                hint("Move slowly around the object")
                HStack(spacing: 10) {
                    smallButton("New pass", systemImage: "arrow.triangle.2.circlepath") { model.newPass() }
                    smallButton("Flip object", systemImage: "arrow.up.and.down.righttriangle.up.righttriangle.down") { model.flipAndNewPass() }
                    bigButton("Finish", systemImage: "checkmark") { model.finish() }
                }
            }
        case .finishing:
            ProgressView("Saving photos…").padding().background(.ultraThinMaterial, in: Capsule())
        case .completed:
            EmptyView()
        case .failed(let msg):
            VStack(spacing: 8) {
                Text("Capture failed").font(.headline)
                Text(msg).font(.footnote).multilineTextAlignment(.center)
                bigButton("Close", systemImage: "xmark") { onClose(model.shots > 0) }
            }
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private func bigButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.black)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .background(Theme.accent, in: Capsule())
        }
    }

    private func smallButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(width: 76, height: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .foregroundStyle(.white)
    }
}
