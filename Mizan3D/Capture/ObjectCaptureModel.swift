import Foundation
import RealityKit
import SwiftUI

/// Wraps Apple's ObjectCaptureSession: guided capture with LiDAR-assisted
/// bounding box, automatic shots and coverage feedback.
/// Must be created on the main thread.
@MainActor
final class ObjectCaptureModel: ObservableObject {
    enum Phase: Equatable {
        case initializing, ready, detecting, capturing, finishing, completed
        case failed(String)
    }

    let session: ObjectCaptureSession
    let project: ScanProject

    @Published var phase: Phase = .initializing
    @Published var feedback: [String] = []
    @Published var shots: Int = 0
    @Published var maxShots: Int = 0
    @Published var pass: Int = 1
    /// Auto mode: find the object, fit the box and start capturing without taps.
    @Published var autoMode = true
    @Published var countdown: Int?          // seconds before auto capture starts
    @Published var passComplete = false     // user finished an orbit

    private var autoTask: Task<Void, Never>?

    var onCompleted: (() -> Void)?

    private var tasks: [Task<Void, Never>] = []
    private var timer: Timer?
    private var started = false

    static var isSupported: Bool { ObjectCaptureSession.isSupported }

    init(project: ScanProject) {
        self.project = project
        self.session = ObjectCaptureSession()
    }

    func start() {
        guard !started else { return }
        started = true
        let store = ProjectStore.shared
        var config = ObjectCaptureSession.Configuration()
        config.checkpointDirectory = store.checkpointFolder(for: project)
        config.isOverCaptureEnabled = true
        // Listen first, then start, so the first state changes aren't missed.
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await state in self.session.stateUpdates {
                self.handle(state)
            }
        })
        tasks.append(Task { [weak self] in
            guard let self else { return }
            for await fb in self.session.feedbackUpdates {
                self.feedback = fb.map { Self.describe($0) }.sorted()
            }
        })
        session.start(imagesDirectory: store.imagesFolder(for: project), configuration: config)
        Log.i("ObjectCaptureSession started for \(project.id)")

        // Safety net: also poll the session state, in case an update is missed.
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.handle(self.session.state)
                if case .capturing = self.phase {
                    let done = self.session.userCompletedScanPass
                    if done != self.passComplete { self.passComplete = done }
                }
                self.shots = self.session.numberOfShotsTaken
                self.maxShots = self.session.maximumNumberOfInputImages
            }
        }
    }

    private var lastStateKey = ""

    private func handle(_ state: ObjectCaptureSession.CaptureState) {
        let key = String(describing: state)
        guard key != lastStateKey else { return }
        lastStateKey = key
        Log.i("Capture state -> \(key)")
        switch state {
        case .initializing: phase = .initializing
        case .ready:
            phase = .ready
            if autoMode { autoDetect() }
        case .detecting:
            phase = .detecting
            if autoMode { autoStartCapture() }
        case .capturing:
            phase = .capturing
            countdown = nil
        case .finishing: phase = .finishing
        case .completed:
            phase = .completed
            Log.i("Capture completed: \(session.numberOfShotsTaken) shots")
            stopListening()
            onCompleted?()
        case .failed(let error):
            phase = .failed(error.localizedDescription)
            Log.e("Capture failed: \(error.localizedDescription)")
            stopListening()
        @unknown default:
            Log.w("Unknown capture state: \(String(describing: state))")
        }
    }

    // MARK: Auto mode

    /// Keep trying to lock onto whatever is under the centre dot.
    private func autoDetect() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            for attempt in 0..<20 {
                guard let self, !Task.isCancelled, self.autoMode, case .ready = self.phase else { return }
                if self.session.startDetecting() {
                    Log.i("Auto: object detected (attempt \(attempt + 1))")
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// Give the user 3 s to see the box, then start capturing.
    private func autoStartCapture() {
        autoTask?.cancel()
        autoTask = Task { [weak self] in
            for n in stride(from: 3, through: 1, by: -1) {
                guard let self, !Task.isCancelled, self.autoMode, case .detecting = self.phase else {
                    self?.countdown = nil
                    return
                }
                self.countdown = n
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard let self, !Task.isCancelled, self.autoMode, case .detecting = self.phase else { return }
            self.countdown = nil
            Log.i("Auto: starting capture")
            self.session.startCapturing()
        }
    }

    /// User wants to adjust the box by hand: stop the auto countdown.
    func pauseAuto() {
        autoMode = false
        autoTask?.cancel()
        countdown = nil
    }

    func resumeAuto() {
        autoMode = true
        switch phase {
        case .ready: autoDetect()
        case .detecting: autoStartCapture()
        default: break
        }
    }

    // MARK: User actions

    func continueToDetect() {
        if !session.startDetecting() { Log.w("startDetecting returned false") }
    }

    func startCapturing() { session.startCapturing() }
    func resetBox() { session.resetDetection() }

    func newPass() {
        passComplete = false
        session.beginNewScanPass()
        pass += 1
        Log.i("New scan pass \(pass)")
    }

    func flipAndNewPass() {
        passComplete = false
        session.beginNewScanPassAfterFlip()
        pass += 1
        Log.i("New scan pass after flip \(pass)")
    }

    func finish() { session.finish() }

    func cancel() {
        session.cancel()
        stopListening()
        Log.i("Capture cancelled")
    }

    private func stopListening() {
        autoTask?.cancel()
        timer?.invalidate()
        timer = nil
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
    }

    /// Human text for feedback flags. Matched on the case name so new SDK cases don't break the build.
    private static func describe(_ f: ObjectCaptureSession.Feedback) -> String {
        let key = String(describing: f)
        let map: [String: String] = [
            "objectTooClose": "Move back a little",
            "objectTooFar": "Move closer",
            "movingTooFast": "Slow down",
            "environmentLowLight": "More light needed",
            "environmentTooDark": "Too dark",
            "outOfFieldOfView": "Keep the object in view",
            "objectNotFlippable": "Don't flip this object",
            "overCapturing": "Enough shots here, move on",
            "objectNotDetected": "Object not detected",
        ]
        return map[key] ?? key
    }
}
