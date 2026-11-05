import SwiftUI

@main
struct Mizan3DApp: App {
    @StateObject private var store = ProjectStore.shared

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .onAppear { Log.i("App started, v\(Bundle.main.appVersion)") }
        }
    }
}

enum Theme {
    static let accent = Color(red: 0.18, green: 0.85, blue: 0.76)
    static let background = Color(red: 0.04, green: 0.055, blue: 0.086)
    static let card = Color.white.opacity(0.06)
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}
