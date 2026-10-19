import AppKit

// Adapted from figma-finder-bridge's panel tokens and native controls.
@MainActor
enum PanelStyle {
    static let background = adaptive(light: 0.995, dark: 0.105)
    static let surface = adaptive(light: 0.965, dark: 0.16)
    static let border = NSColor(name: "Panel border") { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.09 : 0.045)
    }
    private static func adaptive(light: CGFloat, dark: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(white: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light, alpha: 1)
        }
    }
    static func label(_ text: String, size: CGFloat = 13,
                      color: NSColor = .labelColor, wrapping: Bool = false) -> NSTextField {
        let label = wrapping ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    static func surface(around content: NSView) -> NSView {
        let view = PanelSurface(color: surface, radius: 14, bordered: true)
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12)
        ])
        return view
    }
}

@MainActor
final class PanelSurface: NSView {
    private let color: NSColor
    private let radius: CGFloat
    private let bordered: Bool
    init(color: NSColor, radius: CGFloat, bordered: Bool = false) {
        self.color = color; self.radius = radius; self.bordered = bordered
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: bordered ? 0.5 : 0, dy: bordered ? 0.5 : 0),
            xRadius: radius, yRadius: radius)
        color.setFill(); shape.fill()
        if bordered { PanelStyle.border.setStroke(); shape.lineWidth = 1; shape.stroke() }
    }
}

@MainActor
class PointingHandButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(visibleRect, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        super.updateTrackingAreas()
        let area = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); hoverTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }
    override func mouseMoved(with event: NSEvent) { (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); NSCursor.arrow.set() }
}

@MainActor
final class PanelPillButton: PointingHandButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = .systemFont(ofSize: 14)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        (isHighlighted ? NSColor.quaternaryLabelColor : PanelStyle.surface).setFill(); shape.fill()
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? .systemFont(ofSize: 14), .foregroundColor: contentTintColor ?? NSColor.labelColor,
            .paragraphStyle: paragraph
        ])
        text.draw(in: NSRect(x: 10, y: bounds.midY - text.size().height / 2, width: bounds.width - 20, height: text.size().height))
    }
}

@MainActor
final class CircularStatusView: NSView {
    enum Phase { case processing, success, failed, cancelled }
    private let spinner = NSProgressIndicator()
    var phase: Phase = .processing {
        didSet {
            if phase == .processing { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
            needsDisplay = true
        }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        spinner.startAnimation(nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let ink: NSColor = phase == .failed ? .systemRed : phase == .cancelled ? .secondaryLabelColor : .systemBlue
        ink.withAlphaComponent(0.10).setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
        ink.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 6, dy: 6)).fill()
        let symbol: String
        switch phase {
        case .processing: return
        case .success: symbol = "checkmark"
        case .failed: symbol = "exclamationmark"
        case .cancelled: symbol = "xmark"
        }
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium).applying(.init(paletteColors: [.white])))?
            .draw(in: NSRect(x: bounds.midX - 10, y: bounds.midY - 10, width: 20, height: 20))
    }
}

@MainActor
final class BatchProgressBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true; setAccessibilityValue(fraction) } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Batch progress")
        setAccessibilityMinValue(0)
        setAccessibilityMaxValue(1)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
        NSColor.systemBlue.setFill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * max(0, min(1, fraction)), height: bounds.height)
        NSBezierPath(roundedRect: filled, xRadius: 2, yRadius: 2).fill()
    }
}
