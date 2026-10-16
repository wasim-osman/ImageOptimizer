import AppKit
import ImageOptimizerCore

/// A standard tabbed preferences window plus a quiet credit line.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private let store = SettingsStore.shared

    private let outputLocation = NSPopUpButton()
    private let folderLabel = NSTextField(labelWithString: "")
    private let suffixField = NSTextField(string: "")
    private let conflictPolicy = NSPopUpButton()

    private let encoderMode = NSSegmentedControl(labels: ["High quality", "Balanced", "Smallest", "Fit to size"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let modeCaption = NSTextField(wrappingLabelWithString: "")
    private let targetField = NSTextField(string: "")
    private let targetUnit = NSTextField(labelWithString: "MB")
    private let pngLossy = NSButton(checkboxWithTitle: "Reduce PNG colours (much smaller, near-identical)", target: nil, action: nil)

    private var metadataBoxes: [MetadataCategory: NSButton] = [:]
    private let concurrency = NSStepper()
    private let concurrencyLabel = NSTextField(labelWithString: "Automatic")
    private let preserveDates = NSButton(checkboxWithTitle: "Keep the original file's dates", target: nil, action: nil)
    private let deleteSource = NSButton(checkboxWithTitle: "Move the original to the Trash after optimising (never RAW files)", target: nil, action: nil)

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 470),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        self.init(window: window)
        window.delegate = self
        window.contentView = buildTabs()
        loadFromStore()
    }

    // MARK: - Layout

    private func buildTabs() -> NSView {
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        for (title, content) in [("General", generalTab()), ("Quality", qualityTab()), ("Metadata", metadataTab()), ("Advanced", advancedTab())] {
            let item = NSTabViewItem()
            item.label = title
            item.view = content
            tabs.addTabViewItem(item)
        }
        let credit = developerCredit()
        let container = NSView()
        container.addSubview(tabs)
        container.addSubview(credit)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            tabs.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            tabs.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            tabs.bottomAnchor.constraint(equalTo: credit.topAnchor, constant: -6),
            credit.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            credit.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            credit.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func developerCredit() -> NSView {
        let text = NSMutableAttributedString(string: "Developed by Wasim Osman",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor])
        let range = (text.string as NSString).range(of: "Wasim Osman")
        text.addAttributes([.link: URL(string: "https://github.com/wasim-osman")!, .foregroundColor: NSColor.linkColor], range: range)
        let field = NSTextField(labelWithAttributedString: text)
        field.isSelectable = true
        field.allowsEditingTextAttributes = true
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }

    private func generalTab() -> NSView {
        outputLocation.addItems(withTitles: ["Same folder as the original", "Choose a folder…"])
        outputLocation.target = self
        outputLocation.action = #selector(outputLocationChanged)
        folderLabel.font = .systemFont(ofSize: 11)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.bezelStyle = .rounded
        let folderRow = NSStackView(views: [folderLabel, choose])
        folderRow.orientation = .horizontal
        folderRow.spacing = 8
        suffixField.target = self
        suffixField.action = #selector(commitFields)
        suffixField.placeholderString = "_optimized"
        conflictPolicy.addItems(withTitles: ["Replace it", "Add a number", "Skip the image"])
        conflictPolicy.target = self
        conflictPolicy.action = #selector(commitFields)
        return grid([("Save to:", outputLocation), ("", folderRow), ("Filename suffix:", suffixField), ("If a result exists:", conflictPolicy)])
    }

    private func qualityTab() -> NSView {
        encoderMode.target = self
        encoderMode.action = #selector(modeChanged)
        modeCaption.font = .systemFont(ofSize: 11)
        modeCaption.textColor = .secondaryLabelColor
        modeCaption.preferredMaxLayoutWidth = 330
        pngLossy.target = self
        pngLossy.action = #selector(commitFields)
        pngLossy.toolTip = "Lossy PNG uses palette reduction. High quality mode never uses it: PNGs are recompressed pixel-for-pixel."
        targetField.target = self
        targetField.action = #selector(commitFields)
        targetField.alignment = .right
        targetField.placeholderString = "10"
        targetField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        targetField.toolTip = "Discord's limit is 10 MB. Decimal megabytes, so a result under it is also under 10 MiB."
        let targetRow = NSStackView(views: [targetField, targetUnit])
        targetRow.orientation = .horizontal
        targetRow.spacing = 6
        return grid([("Optimise for:", encoderMode), ("", modeCaption), ("Target size:", targetRow), ("PNG:", pngLossy)])
    }

    /// One checkbox per group of embedded metadata. Ticked means removed from the optimised copy.
    private func metadataTab() -> NSView {
        let intro = NSTextField(wrappingLabelWithString: "Choose what to remove from the optimised copy. Anything left unticked is kept. "
            + "The original file is never changed. Applies to images added from now on.")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 420
        let heading = NSTextField(labelWithString: "Remove:")
        heading.font = .boldSystemFont(ofSize: 12)

        var rows: [NSView] = [intro, heading]
        for category in MetadataCategory.allCases {
            let box = NSButton(checkboxWithTitle: category.displayName, target: self, action: #selector(commitFields))
            box.identifier = NSUserInterfaceItemIdentifier(category.rawValue)
            metadataBoxes[category] = box
            let caption = NSTextField(labelWithString: category.detail)
            caption.font = .systemFont(ofSize: 10)
            caption.textColor = .tertiaryLabelColor
            let indent = NSStackView(views: [NSView(), caption])
            indent.orientation = .horizontal
            indent.views[0].widthAnchor.constraint(equalToConstant: 18).isActive = true
            let item = NSStackView(views: [box, indent])
            item.orientation = .vertical
            item.alignment = .leading
            item.spacing = 1
            rows.append(item)
        }
        let all = NSButton(title: "Remove all", target: self, action: #selector(removeAllMetadata))
        let locationOnly = NSButton(title: "Location only", target: self, action: #selector(removeLocationOnly))
        let none = NSButton(title: "Keep all", target: self, action: #selector(keepAllMetadata))
        for b in [all, locationOnly, none] { b.bezelStyle = .rounded }
        let buttons = NSStackView(views: [all, locationOnly, none])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        rows.append(buttons)
        let note = NSTextField(wrappingLabelWithString: "Keeping metadata makes a file a little larger. The picture's rotation and colour profile are always kept.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.preferredMaxLayoutWidth = 420
        rows.append(note)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.setCustomSpacing(12, after: intro)
        stack.setCustomSpacing(12, after: rows[rows.count - 3])
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
        ])
        return container
    }

    private func setRemoved(_ removed: Set<MetadataCategory>) {
        for (category, box) in metadataBoxes { box.state = removed.contains(category) ? .on : .off }
        commitFields()
    }
    @objc private func removeAllMetadata() { setRemoved(Set(MetadataCategory.allCases)) }
    @objc private func removeLocationOnly() { setRemoved(MetadataCategory.defaultRemoved) }
    @objc private func keepAllMetadata() { setRemoved([]) }

    private func advancedTab() -> NSView {
        concurrency.minValue = 0
        concurrency.maxValue = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        concurrency.increment = 1
        concurrency.valueWraps = false
        concurrency.target = self
        concurrency.action = #selector(concurrencyChanged)
        let row = NSStackView(views: [concurrencyLabel, concurrency])
        row.orientation = .horizontal
        row.spacing = 6
        let note = NSTextField(labelWithString: "Applies to images added from now on.")
        note.font = .systemFont(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        preserveDates.target = self
        preserveDates.action = #selector(commitFields)
        deleteSource.target = self
        deleteSource.action = #selector(deleteSourceToggled)
        return grid([("Images at once:", row), ("", note), ("", preserveDates), ("", deleteSource)])
    }

    private func grid(_ rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for (title, control) in rows {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            grid.addRow(with: [label, control])
        }
        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -18),
        ])
        return container
    }

    // MARK: - Store ⇄ controls

    private static let modes: [EncoderMode] = [.highQuality, .balanced, .smallest, .fitToSize]
    private static let captions: [EncoderMode: String] = [
        .highQuality: "Visually lossless. Smaller files, with no visible change. PNGs are recompressed exactly.",
        .balanced: "Looks the same as the original at normal viewing. The best trade for most photos.",
        .smallest: "Squeezes hardest. Fine detail may soften slightly when you zoom in.",
        .fitToSize: "Keeps the best quality that fits under the target size (e.g. 10 MB for Discord), shrinking the picture only when quality alone can't. Images already under it are left alone.",
    ]

    private func loadFromStore() {
        let s = store.settings
        outputLocation.selectItem(at: [.sameAsSource, .chooseFolder].firstIndex(of: s.outputLocation) ?? 0)
        folderLabel.stringValue = s.chosenFolderPath.isEmpty ? "No folder chosen" : s.chosenFolderPath
        suffixField.stringValue = s.suffix
        conflictPolicy.selectItem(at: [.overwrite, .numberIt, .skip].firstIndex(of: s.conflictPolicy) ?? 0)
        encoderMode.selectedSegment = Self.modes.firstIndex(of: s.encoderMode) ?? 1
        modeCaption.stringValue = Self.captions[s.encoderMode] ?? ""
        pngLossy.state = s.pngLossy ? .on : .off
        targetField.stringValue = Self.formatMB(s.targetSizeMB)
        concurrency.integerValue = s.concurrency
        concurrencyLabel.stringValue = Self.concurrencyText(s.concurrency)
        for (category, box) in metadataBoxes { box.state = s.removeMetadata.contains(category) ? .on : .off }
        preserveDates.state = s.preserveDates ? .on : .off
        deleteSource.state = s.deleteSource ? .on : .off
        updateEnabledStates()
    }

    @objc private func commitFields() {
        store.update { s in
            s.outputLocation = [.sameAsSource, .chooseFolder][outputLocation.indexOfSelectedItem]
            s.suffix = suffixField.stringValue.isEmpty ? "_optimized" : suffixField.stringValue
            s.conflictPolicy = [.overwrite, .numberIt, .skip][conflictPolicy.indexOfSelectedItem]
            s.encoderMode = Self.modes[max(0, encoderMode.selectedSegment)]
            s.pngLossy = pngLossy.state == .on
            if let mb = Double(targetField.stringValue.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")), mb > 0 {
                s.targetSizeMB = min(max(mb, 0.1), 1000)
            }
            s.concurrency = concurrency.integerValue
            s.removeMetadata = Set(metadataBoxes.filter { $0.value.state == .on }.map(\.key))
            s.preserveDates = preserveDates.state == .on
            s.deleteSource = deleteSource.state == .on
        }
        updateEnabledStates()
    }

    @objc private func modeChanged() {
        commitFields()
        modeCaption.stringValue = Self.captions[store.settings.encoderMode] ?? ""
    }

    /// High quality never uses lossy PNG, so the checkbox would do nothing — grey it out and say
    /// why, rather than leave a control that silently has no effect.
    private static func formatMB(_ mb: Double) -> String {
        mb == mb.rounded() ? String(Int(mb)) : String(format: "%g", mb)
    }

    private func updateEnabledStates() {
        let fit = store.settings.encoderMode == .fitToSize
        targetField.isEnabled = fit
        targetUnit.textColor = fit ? .labelColor : .tertiaryLabelColor
        targetField.stringValue = Self.formatMB(store.settings.targetSizeMB)
        let high = store.settings.encoderMode == .highQuality
        pngLossy.isEnabled = !high
        pngLossy.toolTip = high ? "Not used in High quality mode: PNGs are always recompressed pixel-for-pixel."
                                : "Palette reduction makes PNGs much smaller with a near-identical result."
        folderLabel.textColor = store.settings.outputLocation == .chooseFolder ? .secondaryLabelColor : .tertiaryLabelColor
    }

    @objc private func outputLocationChanged() {
        commitFields()
        if store.settings.outputLocation == .chooseFolder, store.settings.chosenFolderPath.isEmpty { chooseFolder() }
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.update { $0.chosenFolderPath = url.path }
        folderLabel.stringValue = url.path
    }

    private static func concurrencyText(_ n: Int) -> String {
        n == 0 ? "Automatic (\(ProcessInfo.processInfo.activeProcessorCount) cores)" : "\(n)"
    }

    @objc private func concurrencyChanged() {
        concurrencyLabel.stringValue = Self.concurrencyText(concurrency.integerValue)
        commitFields()
    }

    /// Destructive-ish, so it confirms once on enable. (It moves to the Trash, so it is recoverable.)
    @objc private func deleteSourceToggled() {
        guard deleteSource.state == .on else { commitFields(); return }
        let alert = NSAlert()
        alert.messageText = "Move originals to the Trash?"
        alert.informativeText = "After an image is optimised successfully, the original goes to the Trash. "
            + "Images that couldn't be improved are never touched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() != .alertFirstButtonReturn { deleteSource.state = .off }
        commitFields()
    }
}
