// PDF Compress — drop PDFs on the window or the app icon; a compressed copy
// is written next to each original as "<name>-c.pdf" using Ghostscript.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Quality presets (Ghostscript -dPDFSETTINGS)

enum Quality: String, CaseIterable, Identifiable {
    case screen, ebook, printer
    var id: String { rawValue }
    var label: String {
        switch self {
        case .screen: return "Small"
        case .ebook: return "Medium"
        case .printer: return "High"
        }
    }
    var detail: String {
        switch self {
        case .screen: return "Images at 72 dpi. Smallest files, fine for on-screen reading only."
        case .ebook: return "Images at 150 dpi. Good balance for sharing and reading."
        case .printer: return "Images at 300 dpi. Larger files, suitable for printing."
        }
    }
    static var current: Quality {
        Quality(rawValue: UserDefaults.standard.string(forKey: "quality") ?? "") ?? .ebook
    }
}

// MARK: - Jobs

final class Job: ObservableObject, Identifiable {
    enum State {
        case running
        case done(output: URL, before: Int64, after: Int64)
        case noSavings(before: Int64, after: Int64)
        case failed(String)
    }

    let id = UUID()
    let source: URL
    @Published var state: State

    init(source: URL, state: State = .running) {
        self.source = source
        self.state = state
    }

    var isFinished: Bool {
        if case .running = state { return false }
        return true
    }
}

final class Compressor: ObservableObject {
    static let shared = Compressor()

    @Published var jobs: [Job] = []

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    func add(_ urls: [URL], quality: Quality = .current) {
        for url in urls {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            guard exists, !isDir.boolValue, url.pathExtension.lowercased() == "pdf" else {
                jobs.insert(Job(source: url, state: .failed("Not a PDF file")), at: 0)
                continue
            }
            let job = Job(source: url)
            jobs.insert(job, at: 0)
            queue.addOperation { [weak self] in self?.compress(job, quality: quality) }
        }
    }

    func clearFinished() {
        jobs.removeAll { $0.isFinished }
    }

    // Apps launched from Finder don't inherit the shell PATH, so look in the
    // known Homebrew locations.
    static var ghostscriptPath: String? {
        ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    private func finish(_ job: Job, _ state: Job.State) {
        DispatchQueue.main.async {
            job.state = state
            self.objectWillChange.send()  // refresh list-level UI (e.g. "Clear Finished")
        }
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// "<name>-c.pdf", or "<name>-c 2.pdf", "<name>-c 3.pdf", … if taken. Never overwrites.
    private func destination(for source: URL) -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        var candidate = dir.appendingPathComponent("\(base)-c.pdf")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-c \(n).pdf")
            n += 1
        }
        return candidate
    }

    private func compress(_ job: Job, quality: Quality) {
        guard let gs = Compressor.ghostscriptPath else {
            finish(job, .failed("Ghostscript not found. Install it with: brew install ghostscript"))
            return
        }

        // Write to a private temp file first: no half-written file next to the
        // original if gs fails, and no trouble with "%" in file names (gs treats
        // "%" in the output name as a page-number pattern).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: gs)
        process.arguments = [
            "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET",
            "-sDEVICE=pdfwrite",
            "-dCompatibilityLevel=1.5",
            "-dPDFSETTINGS=/\(quality.rawValue)",
            "-sOutputFile=\(tmp.path)",
            job.source.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            finish(job, .failed("Could not start Ghostscript: \(error.localizedDescription)"))
            return
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: tmp.path) else {
            let lastLines = output.split(separator: "\n").suffix(3).joined(separator: " ")
            finish(job, .failed(lastLines.isEmpty
                ? "Ghostscript failed (exit code \(process.terminationStatus))"
                : lastLines))
            return
        }

        let before = fileSize(job.source)
        let after = fileSize(tmp)
        guard after > 0, after < before else {
            finish(job, .noSavings(before: before, after: after))
            return
        }

        let dest = destination(for: job.source)
        do {
            try FileManager.default.moveItem(at: tmp, to: dest)
            finish(job, .done(output: dest, before: before, after: after))
        } catch {
            finish(job, .failed("Could not save \(dest.lastPathComponent): \(error.localizedDescription)"))
        }
    }
}

// MARK: - UI

private func formatBytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon.frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.source.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if case let .done(output, _, _) = job.state {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([output])
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
                .accessibilityLabel("Show in Finder")
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .running:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .noSavings:
            Image(systemName: "equal.circle.fill").foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var detail: String {
        switch job.state {
        case .running:
            return "Compressing…"
        case let .done(output, before, after):
            let pct = Int((1 - Double(after) / Double(max(before, 1))) * 100)
            return "\(formatBytes(before)) → \(formatBytes(after)) (−\(pct)%) · \(output.lastPathComponent)"
        case let .noSavings(before, _):
            return "Already compact (\(formatBytes(before))). No smaller version possible, nothing saved."
        case let .failed(message):
            return message
        }
    }
}

struct ContentView: View {
    @ObservedObject private var model = Compressor.shared
    @AppStorage("quality") private var quality: String = Quality.ebook.rawValue
    @State private var isTargeted = false

    private var selected: Quality { Quality(rawValue: quality) ?? .ebook }

    var body: some View {
        VStack(spacing: 12) {
            dropZone

            VStack(spacing: 4) {
                Picker("Quality", selection: $quality) {
                    ForEach(Quality.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(selected.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !model.jobs.isEmpty {
                List(model.jobs) { JobRow(job: $0) }
                    .listStyle(.inset)
                    .frame(minHeight: 140)
                HStack {
                    Spacer()
                    Button("Clear Finished") { model.clearFinished() }
                        .disabled(!model.jobs.contains { $0.isFinished })
                }
            }

            if Compressor.ghostscriptPath == nil {
                Text("Ghostscript is missing. Install it with: brew install ghostscript")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 300)
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop PDFs here")
                .font(.title3.weight(.medium))
            Text("A compressed copy is saved next to each file as name-c.pdf")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Choose Files…", action: choose)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, minHeight: 170)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.add([url], quality: selected) }
                }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            model.add(panel.urls, quality: selected)
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    // Files dropped on the Dock/Finder icon or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        Compressor.shared.add(urls)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PDFCompressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("PDF Compress", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
