import SwiftUI
import Combine

struct LogWindow: View {
    let logURL: URL
    @State private var content: String = ""
    @State private var timer: AnyCancellable?

    var body: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(logURL.lastPathComponent).font(.system(.caption, design: .monospaced))
                Spacer()
                Button("Refresh") { reload() }
            }
            ScrollView {
                Text(content.isEmpty ? "(empty)" : content)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 480)
        .onAppear {
            reload()
            timer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect().sink { _ in reload() }
        }
        .onDisappear { timer?.cancel() }
    }

    private func reload() {
        content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
    }
}
