import SwiftUI
import AppKit

enum TargetResolution: String, CaseIterable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    case p1440 = "1440p (2K/QHD)"

    var id: String { rawValue }
    var argument: String {
        switch self {
        case .p720: "720p"
        case .p1080: "1080p"
        case .p1440: "1440p"
        }
    }
}

enum EncodingQuality: String, CaseIterable, Identifiable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case veryHigh = "Very High"

    var id: String { rawValue }
    var argument: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .veryHigh: "very-high"
        }
    }
}

@main
struct MSeriesVideoConverterApp: App {
    @StateObject private var model = ConverterModel()

    var body: some Scene {
        WindowGroup("M-Series Video Converter") {
            ContentView(model: model)
                .frame(minWidth: 760, minHeight: 680)
                .onAppear(perform: installApplicationIcon)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 920, height: 740)
    }

    private func installApplicationIcon() {
        guard let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else { return }
        NSApplication.shared.applicationIconImage = icon
    }
}

struct ContentView: View {
    @ObservedObject var model: ConverterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("M-Series Video Converter").font(.largeTitle.bold())
                    Text("Convert iPhone videos to space-saving HEVC while preserving capture time, GPS, and HDR.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                VStack(spacing: 12) {
                    FolderRow(title: "Source folder", path: model.sourcePath, action: model.chooseSource)
                    Divider()
                    FolderRow(title: "Destination folder", path: model.destinationPath, action: model.chooseDestination)
                }.padding(4)
            }

            GroupBox("Output settings") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 24) {
                        Picker("Maximum resolution", selection: $model.targetResolution) {
                            ForEach(TargetResolution.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .disabled(model.isRunning)

                        Picker("Quality", selection: $model.quality) {
                            ForEach(EncodingQuality.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .disabled(model.isRunning)
                    }
                    Text("Videos are never upscaled. Compatible HEVC files are copied without re-encoding; Apple exports HDR at up to 1080p for these presets.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(4)
            }

            HStack {
                Stepper("Parallel conversions: \(model.jobs)", value: $model.jobs, in: 1...4)
                    .disabled(model.isRunning)
                Spacer()
                Button("Clear saved state…") { model.clearSavedState() }
                    .disabled(model.destinationPath.isEmpty || model.isRunning)
                Button("Open destination") { model.openDestination() }
                    .disabled(model.destinationPath.isEmpty)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(model.statusText).font(.headline)
                    Spacer()
                    if model.total > 0 {
                        Text("\(model.completed) / \(model.total)").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                ProgressView(value: model.progress)
                HStack(spacing: 16) {
                    Label("\(model.succeeded) succeeded", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Label("\(model.failed) failed", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(model.failed == 0 ? Color.secondary : Color.orange)
                }.font(.callout)
            }

            GroupBox("Log") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logText.isEmpty ? "Ready." : model.logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .onChange(of: model.logText) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }.frame(minHeight: 145)
            }

            HStack {
                Text("Original files are never modified.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Stop", role: .destructive) { model.stop() }
                } else {
                    Button("Start conversion") { model.start() }
                        .buttonStyle(.borderedProminent).disabled(!model.canStart)
                }
            }
        }.padding(22)
    }
}

struct FolderRow: View {
    let title: String
    let path: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(path.isEmpty ? "Not selected" : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Choose…", action: action)
        }
    }
}

