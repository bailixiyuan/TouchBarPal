import AppKit
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private let loginItem = LoginItem()
    private var preferencesWindow: PreferencesWindowController?
    /// Used to tell a cold launch apart from a Dock click on a running app:
    /// LaunchServices also sends `reopen` while starting up.
    private let launchedAt = Date()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only while running: no Dock icon. The bundle still has a
        // normal app icon in Finder, so it can be opened from /Applications.
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        buildMainMenu()

        _ = ClipboardStore.shared
        AppCatalog.shared.reload()
        TouchBarController.shared.start()

        // Give AppKit a moment to finish launching before taking over the bar.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            TouchBarController.shared.present()
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(remotePaste(_:)),
            name: .init("com.local.touchbarpal.pasteRemote"),
            object: nil
        )

        // The app lives in the background: launch shows only the status item
        // and the Touch Bar. The settings window opens on `--preferences`, on
        // Dock reactivation, or from the status menu.
        if CommandLine.arguments.contains("--preferences") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openPreferences()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            self.showFirstRunInfoIfNeeded()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TouchBarController.shared.shutdown()
    }

    /// Lets another process drive a paste through the already running app, so
    /// the real "bar is frontmost" code path can be tested without tapping.
    @objc private func remotePaste(_ notification: Notification) {
        ClipboardStore.debugLog("remotePaste received object=\(String(describing: notification.object))")
        guard let text = notification.object as? String else { return }
        ClipboardStore.shared.paste(ClipItem(text: text, date: Date()))
    }

    @objc private func systemDidWake() {
        // The Touch Bar server sometimes forgets system modal bars after sleep.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            TouchBarController.shared.present()
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let image = BrandIcon.template()
        image.accessibilityDescription = "TouchBarPal"
        statusItem.button?.image = image

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem(menu, "打开设置…", #selector(openPreferences)).keyEquivalent = ","
        menu.addItem(.separator())

        let toggle = addItem(menu, "显示 Touch Bar 面板",
                             #selector(toggleBar))
        toggle.state = TouchBarController.shared.isPresented ? .on : .off

        menu.addItem(.separator())
        addItem(menu, "退出 TouchBarPal", #selector(quit))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        // Ignore the reopen that LaunchServices sends during a cold start so
        // the app can stay in the background on launch.
        if Date().timeIntervalSince(launchedAt) > 2.5 {
            openPreferences()
        }
        return true
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Menu actions

    @objc private func showBar() {
        TouchBarController.shared.present()
    }

    @objc private func hideBar() {
        TouchBarController.shared.hide()
    }

    @objc private func toggleBar() {
        if TouchBarController.shared.isPresented {
            TouchBarController.shared.hide()
        } else {
            TouchBarController.shared.present()
        }
    }

    @objc private func clearHistory() {
        ClipboardStore.shared.clear()
    }

    @objc private func refreshApps() {
        AppCatalog.shared.reload()
    }

    @objc func openPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        _ = loginItem.setEnabled(!loginItem.isEnabled)
    }

    @objc private func customizeTouchBar() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.toggleTouchBarCustomizationPalette(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Main menu

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 TouchBarPal",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "设置…", action: #selector(openPreferences), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 TouchBarPal",
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TouchBarPal",
                        action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Alerts

    func showFirstRunInfoIfNeeded() {
        let key = "didShowFirstRun"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)

        let alert = NSAlert()
        alert.messageText = "TouchBarPal 已启动"
        alert.informativeText = """
        Touch Bar 上现在有剪贴板历史和应用启动器两个图标，后面是你选定的 App 图标。

        点击剪贴板记录会自动粘贴；首次使用需要授予「辅助功能」权限。
        未授权时只会复制，需要手动按 ⌘V。

        点最左侧的 × 收起工具条（不会退出 App）；之后点 Control Strip 里的图标或菜单栏图标即可重新显示。
        在菜单栏图标 ›「设置…」（⌘,）里决定条上显示哪些 App，可选最近使用或自定义列表。
        """
        alert.addButton(withTitle: "去授权")
        alert.addButton(withTitle: "稍后")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibility()
        }
    }

    @objc func showHelp() {
        let alert = NSAlert()
        alert.messageText = "TouchBarPal 使用说明"
        alert.informativeText = """
        Touch Bar 左侧的「剪贴板」保存最近 40 条文本记录，点击一条即可粘贴。
        「应用」列出来自 /Applications 的应用，滑动浏览、点击启动。
        点 × 收起工具条；收起后可从 Control Strip 或菜单栏图标恢复。

        自动粘贴需要「辅助功能」权限：
        系统设置 › 隐私与安全性 › 辅助功能。

        提示：
        • 密码管理器标记为 concealed 的内容不会被记录。
        • Touch Bar 模式需要保持「App Controls with Control Strip」。
        • 全局 Touch Bar 使用 macOS 私有接口，系统升级后可能失效。
        • 重新编译后若自动粘贴失效，请在辅助功能里移除旧条目再重新授权。
        """
        alert.addButton(withTitle: "打开辅助功能设置")
        alert.addButton(withTitle: "好")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibility()
        }
    }

    @objc func showDiagnostics() {
        let mode = CFPreferencesCopyAppValue(
            "PresentationModeGlobal" as CFString,
            "com.apple.touchbar.agent" as CFString
        ) as? String ?? "未知"

        let privateAPI = NSTouchBar.responds(
            to: NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
        )

        let alert = NSAlert()
        alert.messageText = "诊断信息"
        alert.informativeText = """
        全局 Touch Bar API：\(privateAPI ? "可用" : "不可用")
        自动粘贴（辅助功能）：\(AXIsProcessTrusted() ? "已授权" : "未授权")
        剪贴板历史：\(ClipboardStore.shared.items.count) 条
        已发现应用：\(AppCatalog.shared.apps.count) 个
        Touch Bar 模式：\(mode)

        数据目录：~/Library/Application Support/TouchBarPal
        """
        alert.addButton(withTitle: "好")

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
