import AppKit
import UniformTypeIdentifiers
import WebKit
import ThumbnailCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var progressWindow: ProgressWindow?
    private let manager = FileManager.default
    private var queue: [URL] = []
    private var nextIndex = 0
    private var knownFiles = Set<URL>()
    private var activeFiles = Set<URL>()
    private var inFlight: [URL: Task<RasterIcon, Error>] = [:]
    private var batchID = UUID()
    private var task: Task<Void, Never>?
    private var results: [URL: FileResult] = [:]
    private var interruptSource: DispatchSourceSignal?
    private var exitTask: Task<Void, Never>?
    private var receivedFiles = false
    private var refresh = false
    // AppKit can turn bare command-line paths into open-files Apple events,
    // including option values. CLI mode owns parsing and must ignore those events.
    private let commandLine = CommandLine.arguments.dropFirst().first == "--generate"
    private var timeout: TimeInterval = 25
    private var reportURL: URL?

    private var cacheDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["WEBLOC_THUMBNAILS_CACHE_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return manager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.behlock.webloc-thumbnails", isDirectory: true)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--register-services"] {
            NSUpdateDynamicServices()
            NSApp.terminate(nil)
            return
        }
        if arguments.first == "--generate" {
            signal(SIGINT, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.cancelGeneration() } }
            source.resume()
            interruptSource = source
            do {
                let paths = try parseArguments(Array(arguments.dropFirst()))
                guard !paths.isEmpty else { throw ThumbnailError.message("Pass at least one .webloc file after --generate.") }
                enqueue(paths)
            } catch {
                FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                Darwin.exit(2)
            }
        } else {
            // A Service invocation can launch us before delivering its file URLs.
            // Delay the picker so service launches never flash an open dialog.
            exitTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 900_000_000) } catch { return }
                guard let self, !self.receivedFiles else { return }
                self.chooseFiles()
            }
        }
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        if !commandLine { enqueue(filenames.map { URL(fileURLWithPath: $0) }) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag || task != nil { progressWindow?.showWindow(nil) }
        else { chooseFiles() }
        return true
    }

    @objc func generateThumbnails(_ pasteboard: NSPasteboard, userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        var urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if urls.isEmpty, let paths = pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String] {
            urls = paths.map { URL(fileURLWithPath: $0) }
        }
        guard urls.contains(where: { $0.pathExtension.lowercased() == "webloc" }) else {
            error.pointee = "Select .webloc files in Finder first." as NSString
            return
        }
        receivedFiles = true
        exitTask?.cancel()
        // Return to Finder before constructing UI or starting generation.
        Task { @MainActor [weak self] in self?.enqueue(urls) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = "Choose website shortcuts"
        panel.message = "Select .webloc files to give them website preview icons."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.init(filenameExtension: "webloc")!]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { NSApp.terminate(nil); return }
        enqueue(panel.urls)
    }

    private func enqueue(_ urls: [URL]) {
        receivedFiles = true
        exitTask?.cancel()
        if task == nil {
            results = [:]; queue = []; nextIndex = 0; knownFiles = []; activeFiles = []
            inFlight = [:]; batchID = UUID()
        }
        var added: [URL] = []
        for url in urls {
            let normalized = url.standardizedFileURL
            if knownFiles.insert(normalized).inserted { added.append(normalized) }
        }
        queue.append(contentsOf: added)
        guard task == nil else {
            progressWindow?.add(files: added)
            return
        }
        if !commandLine {
            progressWindow?.close()
            progressWindow = ProgressWindow(files: queue)
            progressWindow?.onCancel = { [weak self] in self?.cancelGeneration() }
            NSApp.activate(ignoringOtherApps: true)
        }
        task = Task { [weak self] in await self?.runQueue() }
    }

    private func runQueue() async {
        let id = batchID
        let worker = IconWorker(cacheDirectory: cacheDirectory)
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let captures = (0..<2).map { _ in PageCapture(dataStore: dataStore) }
        // Bound WebKit's CPU/memory use. File/image/icon work is separately
        // serialized, as required by NSWorkspace's setIcon contract.
        await withTaskGroup(of: Void.self) { group in
            for capture in captures {
                group.addTask { [weak self] in
                    await self?.runWorker(capture, worker: worker)
                }
            }
        }
        let cancelled = Task.isCancelled
        for file in queue where results[file] == nil {
            results[file] = FileResult(file: file, status: .cancelled)
        }
        let report = RunReport(results: queue.compactMap { results[$0] }, cancelled: cancelled)
        progressWindow?.finish(report)
        // New Service requests may start another batch while this batch's
        // background cache cleanup/report write finishes.
        task = nil
        var reportFailed = false
        do {
            let url = reportURL ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Webloc Thumbnails/last-run.json")
            try await worker.finish(report: report, at: url)
        } catch {
            reportFailed = true
            FileHandle.standardError.write(Data(("Couldn’t save the report: \(error.localizedDescription)\n").utf8))
        }
        guard batchID == id else { return }
        if commandLine {
            if let data = try? report.data() { FileHandle.standardOutput.write(data + Data([10])) }
            Darwin.exit(cancelled ? 130 : reportFailed || !report.failures.isEmpty ? 1 : 0)
        }
        if !cancelled, report.failures.isEmpty {
            exitTask = Task {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { return }
                NSApp.terminate(nil)
            }
        }
    }

    private func runWorker(_ capture: PageCapture, worker: IconWorker) async {
        while !Task.isCancelled, nextIndex < queue.count {
            let file = queue[nextIndex]
            nextIndex += 1
            activeFiles.insert(file)
            refreshProgress(file)
            do {
                let loaded = try await worker.load(file, refresh: refresh)
                try Task.checkCancellation()
                let icon: RasterIcon
                let cached: Bool
                if let existing = loaded.icon {
                    icon = existing
                    cached = true
                } else {
                    (icon, cached) = try await sharedIcon(for: loaded.document.websiteURL, capture: capture, worker: worker)
                }
                try Task.checkCancellation()
                try await worker.apply(icon, to: loaded.document)
                progressWindow?.didGenerate(NSImage(cgImage: icon.image, size: NSSize(width: 512, height: 512)), for: file)
                results[file] = FileResult(file: file, status: .success, cached: cached)
            } catch is CancellationError {
                results[file] = FileResult(file: file, status: .cancelled)
            } catch {
                results[file] = FileResult(file: file, status: .failed, message: error.localizedDescription)
            }
            activeFiles.remove(file)
            if let active = activeFiles.first { refreshProgress(active) }
        }
    }

    private func sharedIcon(for url: URL, capture: PageCapture, worker: IconWorker) async throws -> (RasterIcon, Bool) {
        if let existing = inFlight[url] { return (try await existing.value, true) }
        let captureTimeout = timeout
        let render = Task { @MainActor in
            let screenshot = try await capture.capture(url, timeout: captureTimeout)
            try Task.checkCancellation()
            return try await worker.prepare(screenshot: screenshot, websiteURL: url)
        }
        inFlight[url] = render
        defer { inFlight.removeValue(forKey: url) }
        return (try await render.value, false)
    }

    private func refreshProgress(_ file: URL) {
        progressWindow?.update(file: file, completed: results.count, total: knownFiles.count, activeFiles: activeFiles)
    }

    private func cancelGeneration() {
        guard task != nil else { return }
        progressWindow?.cancelling()
        task?.cancel()
        inFlight.values.forEach { $0.cancel() }
    }

    private func parseArguments(_ arguments: [String]) throws -> [URL] {
        var paths: [URL] = []
        var index = 0
        var literalPaths = false
        while index < arguments.count {
            let value = arguments[index]
            if literalPaths { paths.append(URL(fileURLWithPath: value)); index += 1; continue }
            switch value {
            case "--": literalPaths = true
            case "--refresh": refresh = true
            case "--report", "--timeout":
                index += 1
                guard index < arguments.count else { throw ThumbnailError.message("Missing value for \(value).") }
                if value == "--report" { reportURL = URL(fileURLWithPath: arguments[index]) }
                else {
                    guard let seconds = Double(arguments[index]), seconds.isFinite, seconds >= 1, seconds <= 120 else {
                        throw ThumbnailError.message("Timeout must be between 1 and 120 seconds.")
                    }
                    timeout = seconds
                }
            default:
                guard !value.hasPrefix("--") else { throw ThumbnailError.message("Unknown option: \(value)") }
                paths.append(URL(fileURLWithPath: value))
            }
            index += 1
        }
        return paths
    }
}