@MainActor
final class ConverterModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var destinationPath = ""
    @Published var jobs = 2
    @Published var targetResolution = TargetResolution.p1080
    @Published var quality = EncodingQuality.high
    @Published var isRunning = false
    @Published var total = 0
    @Published var completed = 0
    @Published var succeeded = 0
    @Published var failed = 0
    @Published var statusText = "Ready"
    @Published var logText = ""

    private var process: Process?
    private var outputBuffer = ""

    var canStart: Bool { !sourcePath.isEmpty && !destinationPath.isEmpty && !isRunning }
    var progress: Double { total > 0 ? min(1, Double(completed) / Double(total)) : 0 }

    func chooseSource() { chooseFolder { self.sourcePath = $0 } }
    func chooseDestination() { chooseFolder { self.destinationPath = $0 } }

    private func chooseFolder(assign: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { assign(url.path) }
    }

    func openDestination() {
        guard !destinationPath.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: destinationPath))
    }

    func clearSavedState() {
        guard !destinationPath.isEmpty, !isRunning else { return }

        let alert = NSAlert()
        alert.messageText = "Clear saved state?"
        alert.informativeText = "This removes hidden progress, temporary data, and diagnostic logs. Converted videos and files in Problems are not deleted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let stateURL = URL(fileURLWithPath: destinationPath)
            .appendingPathComponent(".mseries-video-converter", isDirectory: true)
        do {
            if FileManager.default.fileExists(atPath: stateURL.path) {
                try FileManager.default.removeItem(at: stateURL)
            }
            total = 0; completed = 0; succeeded = 0; failed = 0
            logText = "Saved state cleared. Converted videos were not changed."
            outputBuffer = ""
            statusText = "Saved state cleared"
        } catch {
            statusText = "Could not clear saved state"
            appendLog("ERROR: \(error.localizedDescription)")
        }
    }

    func start() {
        guard canStart else { return }
        guard sourcePath != destinationPath else { statusText = "Source and destination must be different"; return }
        guard let engine = engineURL() else { statusText = "Conversion engine not found"; return }

        total = 0; completed = 0; succeeded = 0; failed = 0
        logText = ""; outputBuffer = ""; isRunning = true; statusText = "Preparing…"

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [
            engine.path,
            "--source", sourcePath,
            "--destination", destinationPath,
            "--jobs", String(jobs),
            "--resolution", targetResolution.argument,
            "--quality", quality.argument
        ]
        task.standardOutput = pipe
        task.standardError = pipe
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        task.environment = environment

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }
        task.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                guard let self else { return }
                self.isRunning = false
                self.process = nil
                if finished.terminationReason == .uncaughtSignal {
                    self.statusText = "Stopped"
                } else if finished.terminationStatus == 0 {
                    self.statusText = self.failed == 0 ? "Finished" : "Finished with errors"
                } else {
                    self.statusText = self.failed > 0 ? "Finished with errors" : "Cancelled"
                }
            }
        }

        do {
            try task.run()
            process = task
            statusText = "Converting"
        } catch {
            isRunning = false
            statusText = "Could not start"
            appendLog("ERROR: \(error.localizedDescription)")
        }
    }

    func stop() { statusText = "Stopping…"; process?.interrupt() }

    private func engineURL() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Engine/convert_videos.sh")
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let development = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Support/Engine/convert_videos.sh")
        return FileManager.default.fileExists(atPath: development.path) ? development : nil
    }

    private func consume(_ text: String) {
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: .newlines)
        outputBuffer = lines.last ?? ""
        for line in lines.dropLast() where !line.isEmpty { appendLog(line); parseProgress(line) }
    }

    private func parseProgress(_ line: String) {
        let fields = line.split(separator: " ")
        guard fields.first == "[PROGRESS]", fields.count >= 5 else {
            if line.hasPrefix("[SCAN]") {
                statusText = "Scanning videos…"
                if fields.count > 1, let found = Int(fields[1]) { total = found }
            }
            return
        }
        completed = Int(fields[1]) ?? completed
        total = Int(fields[2]) ?? total
        succeeded = Int(fields[3]) ?? succeeded
        failed = Int(fields[4]) ?? failed
        statusText = "Converting"
    }

    private func appendLog(_ line: String) {
        logText += (logText.isEmpty ? "" : "\n") + line
        if logText.count > 80_000 { logText.removeFirst(logText.count - 60_000) }
    }
}
