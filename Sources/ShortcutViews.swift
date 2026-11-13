import AppKit

/// A single shortcut hint: modifier glyphs followed by the menu command name.
final class ShortcutChipView: NSScrubberItemView {
    private let keys = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 7

        keys.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
        keys.textColor = .white
        keys.lineBreakMode = .byTruncatingTail
        keys.setContentHuggingPriority(.required, for: .horizontal)
        keys.translatesAutoresizingMaskIntoConstraints = false
        addSubview(keys)

        name.font = .systemFont(ofSize: 12, weight: .regular)
        name.textColor = NSColor.white.withAlphaComponent(0.72)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        addSubview(name)

        NSLayoutConstraint.activate([
            keys.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            keys.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: keys.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            name.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ shortcut: AppShortcut) {
        keys.stringValue = shortcut.display
        keys.alignment = .left
        name.stringValue = shortcut.title
        name.isHidden = false
    }

    func showPlaceholder(_ text: String) {
        keys.stringValue = text
        keys.alignment = .center
        name.stringValue = ""
        name.isHidden = true
    }
}

/// Scrollable strip of the frontmost app's menu shortcuts. Tapping one presses
/// the corresponding menu item.
final class ShortcutScrubberView: NSView, NSScrubberDataSource, NSScrubberDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("TouchBarPal.shortcuts")

    private let scrubber = NSScrubber()
    private var entries: [AppShortcut] = []
    private var placeholder: String?
    private var needsPermission = false

    var onPick: ((AppShortcut) -> Void)?
    var onPermissionTap: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        let layout = NSScrubberFlowLayout()
        layout.itemSize = NSSize(width: 158, height: 30)
        layout.itemSpacing = 4

        scrubber.frame = bounds
        scrubber.autoresizingMask = [.width, .height]
        scrubber.scrubberLayout = layout
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.mode = .free
        scrubber.itemAlignment = .none
        scrubber.showsAdditionalContentIndicators = true
        scrubber.selectionBackgroundStyle = nil
        scrubber.register(ShortcutChipView.self, forItemIdentifier: Self.itemIdentifier)
        addSubview(scrubber)

        DispatchQueue.main.async { [weak self] in self?.disableElasticity() }
    }

    func show(_ shortcuts: [AppShortcut], placeholder: String? = nil, needsPermission: Bool = false) {
        entries = shortcuts
        self.placeholder = placeholder
        self.needsPermission = needsPermission
        scrubber.reloadData()
        scrubber.selectedIndex = -1
    }

    private func disableElasticity() {
        func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView {
                scrollView.horizontalScrollElasticity = .none
                scrollView.verticalScrollElasticity = .none
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(scrubber)
    }

    override func layout() {
        super.layout()
        disableElasticity()
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        max(entries.count, 1)
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: Self.itemIdentifier, owner: nil) as! ShortcutChipView
        if entries.isEmpty {
            view.showPlaceholder(placeholder ?? "暂无快捷键")
        } else {
            view.show(entries[index])
        }
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        if entries.isEmpty {
            if needsPermission { onPermissionTap?() } else { NSSound.beep() }
        } else if index < entries.count {
            onPick?(entries[index])
        }
        DispatchQueue.main.async { scrubber.selectedIndex = -1 }
    }
}
