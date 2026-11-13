import AppKit

/// Headless checks: `TouchBarPal.app/Contents/MacOS/TouchBarPal --selftest`.
enum SelfTest {
    static func run() {
        _ = NSApplication.shared
        // Match the login-agent style used by the harness; a regular app that
        // never runs its event loop can keep itself frontmost.
        NSApp.setActivationPolicy(.accessory)
        var failures = 0

        func check(_ name: String, _ condition: Bool) {
            print((condition ? "PASS  " : "FAIL  ") + name)
            if !condition { failures += 1 }
        }

        print("INFO  accessibility trusted: \(AXIsProcessTrusted())")

        // Private API surface ------------------------------------------------
        check(
            "private presentSystemModalTouchBar selector",
            NSTouchBar.responds(to: NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:"))
        )
        check(
            "private addSystemTrayItem selector",
            NSTouchBarItem.responds(to: NSSelectorFromString("addSystemTrayItem:"))
        )

        // Clipboard store ----------------------------------------------------
        let temporaryStore = FileManager.default.temporaryDirectory
            .appendingPathComponent("touchbarpal-selftest-\(UUID().uuidString).json")
        let store = ClipboardStore(storeURL: temporaryStore, maxItems: 5, startMonitoring: false)
        let pasteboard = NSPasteboard.general
        let savedClipboard = pasteboard.string(forType: .string)

        let token = "TouchBarPal selftest \(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        store.poll()
        check("captures plain text", store.items.first?.text == token)

        let countAfterFirstCapture = store.items.count
        pasteboard.clearContents()
        pasteboard.setString(token, forType: .string)
        store.poll()
        check(
            "deduplicates repeated text",
            store.items.count == countAfterFirstCapture && store.items.first?.text == token
        )

        let image = NSImage(size: NSSize(width: 20, height: 10))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 20, height: 10).fill()
        image.unlockFocus()
        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            store.poll()
            check("captures images", store.items.first?.isImage == true)
            check("labels image size", store.items.first?.preview == "图片 \(rep.pixelsWide)×\(rep.pixelsHigh)")
            let imageFile = store.items.first.flatMap {
                store.imageURL(for: $0).map { FileManager.default.fileExists(atPath: $0.path) }
            }
            check("stores the image file", imageFile == true)
            if let item = store.items.first {
                store.paste(item)
                check("puts an image back on the pasteboard",
                      NSPasteboard.general.data(forType: .png) != nil)
            }

            // Finder copies an image file as file URL + generic icon TIFF.
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbp-copied-\(UUID().uuidString).png")
            try? png.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            pasteboard.clearContents()
            pasteboard.declareTypes([.fileURL, .tiff], owner: nil)
            pasteboard.setString(source.absoluteString, forType: .fileURL)
            pasteboard.setData(rep.representation(using: .tiff, properties: [:]) ?? Data(), forType: .tiff)
            store.poll()
            check("captures copied image files", store.items.first?.isFile == true)
            check("labels copied files", store.items.first?.preview.hasPrefix("文件 ") == true)
            if let item = store.items.first {
                store.paste(item)
                check("pastes copied files as file URLs",
                      NSPasteboard.general.string(forType: .fileURL) != nil)
                check("pastes copied files as images too",
                      NSPasteboard.general.data(forType: .png) != nil)
                let stored = store.imageURL(for: item)
                store.clear()
                check("clearing empties the history", store.items.isEmpty)
                check("clearing deletes image files",
                      stored.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
            }
        }

        pasteboard.clearContents()
        let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString("concealed-value", forType: .string)
        pasteboard.setString("1", forType: concealedType)
        store.poll()
        check(
            "skips concealed clipboard content",
            !store.items.contains { $0.text == "concealed-value" }
        )

        for index in 0..<10 {
            pasteboard.clearContents()
            pasteboard.setString("item-\(index)", forType: .string)
            store.poll()
        }
        check(
            "respects the history limit",
            store.items.count == 5 && store.items.first?.text == "item-9"
        )
        check("persists history JSON", FileManager.default.fileExists(atPath: temporaryStore.path))

        // App scanner --------------------------------------------------------
        let candidates = AppCatalog.scanCandidates()
        check("finds installed applications", candidates.count > 5)
        check("finds Finder", candidates.contains { $0.bundleID == "com.apple.finder" })
        check("finds Safari", candidates.contains { $0.bundleID == "com.apple.Safari" })
        check(
            "loads app icons",
            NSWorkspace.shared.icon(forFile: candidates.first?.url.path ?? "/").size.width > 0
        )

        let entries = candidates.map {
            AppEntry(bundleID: $0.bundleID, name: $0.name, url: $0.url, icon: NSImage())
        }
        let sorted = AppCatalog.alphabetical(entries)
        check(
            "all-apps list is alphabetical",
            zip(sorted, sorted.dropFirst()).allSatisfy {
                $0.name.localizedStandardCompare($1.name) != .orderedDescending
            }
        )

        // Second tap on the last activated app must collapse it.
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.activationPolicy == .regular
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }), let bundleID = running.bundleIdentifier {
            AppCatalog.shared.markLastExternal(running)
            check("second tap minimises the active app", AppCatalog.shared.willMinimize(bundleID))
            AppCatalog.shared.markLastExternal(running)
            // Let the app's own launch activation settle first.
            let settleDeadline = Date().addingTimeInterval(2)
            while Date() < settleDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            }
            NSApp.deactivate()
            running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            let activationDeadline = Date().addingTimeInterval(3)
            while NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID,
                  Date() < activationDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            AppCatalog.shared.markLastExternal(nil)
            print("INFO  frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil") target=\(bundleID)")
            check("frontmost app minimises on the first tap", AppCatalog.shared.willMinimize(bundleID))
            check("background app is not minimised", !AppCatalog.shared.willMinimize("com.example.not-running"))
            AppCatalog.shared.markLastExternal(nil)
        }

        // Recent ordering refreshes at most once an hour.
        AppCatalog.shared.reload()
        let scanDeadline = Date().addingTimeInterval(5)
        while AppCatalog.shared.apps.isEmpty, Date() < scanDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        AppCatalog.shared.rebuildRecentOrder()
        let stableOrder = AppCatalog.shared.orderedApps.map(\.bundleID)
        check("recent order builds", !stableOrder.isEmpty)
        if let leastRecent = stableOrder.last {
            AppCatalog.shared.updateMRUForTest(leastRecent)
            check(
                "recent order does not change within the hour",
                AppCatalog.shared.orderedApps.map(\.bundleID) == stableOrder
            )
            AppCatalog.shared.rebuildRecentOrder()
            check("forced rebuild applies the new order", AppCatalog.shared.orderedApps.first?.bundleID == leastRecent)
        }

        // Minimising uses AX so the window animates like the yellow button.
        // Full-screen windows cannot be minimised on some apps, so prefer a
        // candidate that has at least one normal window.
        func hasNormalWindow(_ app: NSRunningApplication) -> Bool {
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsValue) == .success,
                  let windows = windowsValue as? [AXUIElement] else { return false }
            return windows.contains { window in
                var fullScreen: CFTypeRef?
                let ok = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullScreen) == .success
                return !(ok && (fullScreen as? Bool) == true)
            }
        }
        let target = NSWorkspace.shared.runningApplications.first { app in
            guard !app.isTerminated, app.activationPolicy == .regular,
                  app.bundleIdentifier != Bundle.main.bundleIdentifier,
                  app.bundleIdentifier != "com.apple.finder" else { return false }
            return hasNormalWindow(app)
        }
        func minimizedState(_ window: AXUIElement) -> Bool {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
            return (value as? Bool) == true
        }
        print("INFO  minimize target:", target?.localizedName ?? "none", "trusted:", AXIsProcessTrusted())
        if let target {
            // Bring the chosen app's normal window into an unminimised state
            // first, otherwise `minimize` would restore it instead.
            let axApp = AXUIElementCreateApplication(target.processIdentifier)
            var wv: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &wv) == .success,
               let windows = wv as? [AXUIElement] {
                for candidate in windows {
                    var fs: CFTypeRef?
                    let known = AXUIElementCopyAttributeValue(candidate, "AXFullScreen" as CFString, &fs) == .success
                    if known && (fs as? Bool) == true { continue }
                    var mini: CFTypeRef?
                    AXUIElementCopyAttributeValue(candidate, kAXMinimizedAttribute as CFString, &mini)
                    if (mini as? Bool) == true {
                        AXUIElementSetAttributeValue(candidate, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
                        for _ in 0..<10 {
                            usleep(60_000)
                            AXUIElementCopyAttributeValue(candidate, kAXMinimizedAttribute as CFString, &mini)
                            if (mini as? Bool) != true { break }
                        }
                    }
                    break
                }
            }
        }
        if let target, let window = AppCatalog.shared.minimize(target) {
            var state = minimizedState(window)
            for _ in 0..<10 where !state {
                usleep(60_000)
                state = minimizedState(window)
            }
            check("AX minimise sets the window minimised", state)
            if let entry = AppCatalog.shared.apps.first(where: { $0.bundleID == target.bundleIdentifier }) {
                AppCatalog.shared.launch(entry)
            } else {
                AppCatalog.shared.minimize(target)
            }
            for _ in 0..<10 where minimizedState(window) {
                usleep(60_000)
            }
            check("first tap restores a minimised app", !minimizedState(window))
            target.activate(options: [.activateAllWindows])
        }

        // Quick phrases ------------------------------------------------------
        let phrasesBefore = QuickPhraseStore.shared.items
        let phraseToken = "phrase-\(UUID().uuidString)"
        check("adds a quick phrase", QuickPhraseStore.shared.add(phraseToken))
        check("stores the phrase text", QuickPhraseStore.shared.items.last == phraseToken)
        check("deduplicates quick phrases", !QuickPhraseStore.shared.add(phraseToken))
        if !QuickPhraseStore.shared.items.isEmpty {
            QuickPhraseStore.shared.remove(at: QuickPhraseStore.shared.items.count - 1)
        }
        check("removes a quick phrase", QuickPhraseStore.shared.items == phrasesBefore)

        // Monitors -----------------------------------------------------------
        check("formats small speeds", MonitorCenter.speedText(0) == "0B")
        check("formats kilobyte speeds", MonitorCenter.speedText(2048) == "2.0K")
        check("formats megabyte speeds", MonitorCenter.speedText(1.5 * 1024 * 1024) == "1.5M")
        check("maps clear weather", MonitorCenter.symbolName(for: 0) == "sun.max.fill")
        check("maps rain weather", MonitorCenter.symbolName(for: 61) == "cloud.rain.fill")
        check("maps thunder weather", MonitorCenter.symbolName(for: 95) == "cloud.bolt.rain.fill")
        check("describes clear weather", MonitorCenter.conditionText(for: 0) == "晴")
        check("describes rain weather", MonitorCenter.conditionText(for: 61) == "雨")

        let batteryBefore = AppSettings.shared.showBattery
        AppSettings.shared.showBattery = !batteryBefore
        check("bundles the pet spritesheet",
              Bundle.main.url(forResource: "spritesheet", withExtension: "webp") != nil)
        let petView = PetRunView(frame: NSRect(x: 0, y: 0, width: 400, height: 30))
        check("pet overlay passes taps through", petView.hitTest(NSPoint(x: 200, y: 15)) == nil)
        check("pet overlay receives taps on itself", petView.hitTest(NSPoint(x: 80, y: 15)) != nil)
        petView.react()
        check("tapping the pet reacts", petView.isReacting)
        check("built-in pet has a sheet", PetAsset.builtIn.sheetURL != nil)

        let chip = ClipChipView(frame: NSRect(x: 0, y: 0, width: 152, height: 30))
        chip.showPlaceholder("暂无记录")
        check("empty clipboard chip has no thumbnail", !chip.showsThumbnail)
        check("empty clipboard chip shows the placeholder", chip.text == "暂无记录")

        let wall = PetWallView(frame: NSRect(x: 0, y: 0, width: 840, height: 30))
        wall.configure(assets: [.builtIn])
        check("a single pet does not scroll", !wall.isScrolling)
        check("the built-in pet has idle frames", wall.frameCount(for: .builtIn) > 1)
        let many = (0..<20).map { PetAsset(id: "fake-\($0)", name: "假宠物", directory: nil) }
        wall.configure(assets: many)
        check("an overflowing wall scrolls", wall.isScrolling)

        // One full set width of travel must wrap back to the start, keeping the
        // marquee seamless instead of jumping.
        wall.tick(1)
        check("the marquee moves", wall.offset > 0)
        wall.tick(10_000)
        check("the marquee wraps within one set", wall.offset >= 0 && wall.offset < wall.setWidth)

        var selected: PetAsset?
        wall.onSelect = { selected = $0 }
        wall.select(many[2])
        check("tapping a wall cell selects that pet", selected?.id == many[2].id)
        wall.configure(assets: [.builtIn])

        let capacityBar = MainBarView(frame: NSRect(x: 0, y: 0, width: 860, height: 30))
        let bareCapacity = capacityBar.appCapacity(for: [])
        let monitorCapacity = capacityBar.appCapacity(for: [.weather, .battery, .cpu, .memory])
        check("monitors reduce app capacity", monitorCapacity < bareCapacity)
        check("capacity never drops below 2", monitorCapacity >= 2)
        check("capacity fits the fixed width",
              bareCapacity <= Int(860 / 30))

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbp-pet-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        check("rejects a folder without a manifest",
              (try? PetLibrary.shared.importPackage(from: temp)) == nil)
        if let sheet = Bundle.main.url(forResource: "spritesheet", withExtension: "webp") {
            try? FileManager.default.copyItem(at: sheet, to: temp.appendingPathComponent("spritesheet.png"))
            try? #"{"displayName":"测试水豚","spritesheetPath":"spritesheet.png"}"#
                .data(using: .utf8)?.write(to: temp.appendingPathComponent("pet.json"))
            let imported = try? PetLibrary.shared.importPackage(from: temp)
            check("imports a pet package", imported != nil)
            if let imported {
                check("lists the imported pet", PetLibrary.shared.pets.contains(imported))
                try? PetLibrary.shared.remove(imported)
            }
        }
        try? FileManager.default.removeItem(at: temp)

        // Version-2 sheets have extra action rows; the parser must accept them.
        check("accepts tall version-2 sheets", {
            guard let sheet = Bundle.main.url(forResource: "spritesheet", withExtension: "webp"),
                  let image = NSImage(contentsOf: sheet) else { return false }
            var proposed = NSRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else { return false }
            let tall = NSImage(size: NSSize(width: cg.width, height: cg.height * 2))
            tall.lockFocus()
            image.draw(in: NSRect(x: 0, y: 0, width: cg.width, height: cg.height))
            image.draw(in: NSRect(x: 0, y: cg.height, width: cg.width, height: cg.height))
            tall.unlockFocus()
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbp-tall-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            guard let tiff = tall.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { return false }
            try? data.write(to: folder.appendingPathComponent("spritesheet.png"))
            try? #"{"displayName":"高图","spritesheetPath":"spritesheet.png"}"#
                .data(using: .utf8)?.write(to: folder.appendingPathComponent("pet.json"))
            let imported = try? PetLibrary.shared.importPackage(from: folder)
            if let imported { try? PetLibrary.shared.remove(imported) }
            return imported != nil
        }())

        if ShortcutReader.isTrusted,
           let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
            let shortcuts = ShortcutReader.shortcuts(for: finder)
            check("reads menu shortcuts through Accessibility", shortcuts.count > 3)
            check("shortcut hints carry a key and a title", shortcuts.allSatisfy {
                !$0.display.isEmpty && !$0.title.isEmpty
            })
            check("the shared Apple menu is skipped", shortcuts.allSatisfy { $0.menu != "Apple" })
            check("shortcut keys are joined with a +", shortcuts
                .filter { $0.title.contains("全部最小化") }
                .allSatisfy { $0.display.contains("+") })
        } else {
            print("INFO  shortcut reader skipped: trusted=\(ShortcutReader.isTrusted)")
        }

        let barChip = ChipButton(frame: NSRect(x: 0, y: 0, width: 90, height: 30))
        barChip.titleText = "剪贴板 3"
        check("chip keeps its title in a subview", barChip.titleText == "剪贴板 3")
        check("chip routes clicks to itself", barChip.hitTest(NSPoint(x: 40, y: 15)) === barChip)
        check("chip ignores clicks outside", barChip.hitTest(NSPoint(x: -8, y: 15)) == nil)

        let monitorBar = MainBarView(frame: NSRect(x: 0, y: 0, width: 860, height: 30))
        monitorBar.configure(slots: 2, monitors: [.battery], showPet: false)
        check("removed monitor chips are hidden",
              monitorBar.weatherButton.isHidden
              && monitorBar.cpuButton.isHidden
              && monitorBar.memoryButton.isHidden)
        check("the enabled monitor chip stays visible", !monitorBar.batteryButton.isHidden)

        check("toggles a monitor", AppSettings.shared.showBattery == !batteryBefore)
        AppSettings.shared.showBattery = batteryBefore
        check("restores a monitor toggle", AppSettings.shared.showBattery == batteryBefore)

        let previousOnChange = AppSettings.shared.onChange
        var notifications = 0
        AppSettings.shared.onChange = { notifications += 1 }
        AppSettings.shared.batch {
            AppSettings.shared.showBattery = !batteryBefore
            AppSettings.shared.showCPU = !AppSettings.shared.showCPU
            AppSettings.shared.showBattery = batteryBefore
            AppSettings.shared.showCPU = !AppSettings.shared.showCPU
        }
        check("batches several settings into one redraw", notifications == 1)
        AppSettings.shared.onChange = previousOnChange

        // Restore the user's clipboard --------------------------------------
        pasteboard.clearContents()
        if let savedClipboard {
            pasteboard.setString(savedClipboard, forType: .string)
        }
        try? FileManager.default.removeItem(at: temporaryStore)

        print("")
        if failures == 0 {
            print("ALL TESTS PASSED")
            exit(0)
        } else {
            print("\(failures) TEST(S) FAILED")
            exit(1)
        }
    }
}
