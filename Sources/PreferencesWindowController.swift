import AppKit

/// Main window: tabbed settings for the bar contents, quick phrases and the
/// app's general options. Opened from the Dock icon / status menu.
final class PreferencesWindowController: NSWindowController,
                                        NSTableViewDataSource,
                                        NSTableViewDelegate,
                                        NSSearchFieldDelegate,
                                        NSWindowDelegate {

    private enum Tab: Int {
        case bar = 0
        case phrases = 1
        case monitors = 2
        case general = 3
    }

    private let tabControl = NSSegmentedControl(
        labels: ["工具栏", "快捷输入", "监控", "通用"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let content = NSView()

    // Bar tab
    private let table = NSTableView()
    private let scrollView = NSScrollView()
    private let modeControl = NSSegmentedControl(
        labels: ["最近使用", "自定义列表"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let searchField = NSSearchField()
    private let countLabel = NSTextField(labelWithString: "")
    private let countStepper = NSStepper()
    private lazy var clearHistoryButton = NSButton(
        title: "清空剪贴板历史", target: self, action: #selector(clearHistory)
    )

    private var rows: [AppEntry] = []
    private var query = ""
    private var panes: [NSView] = []
    private let loginItem = LoginItem()

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TouchBarPal 设置"
        window.minSize = NSSize(width: 620, height: 520)
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(monitorSettingsChanged(_:)),
            name: .monitorSettingsChanged,
            object: nil
        )
        buildInterface(in: window)
        window.center()
        reloadRows()
        syncControls()
        select(.bar)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Interface

    private func buildInterface(in window: NSWindow) {
        guard let root = window.contentView else { return }

        tabControl.target = self
        tabControl.action = #selector(tabChanged)
        tabControl.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false

        panes = [makeBarPane(), makePhrasesPane(), makeMonitorsPane(), makeGeneralPane()]
        for pane in panes {
            pane.translatesAutoresizingMaskIntoConstraints = false
            pane.isHidden = true
            content.addSubview(pane)
            NSLayoutConstraint.activate([
                pane.topAnchor.constraint(equalTo: content.topAnchor),
                pane.bottomAnchor.constraint(equalTo: content.bottomAnchor),
                pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: content.trailingAnchor)
            ])
        }

        root.addSubview(tabControl)
        root.addSubview(content)
        NSLayoutConstraint.activate([
            tabControl.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            tabControl.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            tabControl.widthAnchor.constraint(equalToConstant: 390),
            content.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 12),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20)
        ])
    }

    private func makeBarPane() -> NSView {
        let pane = NSView()

        let heading = NSTextField(labelWithString: "Touch Bar 上显示哪些 App")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        modeControl.target = self
        modeControl.action = #selector(modeChanged)

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: 12)

        searchField.placeholderString = "搜索 App"
        searchField.delegate = self

        countStepper.minValue = 1
        countStepper.maxValue = Double(AppSettings.maximumRecentLimit)
        countStepper.increment = 1
        countStepper.valueWraps = false
        countStepper.target = self
        countStepper.action = #selector(countChanged)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        table.headerView = nil
        table.rowHeight = 40
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app")))
        table.registerForDraggedTypes([.string])
        table.target = self
        table.doubleAction = #selector(toggleRow)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        let enableAll = NSButton(title: "全部启用", target: self, action: #selector(enableAll))
        let disableAll = NSButton(title: "全部停用", target: self, action: #selector(disableAll))
        let refresh = NSButton(title: "刷新列表", target: self, action: #selector(refreshList))
        for button in [enableAll, disableAll, refresh, clearHistoryButton] {
            button.bezelStyle = .rounded
        }

        let countStack = NSStackView(views: [countLabel, countStepper])
        countStack.orientation = .horizontal
        countStack.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonStack = NSStackView(views: [countStack, spacer, clearHistoryButton, enableAll, disableAll, refresh])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6

        let stack = NSStackView(views: [heading, modeControl, hintLabel, searchField, scrollView, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            modeControl.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 150),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return pane
    }

    private func makePhrasesPane() -> NSView {
        let pane = NSView()

        let heading = NSTextField(labelWithString: "快捷输入短语")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let hint = NSTextField(
            wrappingLabelWithString: "这些短语会出现在 Touch Bar 的「快捷输入」页，点一下即输入到当前 App。拖动可调整顺序。"
        )
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)

        phraseTable.headerView = nil
        phraseTable.rowHeight = 28
        phraseTable.usesAlternatingRowBackgroundColors = true
        phraseTable.allowsMultipleSelection = false
        phraseTable.dataSource = self
        phraseTable.delegate = self
        phraseTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("phrase")))
        phraseTable.registerForDraggedTypes([.string])
        phraseTable.target = self
        phraseTable.doubleAction = #selector(useSelectedPhrase)

        phraseScroll.documentView = phraseTable
        phraseScroll.hasVerticalScroller = true
        phraseScroll.autohidesScrollers = true
        phraseScroll.borderType = .bezelBorder

        phraseField.placeholderString = "输入一条短语，按回车或点「添加」"
        phraseField.target = self
        phraseField.action = #selector(addPhrase)

        let addButton = NSButton(title: "添加", target: self, action: #selector(addPhrase))
        let updateButton = NSButton(title: "更新所选", target: self, action: #selector(updatePhrase))
        let deleteButton = NSButton(title: "删除所选", target: self, action: #selector(deletePhrase))
        for button in [addButton, updateButton, deleteButton] {
            button.bezelStyle = .rounded
        }

        let addStack = NSStackView(views: [phraseField, addButton])
        addStack.orientation = .horizontal
        addStack.spacing = 6

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonStack = NSStackView(views: [spacer, deleteButton, updateButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 6

        let stack = NSStackView(views: [heading, hint, phraseScroll, addStack, buttonStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            phraseScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            phraseScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            addStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonStack.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return pane
    }

    private func makeMonitorsPane() -> NSView {
        let pane = NSView()

        let heading = NSTextField(labelWithString: "主条上的监控")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let hint = NSTextField(wrappingLabelWithString:
            "监控项显示在主条的快捷入口右侧，勾选即显示。CPU / 内存每 2 秒刷新，天气每 15 分钟刷新。"
        )
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 12)

        for box in [weatherCheck, batteryCheck, cpuCheck, memoryCheck] {
            box.target = self
            box.action = #selector(monitorToggled)
        }

        let cityLabel = NSTextField(labelWithString: "天气城市")
        cityLabel.font = .systemFont(ofSize: 12)
        cityField.placeholderString = "如：上海 / Tokyo"
        cityField.stringValue = AppSettings.shared.cityName
        cityField.target = self
        cityField.action = #selector(saveCity)

        let saveButton = NSButton(title: "保存城市", target: self, action: #selector(saveCity))
        let locateButton = NSButton(title: "自动定位", target: self, action: #selector(locateMe))
        for button in [saveButton, locateButton] {
            button.bezelStyle = .rounded
        }

        let cityStack = NSStackView(views: [cityField, saveButton, locateButton])
        cityStack.orientation = .horizontal
        cityStack.spacing = 6

        cityStatus.font = .systemFont(ofSize: 11)
        cityStatus.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            heading, hint, weatherCheck, batteryCheck, cpuCheck, memoryCheck,
            cityLabel, cityStack, cityStatus
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
            hint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cityStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            cityField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
        return pane
    }

    private func makeGeneralPane() -> NSView {
        let pane = NSView()

        let heading = NSTextField(labelWithString: "通用")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)

        petCheckbox.target = self
        petCheckbox.action = #selector(petToggled)
        petPopup.target = self
        petPopup.action = #selector(petChosen)
        petImportButton.target = self
        petImportButton.action = #selector(importPet)
        petDeleteButton.target = self
        petDeleteButton.action = #selector(deletePet)
        petImportButton.bezelStyle = .rounded
        petDeleteButton.bezelStyle = .rounded
        let petRow = NSStackView(views: [petCheckbox, petPopup, petImportButton, petDeleteButton])
        petRow.orientation = .horizontal
        petRow.spacing = 8

        let petHint = NSTextField(wrappingLabelWithString:
            "宠物以顶层动画浮在主条上方。可导入 Codex 宠物文件夹（pet.json + 8 列、至少 9 行的透明精灵图）。"
        )
        petHint.font = .systemFont(ofSize: 12)
        petHint.textColor = .secondaryLabelColor

        accessibilityLabel.font = .systemFont(ofSize: 12)
        accessibilityLabel.textColor = .secondaryLabelColor

        let accessButton = NSButton(title: "打开辅助功能设置", target: self, action: #selector(openAccessibility))
        let helpButton = NSButton(title: "使用说明", target: self, action: #selector(showHelp))
        let diagnosticsButton = NSButton(title: "诊断信息", target: self, action: #selector(showDiagnostics))
        let customizeButton = NSButton(title: "自定义 Touch Bar", target: self, action: #selector(customizeTouchBar))
        for button in [accessButton, helpButton, diagnosticsButton, customizeButton] {
            button.bezelStyle = .rounded
        }

        let accessStack = NSStackView(views: [accessibilityLabel, accessButton])
        accessStack.orientation = .horizontal
        accessStack.spacing = 10

        let buttonStack = NSStackView(views: [helpButton, diagnosticsButton, customizeButton])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8

        let about = NSTextField(wrappingLabelWithString:
            "TouchBarPal 是一款全局 Touch Bar 工具：剪贴板历史、快捷输入和 App 启动器。\n" +
            "点工具条最左侧的 × 只会把它收起到 Control Strip，可从这里的开关或 Control Strip 恢复。"
        )
        about.font = .systemFont(ofSize: 12)
        about.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [heading, loginCheckbox, petRow, petHint, accessStack, buttonStack, about])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor),
            stack.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: pane.bottomAnchor),
            about.widthAnchor.constraint(equalTo: stack.widthAnchor),
            petHint.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        return pane
    }

    private let phraseTable = NSTableView()
    private let phraseScroll = NSScrollView()
    private let phraseField = NSTextField()
    private let loginCheckbox = NSButton(checkboxWithTitle: "登录时自动启动", target: nil, action: nil)
    private let petCheckbox = NSButton(checkboxWithTitle: "显示宠物", target: nil, action: nil)
    private let petPopup = NSPopUpButton()
    private let petImportButton = NSButton(title: "导入…", target: nil, action: nil)
    private let petDeleteButton = NSButton(title: "删除", target: nil, action: nil)
    private let weatherCheck = NSButton(checkboxWithTitle: "天气", target: nil, action: nil)
    private let batteryCheck = NSButton(checkboxWithTitle: "电池电量", target: nil, action: nil)
    private let cpuCheck = NSButton(checkboxWithTitle: "CPU 占用", target: nil, action: nil)
    private let memoryCheck = NSButton(checkboxWithTitle: "内存占用", target: nil, action: nil)
    private let cityField = NSTextField()
    private let cityStatus = NSTextField(labelWithString: "")
    private let accessibilityLabel = NSTextField(labelWithString: "")

    // MARK: - Tabs

    @objc private func tabChanged() {
        select(Tab(rawValue: tabControl.selectedSegment) ?? .bar)
    }

    private func select(_ tab: Tab) {
        tabControl.selectedSegment = tab.rawValue
        for (index, pane) in panes.enumerated() {
            pane.isHidden = index != tab.rawValue
        }
        syncControls()
    }

    // MARK: - Data

    private func reloadRows() {
        let all = AppCatalog.shared.orderedApps

        var sorted: [AppEntry]
        if AppSettings.shared.mode == .custom {
            var byID: [String: AppEntry] = [:]
            for entry in all { byID[entry.bundleID] = entry }
            var picked: [AppEntry] = []
            for id in AppSettings.shared.customBundleIDs {
                if let entry = byID.removeValue(forKey: id) { picked.append(entry) }
            }
            let rest = byID.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            sorted = picked + rest
        } else {
            sorted = all.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }

        if !query.isEmpty {
            sorted = sorted.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        rows = sorted
        table.reloadData()
    }

    @objc private func syncControls() {
        let custom = AppSettings.shared.mode == .custom
        modeControl.selectedSegment = custom ? 1 : 0
        countStepper.integerValue = AppSettings.shared.recentLimit
        countLabel.stringValue = "最近使用数量：\(AppSettings.shared.recentLimit)"
        countStepper.isHidden = custom
        countLabel.isHidden = custom
        clearHistoryButton.title = "清空剪贴板历史（\(ClipboardStore.shared.items.count)）"

        if custom {
            hintLabel.stringValue = AppSettings.shared.isEmptyCustomList
                ? "勾选要固定在 Touch Bar 上的 App，可拖动调整顺序。当前列表为空，暂时回退为最近使用。"
                : "勾选要固定在 Touch Bar 上的 App，可拖动调整顺序。未勾选的 App 不会出现在条上。"
        } else {
            hintLabel.stringValue = "条上显示最近使用的 App。取消勾选可把 App 从 Touch Bar 上隐藏（也会从「应用」列表里移除）。"
        }

        weatherCheck.state = AppSettings.shared.showWeather ? .on : .off
        batteryCheck.state = AppSettings.shared.showBattery ? .on : .off
        cpuCheck.state = AppSettings.shared.showCPU ? .on : .off
        memoryCheck.state = AppSettings.shared.showMemory ? .on : .off
        if cityField.currentEditor() == nil {
            cityField.stringValue = AppSettings.shared.cityName
        }
        if AppSettings.shared.weatherLatitude == nil {
            cityStatus.stringValue = AppSettings.shared.cityName.isEmpty
                ? "未设置城市，天气不会显示。"
                : "\(AppSettings.shared.cityName)，请重新输入城市名。"
        } else {
            cityStatus.stringValue = "当前城市：\(AppSettings.shared.cityName)"
        }

        loginCheckbox.state = loginItem.isEnabled ? .on : .off
        petCheckbox.state = AppSettings.shared.showPet ? .on : .off
        rebuildPetPopup()
        accessibilityLabel.stringValue = AXIsProcessTrusted()
            ? "自动粘贴：已授权"
            : "自动粘贴：未授权（未授权时只复制，需手动按 ⌘V）"
    }

    private func applyChange(_ body: () -> Void) {
        body()
        reloadRows()
        syncControls()
    }

    // MARK: - Actions

    @objc private func petToggled() {
        AppSettings.shared.showPet = petCheckbox.state == .on
        petPopup.isEnabled = petCheckbox.state == .on
        petDeleteButton.isEnabled = petCheckbox.state == .on && !PetLibrary.shared.selected().isBuiltIn
    }

    private func rebuildPetPopup() {
        let selected = PetLibrary.shared.selected()
        petPopup.removeAllItems()
        var seen: [String: Int] = [:]
        for pet in PetLibrary.shared.pets {
            seen[pet.name, default: 0] += 1
            // Built-in and duplicate imported names need a distinguishing suffix.
            let title: String
            if pet.isBuiltIn {
                title = "\(pet.name)（内置）"
            } else if seen[pet.name, default: 0] > 1 {
                title = "\(pet.name)（\(seen[pet.name] ?? 1)）"
            } else {
                title = pet.name
            }
            petPopup.addItem(withTitle: title)
            petPopup.lastItem?.representedObject = pet.id
        }
        let index = petPopup.itemArray.firstIndex { ($0.representedObject as? String) == selected.id }
        petPopup.selectItem(at: index ?? 0)
        petPopup.isEnabled = AppSettings.shared.showPet
        petDeleteButton.isEnabled = AppSettings.shared.showPet && !selected.isBuiltIn
    }

    @objc private func petChosen() {
        guard let id = petPopup.selectedItem?.representedObject as? String,
              let pet = PetLibrary.shared.asset(withID: id) else { return }
        AppSettings.shared.selectedPetID = pet.id
        petDeleteButton.isEnabled = !pet.isBuiltIn
    }

    @objc private func importPet() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "选择包含 pet.json 和标准精灵图的宠物文件夹"
        panel.prompt = "导入"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let pet = try PetLibrary.shared.importPackage(from: url)
            AppSettings.shared.selectedPetID = pet.id
            AppSettings.shared.showPet = true
            petCheckbox.state = .on
            rebuildPetPopup()
        } catch {
            let alert = NSAlert()
            alert.messageText = "导入失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func deletePet() {
        let selected = PetLibrary.shared.selected()
        guard !selected.isBuiltIn else { return }
        do {
            try PetLibrary.shared.remove(selected)
            AppSettings.shared.selectedPetID = PetAsset.builtIn.id
            rebuildPetPopup()
        } catch {
            let alert = NSAlert()
            alert.messageText = "删除失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func monitorToggled() {
        // Four separate writes would otherwise redraw the bar and rebuild the
        // pet wall four times per click.
        AppSettings.shared.batch {
            AppSettings.shared.showWeather = weatherCheck.state == .on
            AppSettings.shared.showBattery = batteryCheck.state == .on
            AppSettings.shared.showCPU = cpuCheck.state == .on
            AppSettings.shared.showMemory = memoryCheck.state == .on
        }
    }

    @objc private func saveCity() {
        MonitorCenter.shared.saveCity(cityField.stringValue)
        cityStatus.stringValue = "正在查找位置…"
    }

    @objc private func locateMe() {
        MonitorCenter.shared.locateMe()
        cityStatus.stringValue = "正在定位…"
    }

    @objc private func monitorSettingsChanged(_ notification: Notification) {
        if let error = notification.userInfo?["error"] as? String {
            cityStatus.stringValue = error
        }
        syncControls()
    }

    @objc private func modeChanged() {
        AppSettings.shared.mode = modeControl.selectedSegment == 1 ? .custom : .recent
        reloadRows()
        syncControls()
    }

    @objc private func countChanged() {
        AppSettings.shared.recentLimit = countStepper.integerValue
        syncControls()
    }

    @objc private func toggleRow() {
        let row = table.clickedRow
        guard row >= 0, row < rows.count else { return }
        toggle(row: row)
    }

    private func toggle(row: Int) {
        guard row < rows.count else { return }
        let entry = rows[row]
        applyChange {
            if AppSettings.shared.mode == .custom {
                AppSettings.shared.setInCustomList(
                    !AppSettings.shared.isInCustomList(entry.bundleID),
                    for: entry.bundleID
                )
            } else {
                AppSettings.shared.setHidden(
                    !AppSettings.shared.isHidden(entry.bundleID),
                    for: entry.bundleID
                )
            }
        }
    }

    @objc private func enableAll() {
        applyChange {
            for entry in rows {
                if AppSettings.shared.mode == .custom {
                    AppSettings.shared.setInCustomList(true, for: entry.bundleID)
                } else {
                    AppSettings.shared.setHidden(false, for: entry.bundleID)
                }
            }
        }
    }

    @objc private func disableAll() {
        applyChange {
            for entry in rows {
                if AppSettings.shared.mode == .custom {
                    AppSettings.shared.setInCustomList(false, for: entry.bundleID)
                } else {
                    AppSettings.shared.setHidden(true, for: entry.bundleID)
                }
            }
        }
    }

    @objc private func refreshList() {
        AppCatalog.shared.reload()
        reloadRows()
    }

    @objc private func clearHistory() {
        ClipboardStore.shared.clear()
        syncControls()
    }

    @objc private func toggleLogin() {
        _ = loginItem.setEnabled(!loginItem.isEnabled)
        syncControls()
    }

    @objc private func openAccessibility() {
        (NSApp.delegate as? AppDelegate)?.openAccessibility()
        syncControls()
    }

    @objc private func showHelp() {
        (NSApp.delegate as? AppDelegate)?.showHelp()
    }

    @objc private func showDiagnostics() {
        (NSApp.delegate as? AppDelegate)?.showDiagnostics()
    }

    @objc private func customizeTouchBar() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.toggleTouchBarCustomizationPalette(nil)
    }

    @objc private func addPhrase() {
        if QuickPhraseStore.shared.add(phraseField.stringValue) {
            phraseField.stringValue = ""
            phraseTable.reloadData()
            phraseTable.scrollRowToVisible(max(QuickPhraseStore.shared.items.count - 1, 0))
        } else {
            NSSound.beep()
        }
    }

    @objc private func updatePhrase() {
        let row = phraseTable.selectedRow
        guard row >= 0 else { return }
        if QuickPhraseStore.shared.replace(at: row, with: phraseField.stringValue) {
            phraseField.stringValue = ""
            phraseTable.reloadData()
        } else {
            NSSound.beep()
        }
    }

    @objc private func deletePhrase() {
        let row = phraseTable.selectedRow
        guard row >= 0 else { return }
        QuickPhraseStore.shared.remove(at: row)
        phraseTable.reloadData()
    }

    @objc private func useSelectedPhrase() {
        let row = phraseTable.clickedRow
        guard row >= 0, row < QuickPhraseStore.shared.items.count else { return }
        phraseField.stringValue = QuickPhraseStore.shared.items[row]
        phraseField.selectText(nil)
    }

    // MARK: - Search

    func controlTextDidChange(_ notification: Notification) {
        query = searchField.stringValue
        reloadRows()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === phraseTable ? QuickPhraseStore.shared.items.count : rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === phraseTable {
            let cell = NSTableCellView()
            let label = NSTextField(labelWithString: QuickPhraseStore.shared.items[row])
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 13)
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let cell = AppRowView()
        cell.configure(with: rows[row])
        cell.checkbox.tag = row
        cell.checkbox.target = self
        cell.checkbox.action = #selector(checkboxClicked(_:))
        return cell
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        toggle(row: sender.tag)
    }

    // MARK: Drag & drop reordering

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        if tableView === phraseTable {
            guard row < QuickPhraseStore.shared.items.count else { return nil }
            let item = NSPasteboardItem()
            item.setString(String(row), forType: .string)
            return item
        }
        guard AppSettings.shared.mode == .custom,
              row < rows.count,
              AppSettings.shared.isInCustomList(rows[row].bundleID) else {
            return nil
        }
        let item = NSPasteboardItem()
        item.setString(rows[row].bundleID, forType: .string)
        return item
    }

    func tableView(_ tableView: NSTableView,
                   validateDrop info: NSDraggingInfo,
                   proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        if tableView === phraseTable { return .move }
        guard AppSettings.shared.mode == .custom else { return [] }
        return .move
    }

    func tableView(_ tableView: NSTableView,
                   acceptDrop info: NSDraggingInfo,
                   row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        if tableView === phraseTable {
            guard let text = info.draggingPasteboard.string(forType: .string),
                  let source = Int(text) else { return false }
            QuickPhraseStore.shared.move(from: source, to: row)
            phraseTable.reloadData()
            return true
        }
        guard AppSettings.shared.mode == .custom,
              let draggedID = info.draggingPasteboard.string(forType: .string),
              let source = AppSettings.shared.customBundleIDs.firstIndex(of: draggedID) else {
            return false
        }

        var destination = AppSettings.shared.customBundleIDs.count
        if row < rows.count {
            if let index = AppSettings.shared.customBundleIDs.firstIndex(of: rows[row].bundleID) {
                destination = index
            }
        }

        var ids = AppSettings.shared.customBundleIDs
        let value = ids.remove(at: source)
        if destination > source { destination -= 1 }
        ids.insert(value, at: min(max(destination, 0), ids.count))
        AppSettings.shared.setInCustomList(true, for: value)
        AppSettings.shared.customBundleIDs = ids
        AppSettings.shared.onChange?()
        reloadRows()
        return true
    }

    // MARK: - Window

    func windowWillClose(_ notification: Notification) {
        try? "closed \(Date())\n".write(toFile: "/tmp/tbp-window.log", atomically: true, encoding: .utf8)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        try? "mini \(Date())\n".write(toFile: "/tmp/tbp-window.log", atomically: true, encoding: .utf8)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        reloadRows()
        syncControls()
    }
}

/// Checkbox + icon + name row.
final class AppRowView: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)

        iconView.imageScaling = .scaleProportionallyDown
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.font = .systemFont(ofSize: 13)

        let stack = NSStackView(views: [checkbox, iconView, nameLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with entry: AppEntry) {
        iconView.image = entry.icon
        nameLabel.stringValue = entry.name

        switch AppSettings.shared.mode {
        case .custom:
            checkbox.state = AppSettings.shared.isInCustomList(entry.bundleID) ? .on : .off
        case .recent:
            checkbox.state = AppSettings.shared.isHidden(entry.bundleID) ? .off : .on
        }
    }
}
