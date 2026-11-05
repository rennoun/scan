import SwiftUI

struct LogView: View {
    @ObservedObject private var log = Log.shared
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.lines.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(line.contains("[ERR") ? Color.red : (line.contains("[WARN") ? Color.orange : Color.primary))
                                .textSelection(.enabled)
                                .id(i)
                        }
                    }
                    .padding()
                }
                .onAppear { proxy.scrollTo(log.lines.count - 1, anchor: .bottom) }
            }
            .navigationTitle("Log  ·  v\(Bundle.main.appVersion)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { log.clear() } label: { Image(systemName: "trash") }
                    Button { share = ShareItem(urls: [log.logFileURL]) } label: { Image(systemName: "square.and.arrow.up") }
                }
            }
            .sheet(item: $share) { item in ShareSheet(urls: item.urls) }
        }
    }
}

struct ScaleMatView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var share: ShareItem?

    private var matURL: URL? { Bundle.main.url(forResource: "Mizan-scale-mat-A4", withExtension: "pdf") }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("True-scale scans with the Mizan mat").font(.title2.weight(.bold))
                    Text("Object mode is already metric (LiDAR sets the scale, typically within about 1 percent). The mat improves tracking and lets you lock the scale to an exact reference.")
                    step(1, "Print the A4 mat at **Actual size** (no 'fit to page'). Check one bar with a ruler: it must be exactly 100 mm.")
                    step(2, "Glue it on a flat, stiff board. Put the part in the centre circle.")
                    step(3, "Scan in Object mode. When you adjust the capture box, stretch it to include one 100 mm bar if you want to calibrate from the mat.")
                    step(4, "In the viewer, tap **Measure**, tap both ends of the bar (or of any feature you measured with a caliper), then **Set real length**. The whole model is rescaled.")
                    Text("Coming next: automatic marker detection (coded targets) so the scale and alignment are set without tapping.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let matURL {
                        Button {
                            share = ShareItem(urls: [matURL])
                        } label: {
                            Label("Print / share the mat (PDF)", systemImage: "printer")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.black)
                    }
                }
                .padding()
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $share) { item in ShareSheet(urls: item.urls) }
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.headline).foregroundStyle(.black)
                .frame(width: 28, height: 28)
                .background(Theme.accent, in: Circle())
            Text(text)
        }
    }
}
