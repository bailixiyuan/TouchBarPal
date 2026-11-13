import AppKit

/// The whole main bar is one custom item. Keeping every chip in a single view
/// lets the pet be a transparent overlay above all of them instead of being
/// squeezed into a dedicated slot of its own.
final class MainBarView: NSView {
    enum Monitor: CaseIterable {
        case weather, battery, cpu, memory
    }

    let clipboardButton = MainBarView.makeChip("剪贴板", symbol: "doc.on.clipboard")
    let phraseButton = MainBarView.makeChip("快捷输入", symbol: "keyboard")
    let appsButton = MainBarView.makeChip("应用", symbol: "square.grid.2x2")
    let shortcutButton = MainBarView.makeChip("快捷键", symbol: "command")
    let petWallButton = MainBarView.makeChip("宠物墙", symbol: "pawprint.fill")

    let weatherButton = MainBarView.makeChip("—°", symbol: "cloud.sun.fill")
    let batteryButton = MainBarView.makeChip("--%", symbol: "battery.100")
    let cpuButton = MainBarView.makeChip("0%", symbol: "cpu")
    let memoryButton = MainBarView.makeChip("0%", symbol: "memorychip")

    let pet = PetRunView()

    private(set) var appButtons: [IconButton] = []
    /// Fired when the real bar width changes, so the controller can re-measure.
    var onWidthChange: (() -> Void)?
    private var slotCount = 0
    private var monitors: [Monitor] = []
    private var showPet = true

    private let maxSlots = AppSettings.maximumRecentLimit
    private let gap: CGFloat = 6
    private let appGap: CGFloat = 3
    private let appWidth: CGFloat = 28
    private let edge: CGFloat = 6
    private var lastLayoutWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        for button in [clipboardButton, phraseButton, appsButton, shortcutButton, petWallButton,
                       weatherButton, batteryButton, cpuButton, memoryButton] {
            addSubview(button)
        }

        for index in 0..<maxSlots {
            let button = IconButton(frame: NSRect(x: 0, y: 0, width: appWidth, height: appWidth))
            button.tag = index
            button.isHidden = true
            addSubview(button)
            appButtons.append(button)
        }

        pet.isHidden = true
        addSubview(pet)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 860, height: 30)
    }

    // MARK: - Content

    func configure(slots: Int, monitors: [Monitor], showPet: Bool) {
        slotCount = slots
        self.monitors = monitors
        self.showPet = showPet
        pet.isHidden = !showPet
        // A removed monitor keeps its old frame otherwise and stays drawn on
        // top of the app icons that move into its place.
        for monitor in Monitor.allCases {
            button(for: monitor).isHidden = !monitors.contains(monitor)
        }
        needsLayout = true
    }

    func setTitle(_ button: ChipButton, _ title: String) {
        button.titleText = title
        needsLayout = true
    }

    func setSymbol(_ button: ChipButton, _ name: String?) {
        guard let name else { return }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        button.icon = image
    }

    // MARK: - Layout

    /// How many recent-app icons still fit beside the fixed chips and the
    /// currently enabled monitors. Monitors are wider than icons, so an exact
    /// measurement beats reserving a guessed number of slots.
    func appCapacity(for monitors: [Monitor]) -> Int {
        var used = edge * 2
        for button in [clipboardButton, phraseButton, appsButton, shortcutButton, petWallButton] {
            used += chipWidth(button) + gap
        }
        for monitor in monitors {
            used += chipWidth(button(for: monitor)) + gap
        }
        if !monitors.isEmpty { used += 2 }
        let width = bounds.width > 0 ? bounds.width : intrinsicContentSize.width
        let available = width - used - appGap
        return max(2, Int(available / (appWidth + appGap)))
    }

    override func layout() {
        super.layout()

        if abs(bounds.width - lastLayoutWidth) > 1 {
            lastLayoutWidth = bounds.width
            DispatchQueue.main.async { [weak self] in self?.onWidthChange?() }
        }

        var x = edge
        let top: CGFloat = 2
        let height: CGFloat = 26

        func place(_ view: NSView, width: CGFloat, spacing: CGFloat = gap) {
            view.frame = NSRect(x: x, y: top, width: width, height: height)
            x += width + spacing
        }

        place(clipboardButton, width: chipWidth(clipboardButton))
        place(phraseButton, width: chipWidth(phraseButton))
        place(appsButton, width: chipWidth(appsButton))
        place(shortcutButton, width: chipWidth(shortcutButton))
        place(petWallButton, width: chipWidth(petWallButton))

        for monitor in monitors {
            let button = button(for: monitor)
            place(button, width: chipWidth(button))
        }

        if !monitors.isEmpty { x += 2 }

        // Hard-stop at the real right edge: a capacity measured before the
        // bar reached its final width must never clip icons or the pet.
        let limit = bounds.width - edge
        for (index, button) in appButtons.enumerated() {
            if index < slotCount, x + appWidth <= limit {
                button.isHidden = false
                button.frame = NSRect(x: x, y: 0, width: appWidth, height: 30)
                x += appWidth + appGap
            } else {
                button.isHidden = true
            }
        }

        if showPet { pet.frame = bounds }
    }

    private func chipWidth(_ button: ChipButton) -> CGFloat {
        let text = (button.titleText as NSString)
            .size(withAttributes: [.font: Self.font]).width
        let hasImage = button.icon != nil
        return (text + 24 + (hasImage ? 24 : 0)).rounded()
    }

    private func button(for monitor: Monitor) -> ChipButton {
        switch monitor {
        case .weather: return weatherButton
        case .battery: return batteryButton
        case .cpu: return cpuButton
        case .memory: return memoryButton
        }
    }

    private static let font = NSFont.systemFont(ofSize: 13, weight: .regular)

    private static func makeChip(_ title: String, symbol: String) -> ChipButton {
        let button = ChipButton(frame: .zero)
        button.titleText = title
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        image?.isTemplate = true
        button.icon = image
        return button
    }
}
