import AppKit

/// Owns the global Touch Bar.
///
/// The bar has two "pages" (clipboard history, app launcher) that are presented
/// as separate system-modal bars, because `NSPopoverTouchBarItem` popovers do
/// not open when a bar is shown through the private system-modal API.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    static let shared = TouchBarController()

    private let bar = NSTouchBar()
    private let clipPageBar = NSTouchBar()
    private let phrasePageBar = NSTouchBar()
    private let appsPageBar = NSTouchBar()
    private let petWallPageBar = NSTouchBar()
    private let shortcutPageBar = NSTouchBar()
    private var presentedBar: NSTouchBar?
    /// Whether a system-modal bar is currently on screen.
    var isPresented: Bool { presentedBar != nil }
    private var trayItem: NSTouchBarItem?

    private var items: [NSTouchBarItem.Identifier: NSTouchBarItem] = [:]
    private var mainBar: MainBarView?
    private var mainItem: NSCustomTouchBarItem?
    private var recentButtons: [IconButton] {
        mainBar?.appButtons ?? []
    }
    private var clipboardScrubber: ClipboardScrubberView?
    private var phraseScrubber: QuickPhraseScrubberView?
    private var appScrubber: AppScrubberView?
    private var petWall: PetWallView?
    private var shortcutScrubber: ShortcutScrubberView?
    private var shortcutTarget: NSRunningApplication?
    private var layoutSignature = ""
    private var settingsWork: DispatchWorkItem?
    private var petWallSignature = ""

    private let maxSlots = AppSettings.maximumRecentLimit
    private let scrubberWidth: CGFloat = 840
    private var slotCount = 0
    private lazy var placeholderIcon = blankIcon()

    private enum ID {
        static let main = NSTouchBarItem.Identifier("com.local.touchbarpal.main")
        static let back = NSTouchBarItem.Identifier("com.local.touchbarpal.back")
        static let tray = NSTouchBarItem.Identifier("com.local.touchbarpal.tray")
        static let clipScrubber = NSTouchBarItem.Identifier("com.local.touchbarpal.clipScrubber")
        static let clearClips = NSTouchBarItem.Identifier("com.local.touchbarpal.clearClips")
        static let phraseScrubber = NSTouchBarItem.Identifier("com.local.touchbarpal.phraseScrubber")
        static let appsScrubber = NSTouchBarItem.Identifier("com.local.touchbarpal.appsScrubber")
        static let petWall = NSTouchBarItem.Identifier("com.local.touchbarpal.petWall")
        static let shortcutScrubber = NSTouchBarItem.Identifier("com.local.touchbarpal.shortcutScrubber")
    }

    // MARK: - Setup

    func start() {
        DFRPrivate.hideCloseBox()
        bar.delegate = self
        clipPageBar.delegate = self
        phrasePageBar.delegate = self
        appsPageBar.delegate = self
        petWallPageBar.delegate = self
        shortcutPageBar.delegate = self
        bar.customizationIdentifier = NSTouchBar.CustomizationIdentifier("com.local.touchbarpal.bar")

        buildItems()
        addTrayItem()

        bar.customizationAllowedItemIdentifiers = [ID.main]
        bar.defaultItemIdentifiers = [ID.main]

        clipPageBar.defaultItemIdentifiers = [ID.back, ID.clipScrubber, ID.clearClips]
        phrasePageBar.defaultItemIdentifiers = [ID.back, ID.phraseScrubber]
        appsPageBar.defaultItemIdentifiers = [ID.back, ID.appsScrubber]
        petWallPageBar.defaultItemIdentifiers = [ID.back, ID.petWall]
        shortcutPageBar.defaultItemIdentifiers = [ID.back, ID.shortcutScrubber]

        refreshPetWall()
        applyLayout()
        refreshBar()
        updateClipboardLabel()
        observeStores()
        MonitorCenter.shared.refresh()

        // Debug hook: TBP_IMPORT_PET=<folder> imports and selects a pet.
        if let path = ProcessInfo.processInfo.environment["TBP_IMPORT_PET"] {
            do {
                let pet = try PetLibrary.shared.importPackage(from: URL(fileURLWithPath: path))
                AppSettings.shared.selectedPetID = pet.id
                NSLog("TouchBarPal: imported pet \(pet.name)")
            } catch {
                NSLog("TouchBarPal: pet import failed: \(error.localizedDescription)")
            }
        }

        // Debug hook: TBP_TYPE_DEMO=text types that text after launch.
        if let demo = ProcessInfo.processInfo.environment["TBP_TYPE_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                QuickPhraseStore.type(demo)
            }
        }

        // Debug hook: TBP_START_PAGE=apps|clip|phrases opens straight to that page.
        if let page = ProcessInfo.processInfo.environment["TBP_START_PAGE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                switch page {
                case "apps": self?.showAppsPage()
                case "phrases": self?.showPhrasePage()
                case "pets": self?.showPetWall()
                case "shortcuts": self?.showShortcutPage()
                case "main": self?.showMain()
                default: self?.showClipboardPage()
                }
            }
        }

    }

    private func buildItems() {
        let main = MainBarView(frame: NSRect(x: 0, y: 0, width: 860, height: 30))
        main.clipboardButton.target = self
        main.clipboardButton.action = #selector(showClipboardPage)
        main.phraseButton.target = self
        main.phraseButton.action = #selector(showPhrasePage)
        main.appsButton.target = self
        main.appsButton.action = #selector(showAppsPage)
        main.shortcutButton.target = self
        main.shortcutButton.action = #selector(showShortcutPage)
        // The real Touch Bar can be narrower than the intrinsic width; re-fit
        // the app row once actual bounds are known.
        main.onWidthChange = { [weak self] in self?.applyLayout() }
        main.petWallButton.target = self
        main.petWallButton.action = #selector(showPetWall)
        main.weatherButton.target = self
        main.weatherButton.action = #selector(showWeatherDetail)
        main.pet.onPet = nil
        for (index, button) in main.appButtons.enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(launchRecent(_:))
        }
        let mainItem = NSCustomTouchBarItem(identifier: ID.main)
        mainItem.view = main
        items[ID.main] = mainItem
        self.mainItem = mainItem
        mainBar = main

        let clipScrubber = ClipboardScrubberView(
            frame: NSRect(x: 0, y: 0, width: scrubberWidth, height: 30)
        )
        // Stay on the history page after pasting so several entries can be
        // used in a row.
        clipScrubber.onPick = { item in
            ClipboardStore.shared.paste(item)
        }
        let clipItem = NSCustomTouchBarItem(identifier: ID.clipScrubber)
        clipItem.view = clipScrubber
        items[ID.clipScrubber] = clipItem
        clipboardScrubber = clipScrubber

        let phraseScrubber = QuickPhraseScrubberView(
            frame: NSRect(x: 0, y: 0, width: scrubberWidth, height: 30)
        )
        phraseScrubber.onPick = { text in
            QuickPhraseStore.type(text)
        }
        let phraseItem = NSCustomTouchBarItem(identifier: ID.phraseScrubber)
        phraseItem.view = phraseScrubber
        items[ID.phraseScrubber] = phraseItem
        self.phraseScrubber = phraseScrubber

        let appScrubber = AppScrubberView(
            frame: NSRect(x: 0, y: 0, width: scrubberWidth, height: 30)
        )
        // Stay on the app page after launching, matching the history page.
        appScrubber.onPick = { entry in
            AppCatalog.shared.launch(entry)
        }
        let appItem = NSCustomTouchBarItem(identifier: ID.appsScrubber)
        appItem.view = appScrubber
        items[ID.appsScrubber] = appItem
        self.appScrubber = appScrubber

        let wall = PetWallView(frame: NSRect(x: 0, y: 0, width: scrubberWidth, height: 30))
        wall.onSelect = { asset in
            AppSettings.shared.selectedPetID = asset.id
        }
        let wallItem = NSCustomTouchBarItem(identifier: ID.petWall)
        wallItem.view = wall
        items[ID.petWall] = wallItem
        petWall = wall

        // Shortcut hints -------------------------------------------------------
        let shortcutView = ShortcutScrubberView(
            frame: NSRect(x: 0, y: 0, width: scrubberWidth, height: 30)
        )
        shortcutView.onPick = { [weak self] shortcut in
            guard let target = self?.shortcutTarget else { return }
            if !ShortcutReader.perform(shortcut, in: target) { NSSound.beep() }
        }
        shortcutView.onPermissionTap = {
            ClipboardStore.requestAccessibilityOnce()
        }
        let shortcutItem = NSCustomTouchBarItem(identifier: ID.shortcutScrubber)
        shortcutItem.view = shortcutView
        items[ID.shortcutScrubber] = shortcutItem
        shortcutScrubber = shortcutView

        // Back -----------------------------------------------------------------
        // A plain NSButtonTouchBarItem stretches to the widest native bezel, so
        // use a custom view to keep the chevron compact.
        let backButton = NSButton(
            image: symbol("chevron.left") ?? blankIcon(),
            target: self,
            action: #selector(showMain)
        )
        backButton.isBordered = false
        backButton.bezelStyle = .regularSquare
        backButton.contentTintColor = .white
        backButton.imagePosition = .imageOnly
        backButton.wantsLayer = true
        backButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        backButton.layer?.cornerRadius = 8
        backButton.widthAnchor.constraint(equalToConstant: 40).isActive = true
        backButton.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let backItem = NSCustomTouchBarItem(identifier: ID.back)
        backItem.view = backButton
        items[ID.back] = backItem

        let clear = NSButtonTouchBarItem(
            identifier: ID.clearClips,
            image: symbol("trash") ?? blankIcon(),
            target: self,
            action: #selector(clearClips)
        )
        clear.title = ""
        items[ID.clearClips] = clear
    }

    /// Control Strip entry: after the bar is collapsed it stays reachable there.
    private func addTrayItem() {
        let tray = NSButtonTouchBarItem(
            identifier: ID.tray,
            image: BrandIcon.template(size: 22),
            target: self,
            action: #selector(showMain)
        )
        tray.title = ""
        NSTouchBarItem.addSystemTrayItem(tray)
        trayItem = tray
    }

    /// Only as many icons as are actually shown; unused slots are hidden
    /// instead of rendering empty buttons.
    private func applyLayout() {
        let settings = AppSettings.shared

        var monitors: [MainBarView.Monitor] = []
        if settings.showWeather, settings.weatherLatitude != nil { monitors.append(.weather) }
        if settings.showBattery { monitors.append(.battery) }
        if settings.showCPU { monitors.append(.cpu) }
        if settings.showMemory { monitors.append(.memory) }

        // Monitor badges are wider than an icon, so measure how many app icons
        // still fit instead of squeezing them into slivers.
        let desired = min(AppCatalog.shared.barApps.count, maxSlots,
                          mainBar?.appCapacity(for: monitors) ?? maxSlots)

        let signature = "\(desired)|\(settings.showPet)|\(settings.selectedPetID)|\(monitors)"
        guard signature != layoutSignature else { return }
        layoutSignature = signature
        slotCount = desired

        mainBar?.configure(slots: desired, monitors: monitors, showPet: settings.showPet)
    }

    /// Rebuilds the wall only when the pet library actually changes, instead
    /// of on every unrelated setting.
    private func refreshPetWall() {
        let signature = PetLibrary.shared.pets.map(\.id).joined(separator: "|")
        guard signature != petWallSignature else { return }
        petWallSignature = signature
        petWall?.configure(assets: PetLibrary.shared.pets)
    }

    private func observeStores() {
        ClipboardStore.shared.onChange = { [weak self] in
            guard let self else { return }
            self.clipboardScrubber?.reload()
            self.updateClipboardLabel()
        }

        QuickPhraseStore.shared.onChange = { [weak self] in
            self?.phraseScrubber?.reload()
        }

        AppCatalog.shared.onChange = { [weak self] in
            guard let self else { return }
            self.appScrubber?.refreshRunning()
            self.refreshBar()
        }

        AppCatalog.shared.onMRUChange = { [weak self] in
            self?.refreshBar()
        }

        AppSettings.shared.onChange = { [weak self] in
            guard let self else { return }
            self.settingsWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let asset = PetLibrary.shared.selected()
                if self.mainBar?.pet.assetID != asset.id {
                    self.mainBar?.pet.load(asset)
                }
                self.applyLayout()
                self.refreshBar()
                self.appScrubber?.reload()
                self.refreshPetWall()
                MonitorCenter.shared.refresh()
            }
            self.settingsWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
        }

        MonitorCenter.shared.onSystemSample = { [weak self] sample in
            self?.apply(sample)
        }
        MonitorCenter.shared.onWeather = { [weak self] weather in
            guard let self, let button = self.mainBar?.weatherButton else { return }
            if let weather {
                self.mainBar?.setSymbol(button, MonitorCenter.symbolName(for: weather.code))
                self.mainBar?.setTitle(button, "\(weather.temperature)°")
            } else {
                self.mainBar?.setTitle(button, "—°")
            }
        }
    }

    // MARK: - Presentation

    func present() {
        showMain()
    }

    @objc func showMain() {
        refreshBar()
        present(bar)
    }

    @objc private func showClipboardPage() {
        clipboardScrubber?.reload()
        present(clipPageBar)
    }

    /// One tap wipes every entry and its image files; no extra confirmation.
    @objc private func clearClips() {
        guard !ClipboardStore.shared.items.isEmpty else {
            NSSound.beep()
            return
        }
        ClipboardStore.shared.clear()
        clipboardScrubber?.reload()
    }

    @objc private func showPhrasePage() {
        phraseScrubber?.reload()
        present(phrasePageBar)
    }

    @objc private func showAppsPage() {
        appScrubber?.reload()
        present(appsPageBar)
    }

    /// Lists the frontmost app's menu shortcuts. Reading happens off the main
    /// thread because each Accessibility call is a synchronous IPC.
    @objc private func showShortcutPage() {
        let target = ShortcutReader.targetApp()
        shortcutTarget = target
        shortcutScrubber?.show([], placeholder: "读取中…")
        present(shortcutPageBar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            guard ShortcutReader.isTrusted else {
                self.shortcutScrubber?.show([], placeholder: "需要辅助功能权限", needsPermission: true)
                return
            }
            guard let target else {
                self.shortcutScrubber?.show([], placeholder: "没有可读取的前台应用")
                return
            }
            let name = target.localizedName ?? "当前应用"
            DispatchQueue.global(qos: .userInitiated).async {
                let shortcuts = ShortcutReader.shortcuts(for: target)
                DispatchQueue.main.async {
                    guard self.shortcutTarget?.processIdentifier == target.processIdentifier else { return }
                    if shortcuts.isEmpty {
                        self.shortcutScrubber?.show([], placeholder: "\(name) 没有可读取的菜单快捷键")
                    } else {
                        self.shortcutScrubber?.show(shortcuts)
                    }
                }
            }
        }
    }

    @objc private func showPetWall() {        present(petWallPageBar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            var assets = PetLibrary.shared.pets
            // Debug hook: repeat the row to exercise the parallax marquee.
            if ProcessInfo.processInfo.environment["TBP_PET_STRESS"] != nil {
                let base = assets
                for round in 0..<5 {
                    assets += base.map {
                        PetAsset(id: "\($0.id)-stress-\(round)", name: $0.name, directory: $0.directory)
                    }
                }
            }
            self?.petWall?.configure(assets: assets)
        }
    }

    private func present(_ target: NSTouchBar) {
        let selector = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        guard NSTouchBar.responds(to: selector) else {
            NSLog("TouchBarPal: system modal Touch Bar API is unavailable on this macOS build")
            return
        }

        // Each page is a separate system-modal bar; dismiss the previous one
        // first, otherwise pages stack up and the close box only pops the top
        // page instead of collapsing the whole tool.
        if let presentedBar, presentedBar !== target {
            NSTouchBar.dismissSystemModalTouchBar(presentedBar)
        }

        // Placement 0 keeps the system Control Strip (brightness/volume) on the right.
        DFRPrivate.hideCloseBox()
        NSTouchBar.presentSystemModalTouchBar(target, placement: 0, systemTrayItemIdentifier: ID.tray)
        presentedBar = target
    }

    /// Collapses the bar into its Control Strip tray item, so it can be
    /// summoned again by tapping that item (or the menu).
    func hide() {
        guard let presentedBar else { return }
        NSTouchBar.minimizeSystemModalTouchBar(presentedBar)
        self.presentedBar = nil
    }

    func shutdown() {
        hide()
        MonitorCenter.shared.invalidate()
        if let trayItem {
            NSTouchBarItem.removeSystemTrayItem(trayItem)
            self.trayItem = nil
        }
    }

    // MARK: - NSTouchBarDelegate

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        items[identifier]
    }

    // MARK: - Actions

    @objc private func launchRecent(_ sender: IconButton) {
        let apps = AppCatalog.shared.barApps
        guard sender.tag >= 0, sender.tag < apps.count else { return }
        let entry = apps[sender.tag]
        playAppTapAnimation(on: sender, minimize: AppCatalog.shared.willMinimize(entry.bundleID))
        AppCatalog.shared.launch(entry)
    }

    @objc private func showWeatherDetail() {
        MonitorCenter.shared.fetchWeather()
        guard AppSettings.shared.showWeather else { return }
        let now = AppSettings.shared.cityName
        let alert = NSAlert()
        if let weather = MonitorCenter.shared.lastWeather {
            alert.messageText = "\(now)  \(MonitorCenter.conditionText(for: weather.code))"
            alert.informativeText = "\(weather.temperature)°C"
        } else {
            alert.messageText = now.isEmpty ? "尚未设置天气位置" : now
            alert.informativeText = "正在获取天气…"
        }
        alert.addButton(withTitle: "刷新")
        alert.addButton(withTitle: "好")
        if alert.runModal() == .alertFirstButtonReturn {
            MonitorCenter.shared.fetchWeather()
        }
    }

    private func apply(_ sample: SystemSample) {
        guard let bar = mainBar else { return }
        if let percent = sample.batteryPercent {
            bar.setTitle(bar.batteryButton, "\(percent)%")
            bar.setSymbol(bar.batteryButton,
                          sample.charging ? "battery.100.bolt" : batterySymbol(percent))
        } else {
            bar.setTitle(bar.batteryButton, "电源")
            bar.setSymbol(bar.batteryButton, "powerplug.fill")
        }
        bar.setTitle(bar.cpuButton, "\(Int(sample.cpuPercent.rounded()))%")
        bar.setTitle(bar.memoryButton, "\(Int(sample.memoryPercent.rounded()))%")
    }

    private func batterySymbol(_ percent: Int) -> String {
        switch percent {
        case ...10: return "battery.0"
        case ...25: return "battery.25"
        case ...50: return "battery.50"
        case ...75: return "battery.75"
        default: return "battery.100"
        }
    }

    private func updateClipboardLabel() {
        guard let button = mainBar?.clipboardButton else { return }
        let count = ClipboardStore.shared.items.count
        mainBar?.setTitle(button, count == 0 ? "剪贴板" : "剪贴板 \(count)")
    }

    private func refreshBar() {
        applyLayout()
        let apps = AppCatalog.shared.barApps

        for (index, button) in recentButtons.enumerated() {
            if index < apps.count, index < maxSlots, index < slotCount {
                if button.icon !== apps[index].icon { button.icon = apps[index].icon }
                let isRunning = AppCatalog.shared.runningBundleIDs.contains(apps[index].bundleID)
                if button.isRunning != isRunning { button.isRunning = isRunning }
                if !button.isEnabled { button.isEnabled = true }
            } else {
                if button.icon !== placeholderIcon { button.icon = placeholderIcon }
                if button.isRunning { button.isRunning = false }
                if button.isEnabled { button.isEnabled = false }
            }
        }
    }

    // MARK: - Helpers

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

    private func blankIcon() -> NSImage {
        NSImage(size: NSSize(width: 22, height: 22))
    }
}

/// Fixed-width wrapper for an app icon; without an intrinsic size the Touch Bar
/// compresses these into slivers when monitor badges take up room.
final class RecentSlotView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: 30, height: 30)
    }
}

final class FixedWidthView: NSView {
    private let width: CGFloat

    init(frame: NSRect, width: CGFloat) {
        self.width = width
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: width, height: 30)
    }
}

/// Loads the private DFRFoundation switch that hides the close box on system
/// modal Touch Bars. Purely cosmetic; failures are ignored.
enum DFRPrivate {
    private static let handle: UnsafeMutableRawPointer? = dlopen(
        "/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation",
        RTLD_LAZY
    )

    static func hideCloseBox() {
        typealias Function = @convention(c) (Bool) -> Void
        guard let handle,
              let symbol = dlsym(handle, "DFRSystemModalShowsCloseBoxWhenFrontMost") else {
            return
        }
        let function = unsafeBitCast(symbol, to: Function.self)
        function(false)
    }
}
