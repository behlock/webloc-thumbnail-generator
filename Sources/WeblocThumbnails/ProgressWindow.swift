import AppKit
import ThumbnailCore

@MainActor
final class ProgressWindow: NSWindowController, NSWindowDelegate {
    var onCancel: (() -> Void)?
    private let heading = PanelStyle.label("Generating previews", size: 14)
    private let detail = PanelStyle.label("Preparing…", size: 12, color: .secondaryLabelColor)
    private let progress = BatchProgressBar()
    private let status = CircularStatusView()
    private let actionButton = PanelPillButton(title: "Cancel", target: nil, action: nil)
    private let preview: WebsitePreviewStrip
    private let stack = NSStackView()
    private let footer = NSStackView()
    private var running = true
    private var hasShown = false

    init(files: [URL]) {
        preview = WebsitePreviewStrip(files: files)
        let window = ThumbnailPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 310),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Webloc Thumbnails"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = PanelSurface(color: PanelStyle.background, radius: 0)
        super.init(window: window)
        window.delegate = self
        window.onEscape = { [weak self] in self?.buttonPressed() }
        window.onReturn = { [weak self] in
            if self?.running == false { self?.buttonPressed() }
        }
        preview.onSizeChange = { [weak self] in self?.fitWindow(animated: true) }
        heading.font = .systemFont(ofSize: 14, weight: .medium)
        heading.lineBreakMode = .byTruncatingMiddle
        detail.lineBreakMode = .byTruncatingMiddle
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [heading, detail, progress])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        for label in [heading, detail] { label.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true }
        progress.widthAnchor.constraint(equalTo: labels.widthAnchor).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 3).isActive = true
        let statusRow = NSStackView(views: [labels, status])
        statusRow.alignment = .centerY
        statusRow.spacing = 12
        NSLayoutConstraint.activate([
            labels.widthAnchor.constraint(equalTo: statusRow.widthAnchor, constant: -66),
            status.widthAnchor.constraint(equalToConstant: 54),
            status.heightAnchor.constraint(equalToConstant: 54)
        ])
        actionButton.target = self
        actionButton.action = #selector(buttonPressed)
        actionButton.setAccessibilityLabel("Cancel")
        actionButton.toolTip = "Cancel thumbnail generation (Escape)"
        actionButton.widthAnchor.constraint(equalToConstant: 82).isActive = true
        actionButton.heightAnchor.constraint(equalToConstant: 34).isActive = true
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(actionButton)
        footer.orientation = .horizontal

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        for view in [preview, PanelStyle.surface(around: statusRow), footer] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            window.contentView!.widthAnchor.constraint(equalToConstant: 440),
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 48)
        ])
        fitWindow()
    }

    required init?(coder: NSCoder) { nil }

    func add(files: [URL]) { preview.add(files: files) }
    func didGenerate(_ icon: NSImage, for file: URL) { preview.setImage(icon, for: file) }

    func update(file: URL, completed: Int, total: Int, activeFiles: Set<URL>) {
        heading.stringValue = file.deletingPathExtension().lastPathComponent
        detail.stringValue = "\(completed) of \(total) completed" + (activeFiles.count > 1 ? " · \(activeFiles.count) processing" : "")
        heading.toolTip = file.lastPathComponent
        progress.fraction = Double(completed) / Double(max(1, total))
        preview.setActive(file, activeFiles: activeFiles)
        if !hasShown {
            hasShown = true
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                let bounds = screen.visibleFrame
                window?.setFrameOrigin(NSPoint(x: bounds.midX - (window?.frame.width ?? 0) / 2,
                    y: bounds.midY - (window?.frame.height ?? 0) / 2))
            }
            showWindow(nil)
        }
    }

    func cancelling() {
        detail.stringValue = "Stopping…"
        actionButton.isEnabled = false
        actionButton.needsDisplay = true
    }

    func finish(_ report: RunReport) {
        running = false
        let successes = report.results.filter { $0.status == .success }.count
        let failures = report.failures
        heading.stringValue = report.cancelled ? "Cancelled" : failures.isEmpty ? "Previews ready" : "Some previews couldn’t be created"
        detail.stringValue = "\(successes) website \(successes == 1 ? "icon" : "icons") updated" + (failures.isEmpty ? "" : " · \(failures.count) failed")
        heading.toolTip = nil
        status.phase = report.cancelled ? .cancelled : failures.isEmpty ? .success : .failed
        progress.fraction = report.cancelled
            ? Double(report.results.filter { $0.status != .cancelled }.count) / Double(max(1, report.results.count))
            : 1
        preview.finish(failedFiles: Set(failures.map { URL(fileURLWithPath: $0.file) }))
        if !failures.isEmpty {
            let errors = PanelStyle.label(failures.map {
                "\(URL(fileURLWithPath: $0.file).lastPathComponent)\n\($0.message ?? "Unknown error")"
            }.joined(separator: "\n\n"), size: 12, color: .secondaryLabelColor, wrapping: true)
            errors.isSelectable = true
            // Keep large failed batches compact; the full report remains on disk.
            errors.maximumNumberOfLines = 6
            errors.lineBreakMode = .byWordWrapping
            errors.preferredMaxLayoutWidth = 368
            errors.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            errors.toolTip = failures.map { "\(URL(fileURLWithPath: $0.file).lastPathComponent): \($0.message ?? "Unknown error")" }.joined(separator: "\n")
            let surface = PanelStyle.surface(around: errors)
            stack.insertArrangedSubview(surface, at: 2)
            surface.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        footer.isHidden = true
        window?.makeFirstResponder(nil)
        fitWindow(animated: true)
    }

    private func fitWindow(animated: Bool = false) {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(stack.fittingSize.height) + 72
        guard abs(content.bounds.height - height) > 1 else { return }
        var frame = window.frame
        let delta = height - content.bounds.height
        frame.size.height += delta
        frame.origin.y -= delta / 2
        window.setFrame(frame, display: true, animate: animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if running { onCancel?(); return false }
        NSApp.terminate(nil)
        return true
    }

    @objc private func buttonPressed() {
        if running { onCancel?() } else { NSApp.terminate(nil) }
    }
}

@MainActor
private final class ThumbnailPanel: NSWindow {
    var onEscape: (() -> Void)?
    var onReturn: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func insertNewline(_ sender: Any?) { onReturn?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onReturn?() }
        else if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}
