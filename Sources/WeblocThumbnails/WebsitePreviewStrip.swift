import AppKit
import QuartzCore

@MainActor
final class WebsitePreviewStrip: NSView {
    var onSizeChange: (() -> Void)?
    private let scroll = NSScrollView()
    private let row = NSStackView()
    private let fade = CAGradientLayer()
    private var tilesByFile: [URL: WebsitePreviewButton] = [:]
    private var knownFiles = Set<URL>()
    private let more = MoreWebsitesView()
    private static let maximumPreviews = 32
    private var currentFiles = Set<URL>()
    private var dimensions: [NSLayoutConstraint] = []
    private var stripHeight: NSLayoutConstraint!
    private var expanded = false
    private var side: CGFloat { expanded ? 192 : 96 }

    init(files: [URL]) {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .none
        scroll.automaticallyAdjustsContentInsets = false
        scroll.wantsLayer = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        scroll.documentView = row
        addSubview(scroll)
        stripHeight = heightAnchor.constraint(equalToConstant: side)
        NSLayoutConstraint.activate([
            stripHeight,
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        add(files: files)
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }
    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    func add(files: [URL]) {
        for file in files where knownFiles.insert(file).inserted {
            // Bound both Auto Layout work and retained image memory for large
            // Finder selections. Every selected file is still processed.
            guard tilesByFile.count < Self.maximumPreviews else { continue }
            let tile = WebsitePreviewButton(file: file)
            tile.target = self
            tile.action = #selector(toggleSize(_:))
            row.addArrangedSubview(tile)
            let constraints = [tile.widthAnchor.constraint(equalToConstant: side), tile.heightAnchor.constraint(equalToConstant: side)]
            dimensions.append(contentsOf: constraints)
            NSLayoutConstraint.activate(constraints)
            tilesByFile[file] = tile
        }
        more.count = knownFiles.count - tilesByFile.count
        if more.count > 0, more.superview == nil {
            row.addArrangedSubview(more)
            let constraints = [more.widthAnchor.constraint(equalToConstant: side), more.heightAnchor.constraint(equalToConstant: side)]
            dimensions.append(contentsOf: constraints)
            NSLayoutConstraint.activate(constraints)
        }
        needsLayout = true
    }
    func setActive(_ file: URL, activeFiles: Set<URL>) {
        for changed in currentFiles.symmetricDifference(activeFiles) {
            tilesByFile[changed]?.isCurrent = activeFiles.contains(changed)
        }
        currentFiles = activeFiles
        let tile: NSView = tilesByFile[file] ?? more
        layoutSubtreeIfNeeded()
        row.scrollToVisible(tile.frame)
        updateFade()
    }
    func setImage(_ image: NSImage, for file: URL) {
        tilesByFile[file]?.thumbnail = image
    }
    func finish(failedFiles: Set<URL>) {
        for tile in tilesByFile.values {
            tile.isCurrent = false
            tile.failed = failedFiles.contains(tile.file)
        }
    }
    override func layout() {
        super.layout()
        let count = tilesByFile.count + (more.count > 0 ? 1 : 0)
        row.setFrameSize(NSSize(width: CGFloat(count) * side + CGFloat(max(0, count - 1)) * 8, height: side))
        row.layoutSubtreeIfNeeded()
        updateFade()
    }
    @objc private func toggleSize(_ sender: WebsitePreviewButton) {
        expanded.toggle()
        dimensions.forEach { $0.constant = side }
        stripHeight.constant = side
        more.cornerRadius = expanded ? 24 : 15
        tilesByFile.values.forEach {
            $0.cornerRadius = expanded ? 24 : 15
            $0.setAccessibilityHelp(expanded ? "Return to default preview size" : "Enlarge website previews")
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        let offset = max(0, min(sender.frame.midX - scroll.contentSize.width / 2, row.bounds.width - scroll.contentSize.width))
        scroll.contentView.scroll(to: NSPoint(x: offset, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        onSizeChange?()
    }
    @objc private func scrolled() { updateFade() }
    private func updateFade() {
        let width = scroll.bounds.width
        guard width > 0 else { return }
        let offset = scroll.contentView.bounds.minX
        let remaining = max(0, row.bounds.width - width - offset)
        let left = min(40, max(0, offset) * 40 / 96)
        let right = min(40, remaining * 40 / 96)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fade.frame = scroll.bounds
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.locations = [0, NSNumber(value: Double(left / width)), NSNumber(value: Double(1 - right / width)), 1]
        fade.colors = [NSColor.black.withAlphaComponent(left > 0 ? 0 : 1).cgColor,
            NSColor.black.cgColor, NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(right > 0 ? 0 : 1).cgColor]
        scroll.layer?.mask = left > 0 || right > 0 ? fade : nil
        CATransaction.commit()
    }
}

@MainActor
private final class MoreWebsitesView: NSView {
    var cornerRadius: CGFloat = 15 { didSet { needsDisplay = true } }
    var count = 0 {
        didSet { needsDisplay = true; setAccessibilityLabel("\(count) additional websites") }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        toolTip = "The remaining selected websites are processed too."
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        PanelStyle.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        let text = NSAttributedString(string: "+\(count) more", attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor
        ])
        text.draw(at: NSPoint(x: bounds.midX - text.size().width / 2, y: bounds.midY - text.size().height / 2))
    }
}

@MainActor
private final class WebsitePreviewButton: PointingHandButton {
    let file: URL
    var thumbnail: NSImage? { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 15 { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    var failed = false { didSet { needsDisplay = true } }
    init(file: URL) {
        self.file = file
        super.init(frame: .zero)
        // Start with a cheap placeholder. Cached/generated pixels arrive from
        // the background worker; never stat files or ask Icon Services here.
        isBordered = false
        focusRingType = .exterior
        title = file.lastPathComponent
        toolTip = file.lastPathComponent + "\nClick to enlarge previews"
        setAccessibilityLabel(file.lastPathComponent)
        setAccessibilityHelp("Enlarge website previews")
    }
    required init?(coder: NSCoder) { nil }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        PanelStyle.surface.setFill(); shape.fill()
        if let thumbnail {
            thumbnail.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        } else {
            let side = min(32, bounds.width * 0.5)
            NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?
                .draw(in: NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side))
        }
        if isHighlighted { NSColor.black.withAlphaComponent(0.12).setFill(); shape.fill() }
        NSGraphicsContext.restoreGraphicsState()
        if isCurrent || window?.firstResponder === self {
            (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : .systemBlue).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius, yRadius: cornerRadius)
            ring.lineWidth = 2; ring.stroke()
        }
        if failed {
            NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(paletteColors: [.white, .systemRed]))?
                .draw(in: NSRect(x: bounds.maxX - 25, y: bounds.maxY - 25, width: 20, height: 20))
        }
    }
}
