import Foundation

/// In-app log, so we can debug on the iPhone without Xcode attached.
/// Lines are shown in the Log screen and saved to Documents/mizan-log.txt.
final class Log: ObservableObject {
    static let shared = Log()

    @Published private(set) var lines: [String] = []
    private let fileURL: URL
    private let ioQueue = DispatchQueue(label: "mizan.log")
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private init() {
        fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mizan-log.txt")
    }

    static func i(_ message: String) { shared.append("INFO", message) }
    static func w(_ message: String) { shared.append("WARN", message) }
    static func e(_ message: String) { shared.append("ERR ", message) }

    var logFileURL: URL { fileURL }

    func clear() {
        DispatchQueue.main.async { self.lines.removeAll() }
        ioQueue.async { try? Data().write(to: self.fileURL) }
    }

    private func append(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        #if DEBUG
        print(line)
        #endif
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 3000 { self.lines.removeFirst(self.lines.count - 3000) }
        }
        ioQueue.async {
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.fileURL) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: self.fileURL)
            }
        }
    }
}
