import SwiftUI
import AppKit

@main
struct MSeriesVideoConverterApp: App {
    @StateObject private var model = ConverterModel()

    var body: some Scene {
        WindowGroup("M-Series Video Converter") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}

struct ContentView: View {
    @ObservedObject var model: ConverterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("M-Series Video Converter").font(.largeTitle.bold())
                Text("iPhone-Videos platzsparend als HEVC 1080p sichern – mit Aufnahmezeit, GPS und HDR.")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                VStack(spacing: 12) {
                    FolderRow(title: "Quellordner", path: model.sourcePath, action: model.chooseSource)
                    Divider()
                    FolderRow(title: "Zielordner", path: model.destinationPath, action: model.chooseDestination)
                }.padding(4)
            }

            HStack {
                Stepper("Parallele Konvertierungen: \(model.jobs)", value: $model.jobs, in: 1...4)
                    .disabled(model.isRunning)
                Spacer()
                Button("Zielordner öffnen") { model.openDestination() }
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
                    Label("\(model.succeeded) erfolgreich", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Label("\(model.failed) Fehler", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(model.failed == 0 ? Color.secondary : Color.orange)
                }.font(.callout)
            }

            GroupBox("Protokoll") {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.logText.isEmpty ? "Bereit." : model.logText)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("bottom")
                    }
                    .onChange(of: model.logText) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }.frame(minHeight: 145)
            }

            HStack {
                Text("Originaldateien werden nie verändert.").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                if model.isRunning {
                    Button("Stoppen", role: .destructive) { model.stop() }
                } else {
                    Button("Konvertierung starten") { model.start() }
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
                Text(path.isEmpty ? "Noch nicht ausgewählt" : path)
                    .foregroundStyle(path.isEmpty ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button("Auswählen …", action: action)
        }
    }
}

@MainActor
final class ConverterModel: ObservableObject {
    @Published var sourcePath = ""
    @Published var destinationPath = ""
    @Published var jobs = 2
    @Published var isRunning = false
    @Published var total = 0
    @Published var completed = 0
    @Published var succeeded = 0
    @Published var failed = 0
    @Published var statusText = "Bereit"
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

    func start() {
        guard canStart else { return }
        guard sourcePath != destinationPath else { statusText = "Quelle und Ziel müssen verschieden sein"; return }
        guard let engine = engineURL() else { statusText = "Konvertierungs-Engine nicht gefunden"; return }

        total = 0; completed = 0; succeeded = 0; failed = 0
        logText = ""; outputBuffer = ""; isRunning = true; statusText = "Vorbereitung …"

        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [engine.path, "--source", sourcePath, "--destination", destinationPath, "--jobs", String(jobs)]
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
                    self.statusText = "Gestoppt"
                } else if finished.terminationStatus == 0 {
                    self.statusText = self.failed == 0 ? "Fertig" : "Fertig mit Fehlern"
                } else {
                    self.statusText = self.failed > 0 ? "Fertig mit Fehlern" : "Abgebrochen"
                }
            }
        }

        do {
            try task.run()
            process = task
            statusText = "Konvertierung läuft"
        } catch {
            isRunning = false
            statusText = "Start fehlgeschlagen"
            appendLog("FEHLER: \(error.localizedDescription)")
        }
    }

    func stop() { statusText = "Wird gestoppt …"; process?.interrupt() }

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
                statusText = "Videos werden erfasst …"
                if fields.count > 1, let found = Int(fields[1]) { total = found }
            }
            return
        }
        completed = Int(fields[1]) ?? completed
        total = Int(fields[2]) ?? total
        succeeded = Int(fields[3]) ?? succeeded
        failed = Int(fields[4]) ?? failed
        statusText = "Konvertierung läuft"
    }

    private func appendLog(_ line: String) {
        logText += (logText.isEmpty ? "" : "\n") + line
        if logText.count > 80_000 { logText.removeFirst(logText.count - 60_000) }
    }
}
