import AppKit
import QuartzCore

/// Tap feedback for an app icon: a pop when opening, a squash-and-fade when
/// minimising.
func playAppTapAnimation(on view: NSView, minimize: Bool) {
    view.wantsLayer = true
    guard let layer = view.layer else { return }

    // One clean dip, no opacity fade: a two-bounce + fade reads as a flicker.
    let scale = CAKeyframeAnimation(keyPath: "transform.scale")
    scale.values = minimize ? [1, 0.88, 1] : [1, 1.08, 1]
    scale.keyTimes = [0, 0.5, 1]
    scale.duration = 0.18
    scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
    layer.add(scale, forKey: "tapScale")
}

/// A single clipboard entry, drawn as a dark rounded chip so entries stay
/// readable against the black Touch Bar.
final class ClipChipView: NSScrubberItemView {
    private let label = NSTextField(labelWithString: "")
    private let thumbnail = NSImageView()
    private var labelLeading: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    var showsThumbnail: Bool { !thumbnail.isHidden }

    /// Empty state: no stale thumbnail or inset from a reused image cell.
    func showPlaceholder(_ message: String) {
        text = message
        thumbnail.image = nil
        thumbnail.isHidden = true
        label.alignment = .center
        labelLeading?.constant = 9
    }

    /// Image entries get a thumbnail; text entries stay label-only.
    func show(item: ClipItem) {
        text = item.preview
        if let url = ClipboardStore.shared.imageURL(for: item),
           let image = NSImage(contentsOf: url) {
            thumbnail.image = image
            thumbnail.isHidden = false
            label.alignment = .left
            labelLeading?.constant = 56
        } else {
            thumbnail.image = nil
            thumbnail.isHidden = true
            label.alignment = .center
            labelLeading?.constant = 9
        }
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 7

        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.isHidden = true
        addSubview(thumbnail)

        label.font = .systemFont(ofSize: 15, weight: .regular)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9)
        labelLeading = leading
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 44),
            thumbnail.heightAnchor.constraint(equalToConstant: 26)
        ])
    }
}

/// A bezel button whose icon fills the chip. Used for the app shortcuts on the
/// bar itself.
final class IconButton: NSButton {
    private let iconView = NSImageView()
    private let runningDot = NSView()

    var icon: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }

    var isRunning = false {
        didSet { runningDot.isHidden = !isRunning }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        title = ""
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 7

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        runningDot.wantsLayer = true
        runningDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        runningDot.layer?.cornerRadius = 2.6
        runningDot.layer?.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
        runningDot.layer?.borderWidth = 1
        runningDot.isHidden = true
        runningDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(runningDot)

        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: trailingAnchor),

            runningDot.widthAnchor.constraint(equalToConstant: 5.2),
            runningDot.heightAnchor.constraint(equalToConstant: 5.2),
            runningDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            runningDot.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, isEnabled else { return nil }
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }
}

/// An app icon with its name on a subtle chip.
final class AppChipView: NSScrubberItemView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let runningDot = NSView()

    var isRunning = false {
        didSet { runningDot.isHidden = !isRunning }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    var image: NSImage? {
        get { iconView.image }
        set { iconView.image = newValue }
    }

    var name: String {
        get { nameLabel.stringValue }
        set { nameLabel.stringValue = newValue }
    }

    private func setUp() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        layer?.cornerRadius = 7

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = .systemFont(ofSize: 11, weight: .medium)
        nameLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        nameLabel.alignment = .left
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameLabel)

        runningDot.wantsLayer = true
        runningDot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        runningDot.layer?.cornerRadius = 2.6
        runningDot.layer?.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
        runningDot.layer?.borderWidth = 1
        runningDot.isHidden = true
        runningDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(runningDot)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 21),
            iconView.heightAnchor.constraint(equalToConstant: 21),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            runningDot.widthAnchor.constraint(equalToConstant: 6),
            runningDot.heightAnchor.constraint(equalToConstant: 6),
            runningDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            runningDot.topAnchor.constraint(equalTo: topAnchor, constant: 2)
        ])
    }
}

