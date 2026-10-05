import AppKit
import UniformTypeIdentifiers

/// The entire main window: a dashed target that fills it, one line of status, a hairline progress
/// bar while working, and — when idle — the lifetime savings caption.
final class DropZoneView: NSView {

    struct Display: Equatable {
        var headline: String
        var detail: String
        var progress: Double?              // nil hides the bar
        var lifetimeCaption: String = ""   // drawn in the bar's strip, only when progress is nil
    }

    var onDrop: (([URL]) -> Void)?
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var onSettingsButtonTapped: (() -> Void)?
    var onStopButtonTapped: (() -> Void)?

    private var isTargeted = false
    private var display = Display(headline: "Drop images here", detail: "", progress: nil)
    private let settingsButton = NSButton()
    private let stopButton = NSButton()
    private var pendingSingleClick: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        configure(settingsButton, symbol: "gearshape", point: 13, tint: .tertiaryLabelColor,
                  tip: "Settings", action: #selector(settingsTapped), edge: .trailing)
        configure(stopButton, symbol: "stop.circle", point: 15, tint: .systemRed,
                  tip: "Stop", action: #selector(stopTapped), edge: .leading)
        stopButton.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    /// A small borderless corner button. As a real subview it intercepts its own clicks, so it
    /// never triggers the window's click-to-reveal action.
    private func configure(_ button: NSButton, symbol: String, point: CGFloat, tint: NSColor,
                           tip: String, action: Selector, edge: NSLayoutConstraint.Attribute) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: point, weight: .regular))
        button.imageScaling = .scaleProportionallyUpOrDown
        button.contentTintColor = tint
        button.toolTip = tip
        button.target = self
        button.action = action
        addSubview(button)
        var constraints = [
            button.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            button.widthAnchor.constraint(equalToConstant: 26),
            button.heightAnchor.constraint(equalToConstant: 26),
        ]
        constraints.append(edge == .trailing
            ? button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18)
            : button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18))
        NSLayoutConstraint.activate(constraints)
    }

    @objc private func settingsTapped() { onSettingsButtonTapped?() }
    @objc private func stopTapped() { onStopButtonTapped?() }

    /// Shown only while something is running; the menu item and ⌘. work either way.
    func setStopButtonVisible(_ visible: Bool) { stopButton.isHidden = !visible }

    func show(_ new: Display) {
        guard new != display else { return }
        display = new
        needsDisplay = true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let inset = bounds.insetBy(dx: 12, dy: 12)
        let path = NSBezierPath(roundedRect: inset, xRadius: 12, yRadius: 12)
        path.lineWidth = 2
        path.setLineDash([7, 5], count: 2, phase: 0)
        if isTargeted {
            NSColor.controlAccentColor.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        path.stroke()

        let tint = isTargeted ? NSColor.controlAccentColor : NSColor.tertiaryLabelColor
        if let glyph = NSImage(systemSymbolName: "photo.badge.arrow.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .light)) {
            let size = glyph.size
            let rect = NSRect(x: bounds.midX - size.width / 2, y: bounds.midY + 14, width: size.width, height: size.height)
            glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
            tint.set()
            rect.fill(using: .sourceAtop)
        }

        draw(display.headline, font: .systemFont(ofSize: 13, weight: .medium), color: .secondaryLabelColor, baselineY: bounds.midY - 8)
        if !display.detail.isEmpty {
            draw(display.detail, font: .systemFont(ofSize: 11), color: .tertiaryLabelColor, baselineY: bounds.midY - 26)
        }

        if let progress = display.progress {
            let track = NSRect(x: inset.minX + 18, y: inset.minY + 16, width: inset.width - 36, height: 3)
            NSColor.separatorColor.setFill()
            NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
            let clamped = min(max(progress, 0), 1)
            if clamped > 0 {
                let filled = NSRect(x: track.minX, y: track.minY, width: track.width * clamped, height: track.height)
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: filled, xRadius: 1.5, yRadius: 1.5).fill()
            }
        } else if !display.lifetimeCaption.isEmpty {
            draw(display.lifetimeCaption, font: .systemFont(ofSize: 10), color: .tertiaryLabelColor, baselineY: inset.minY + 14)
        }
    }

    /// Centred text, shrunk to fit so a long filename can never run out of the window.
    private func draw(_ text: String, font: NSFont, color: NSColor, baselineY: CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingMiddle
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let width = bounds.width - 60
        (text as NSString).draw(in: NSRect(x: 30, y: baselineY, width: width, height: font.pointSize + 6), withAttributes: attrs)
    }

    // MARK: - Clicks

    /// A double click opens a file picker; a single click reveals the last output. A genuine double
    /// click still delivers a first mouseDown with clickCount 1, so the single-click action is
    /// deferred by the system double-click interval and cancelled if a second click promotes it.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            pendingSingleClick?.cancel()
            pendingSingleClick = nil
            onDoubleClick?()
            return
        }
        pendingSingleClick?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onClick?() }
        pendingSingleClick = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
    }

    // MARK: - Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        isTargeted = !imageURLs(from: sender).isEmpty
        needsDisplay = true
        return isTargeted ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { isTargeted = false; needsDisplay = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { !imageURLs(from: sender).isEmpty }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender)
        isTargeted = false
        needsDisplay = true
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func imageURLs(from sender: NSDraggingInfo) -> [URL] {
        Self.expand(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [])
    }

    /// Files stay as they are; folders are expanded one level deep. Any image is accepted — formats
    /// v1 can't optimise are refused with a reason by the queue, which beats silently ignoring a drop.
    static func expand(_ urls: [URL]) -> [URL] {
        var out: [URL] = []
        for url in urls {
            if url.hasDirectoryPath {
                let kids = (try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                out += kids.filter(isImage).sorted { $0.path < $1.path }
            } else if isImage(url) {
                out.append(url)
            }
        }
        return out
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .image)
    }
}