/// Horizontal clipboard history inside a Touch Bar popover.
/// Panning scrolls; tapping an item pastes it.
final class ClipboardScrubberView: NSView, NSScrubberDataSource, NSScrubberDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("TouchBarPal.clip")

    private let scrubber = NSScrubber()
    private var entries: [ClipItem] = []
    private var isInteracting = false
    private var needsReload = false
    var onPick: ((ClipItem) -> Void)?

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
        layout.itemSize = NSSize(width: 152, height: 30)
        layout.itemSpacing = 4

        scrubber.frame = bounds
        scrubber.autoresizingMask = [.width, .height]
        scrubber.scrubberLayout = layout
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.mode = .free
        // `.none` stops the scrubber snapping the first item back to the left
        // edge when a pan reaches the start.
        scrubber.itemAlignment = .none
        scrubber.showsAdditionalContentIndicators = true
        scrubber.selectionBackgroundStyle = nil
        scrubber.register(ClipChipView.self, forItemIdentifier: Self.itemIdentifier)
        addSubview(scrubber)

        DispatchQueue.main.async { [weak self] in self?.disableElasticity() }

        entries = ClipboardStore.shared.items
    }

    /// Live clipboard changes must not yank the scrubber back to the start
    /// while the user is panning, so defer them until the gesture ends.
    func reload() {
        if isInteracting {
            needsReload = true
            return
        }
        applyReload()
    }

    private func applyReload() {
        needsReload = false
        entries = ClipboardStore.shared.items
        scrubber.reloadData()
        scrubber.selectedIndex = -1
    }

    func scrubber(_ scrubber: NSScrubber, didBeginInteractingWith scrubber2: NSScrubber) {
        isInteracting = true
    }

    func scrubber(_ scrubber: NSScrubber, didFinishInteractingWith scrubber2: NSScrubber) {
        isInteracting = false
        if needsReload { applyReload() }
    }

    func scrubber(_ scrubber: NSScrubber, didCancelInteractingWith scrubber2: NSScrubber) {
        isInteracting = false
        if needsReload { applyReload() }
    }

    /// The scrubber's internal scroll view rubber-bands at the ends, which
    /// feels like a jump-back when panning. Turn elasticity off.
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
        let view = scrubber.makeItem(withIdentifier: Self.itemIdentifier, owner: nil) as! ClipChipView
        if entries.isEmpty {
            view.showPlaceholder("暂无记录")
        } else {
            view.show(item: entries[index])
        }
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard index < entries.count else { return }
        onPick?(entries[index])
        // NSScrubber only reports a *change* of selection, so clear it and let
        // the next tap on the same chip fire again.
        DispatchQueue.main.async { scrubber.selectedIndex = -1 }
    }
}

/// Horizontal list of installed apps inside a Touch Bar popover.
final class AppScrubberView: NSView, NSScrubberDataSource, NSScrubberDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("TouchBarPal.apps")

    private let scrubber = NSScrubber()
    private var entries: [AppEntry] = []
    private var itemViews: [Int: AppChipView] = [:]
    var onPick: ((AppEntry) -> Void)?

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
        layout.itemSize = NSSize(width: 100, height: 30)
        layout.itemSpacing = 3

        scrubber.frame = bounds
        scrubber.autoresizingMask = [.width, .height]
        scrubber.scrubberLayout = layout
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.mode = .free
        scrubber.itemAlignment = .none
        scrubber.showsAdditionalContentIndicators = true
        scrubber.selectionBackgroundStyle = nil
        scrubber.register(AppChipView.self, forItemIdentifier: Self.itemIdentifier)
        addSubview(scrubber)

        DispatchQueue.main.async { [weak self] in self?.disableElasticity() }

        entries = AppCatalog.shared.visibleApps
    }

    func reload() {
        entries = AppCatalog.shared.visibleApps
        itemViews.removeAll()
        scrubber.reloadData()
        scrubber.selectedIndex = -1
    }

    /// Update the green dots without recreating item views.
    func refreshRunning() {
        let running = AppCatalog.shared.runningBundleIDs
        for (index, view) in itemViews {
            let isRunning = index < entries.count && running.contains(entries[index].bundleID)
            if view.isRunning != isRunning { view.isRunning = isRunning }
        }
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
        entries.count
    }


    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: Self.itemIdentifier, owner: nil) as! AppChipView
        view.image = entries[index].icon
        view.name = entries[index].name
        view.isRunning = AppCatalog.shared.runningBundleIDs.contains(entries[index].bundleID)
        itemViews[index] = view
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard index < entries.count else { return }
        let active = AppCatalog.shared.willMinimize(entries[index].bundleID)
        if let view = itemViews[index] {
            playAppTapAnimation(on: view, minimize: active)
        }
        onPick?(entries[index])
        // Allow tapping the same icon again (second tap minimises).
        DispatchQueue.main.async { scrubber.selectedIndex = -1 }
    }
}

/// Horizontal list of saved quick phrases inside a Touch Bar popover.
/// Tapping a phrase types it into the frontmost app.
final class QuickPhraseScrubberView: NSView, NSScrubberDataSource, NSScrubberDelegate {
    private static let itemIdentifier = NSUserInterfaceItemIdentifier("TouchBarPal.phrases")

    private let scrubber = NSScrubber()
    private var entries: [String] = []
    var onPick: ((String) -> Void)?

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
        layout.itemSize = NSSize(width: 180, height: 30)
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
        scrubber.register(ClipChipView.self, forItemIdentifier: Self.itemIdentifier)
        addSubview(scrubber)

        DispatchQueue.main.async { [weak self] in self?.disableElasticity() }
        entries = QuickPhraseStore.shared.items
    }

    func reload() {
        entries = QuickPhraseStore.shared.items
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
        let view = scrubber.makeItem(withIdentifier: Self.itemIdentifier, owner: nil) as! ClipChipView
        view.text = entries.isEmpty ? "暂无短语" : entries[index]
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt index: Int) {
        guard index < entries.count else { return }
        onPick?(entries[index])
        DispatchQueue.main.async { scrubber.selectedIndex = -1 }
    }
}
