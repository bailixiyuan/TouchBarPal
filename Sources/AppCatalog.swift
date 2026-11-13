import AppKit
import ApplicationServices

struct AppEntry {
    let bundleID: String
    let name: String
    let url: URL
    let icon: NSImage
}

struct AppCandidate {
    let bundleID: String
    let name: String
    let url: URL
}

/// Scans the usual application folders, tracks a most-recently-used order and
/// launches entries via NSWorkspace.
final class AppCatalog {
    static let shared = AppCatalog()

    private(set) var apps: [AppEntry] = []
    private(set) var mruBundleIDs: [String] = []
    private(set) var lastExternalApp: NSRunningApplication?

    var onChange: (() -> Void)?
    var onMRUChange: (() -> Void)?

    /// Bundle IDs of apps that are currently running, for the active dot.
    var runningBundleIDs: Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }
            .compactMap { $0.bundleIdentifier })
    }

    private var isScanning = false
    private var lastActivated: (bundleID: String, at: Date)?

    /// Test seam: pretend `bundleID` was the app we last brought forward.
    func markLastExternal(_ app: NSRunningApplication?) {
        lastExternalApp = app
    }
    private let mruKey = "mruBundleIDs"

    private init() {
        mruBundleIDs = UserDefaults.standard.stringArray(forKey: mruKey) ?? []

        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApp = frontmost
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(appActivated(_:)),
                           name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appListChanged(_:)),
                           name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appListChanged(_:)),
                           name: NSWorkspace.didTerminateApplicationNotification, object: nil)
    }

    // MARK: - Activation tracking

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              bundleID != Bundle.main.bundleIdentifier else {
            return
        }

        if lastActivated?.bundleID != bundleID {
            lastActivated = nil
        }
        lastExternalApp = app
        mruBundleIDs.removeAll { $0 == bundleID }
        mruBundleIDs.insert(bundleID, at: 0)
        if mruBundleIDs.count > 24 {
            mruBundleIDs.removeLast(mruBundleIDs.count - 24)
        }
        UserDefaults.standard.set(mruBundleIDs, forKey: mruKey)
        onMRUChange?()
    }

    @objc private func appListChanged(_ notification: Notification) {
        // Running state affects ordering. Refresh shortly after the change.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.onChange?()
            self?.onMRUChange?()
        }
    }

    // MARK: - Scanning

    func reload() {
        guard !isScanning else { return }
        isScanning = true

        DispatchQueue.global(qos: .userInitiated).async {
            let candidates = Self.scanCandidates()

            DispatchQueue.main.async {
                self.apps = candidates.map { candidate in
                    let icon = NSWorkspace.shared.icon(forFile: candidate.url.path)
                    icon.size = NSSize(width: 22, height: 22)
                    return AppEntry(bundleID: candidate.bundleID,
                                    name: candidate.name,
                                    url: candidate.url,
                                    icon: icon)
                }
                self.cachedRecentOrder = []
                self.recentOrderBuiltAt = .distantPast
                self.isScanning = false
                self.onChange?()
                self.onMRUChange?()
            }
        }
    }

    /// Filesystem-only scan: no AppKit image loading, safe off the main thread.
    ///
    /// `CoreServices` is deliberately *not* scanned wholesale: it is full of
    /// background agents (System Events, SystemUIServer, …) that report the
    /// generic package icon. The handful of real apps living there (Finder)
    /// are listed explicitly instead.
    static func scanCandidates() -> [AppCandidate] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            "/System/Cryptexes/App/System/Applications",
            home + "/Applications"
        ]
        let extraBundles = [
            "/System/Library/CoreServices/Finder.app"
        ]

        let ownBundleID = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var result: [AppCandidate] = []
        let fileManager = FileManager.default

        func append(_ url: URL) {
            let resolvedURL = url.resolvingSymlinksInPath()
            guard let bundle = Bundle(url: resolvedURL),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != ownBundleID,
                  let packageType = bundle.infoDictionary?["CFBundlePackageType"] as? String,
                  packageType == "APPL" || packageType == "FNDR",
                  bundle.infoDictionary?["LSUIElement"] as? Bool != true,
                  bundle.infoDictionary?["LSBackgroundOnly"] as? Bool != true else {
                return
            }

            guard seen.insert(bundleID).inserted else { return }

            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? resolvedURL.deletingPathExtension().lastPathComponent

            result.append(AppCandidate(bundleID: bundleID, name: name, url: resolvedURL))
        }

        for path in extraBundles {
            append(URL(fileURLWithPath: path))
        }

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()
                append(url)
            }
        }

        return result
    }

    // MARK: - Ordering and launching

    private var cachedRecentOrder: [AppEntry] = []
    private var recentOrderBuiltAt = Date.distantPast
    /// Re-sorting the recent list at most this often keeps the bar stable while
    /// the user is tapping through it.
    private static let recentOrderLifetime: TimeInterval = 60 * 60

    /// MRU first, then running apps, then everything alphabetically, but only
    /// recomputed once per hour (or when the installed app list changes).
    var orderedApps: [AppEntry] {
        guard !apps.isEmpty else { return [] }

        let sameApps = cachedRecentOrder.count == apps.count
            && Set(cachedRecentOrder.map(\.bundleID)) == Set(apps.map(\.bundleID))
        if !sameApps || Date().timeIntervalSince(recentOrderBuiltAt) >= Self.recentOrderLifetime {
            rebuildRecentOrder()
        }
        return cachedRecentOrder
    }

    /// Selftest seam: record an activation without touching NSWorkspace.
    func updateMRUForTest(_ bundleID: String) {
        mruBundleIDs.removeAll { $0 == bundleID }
        mruBundleIDs.insert(bundleID, at: 0)
    }

    /// Force the once-an-hour re-sort (also used by the selftest).
    func rebuildRecentOrder() {
        var rank: [String: Int] = [:]
        for (index, bundleID) in mruBundleIDs.enumerated() {
            rank[bundleID] = index
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })

        cachedRecentOrder = apps.sorted { lhs, rhs in
            let leftRank = rank[lhs.bundleID] ?? Int.max
            let rightRank = rank[rhs.bundleID] ?? Int.max
            if leftRank != rightRank { return leftRank < rightRank }

            let leftRunning = running.contains(lhs.bundleID)
            let rightRunning = running.contains(rhs.bundleID)
            if leftRunning != rightRunning { return leftRunning }

            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        recentOrderBuiltAt = Date()
    }

    func recentApps(limit: Int) -> [AppEntry] {
        if !apps.isEmpty {
            return Array(orderedApps.prefix(limit))
        }

        // Before the asynchronous scan finishes, fall back to running apps.
        let running = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular &&
                $0.bundleIdentifier != Bundle.main.bundleIdentifier
            }
            .compactMap { app -> AppEntry? in
                guard let bundleID = app.bundleIdentifier, let url = app.bundleURL else { return nil }
                let icon = (app.icon?.copy() as? NSImage)
                    ?? NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 22, height: 22)
                return AppEntry(bundleID: bundleID,
                                name: app.localizedName ?? bundleID,
                                url: url,
                                icon: icon)
            }
        return Array(running.prefix(limit))
    }

    /// Alphabetical order used by the all-apps page.
    static func alphabetical(_ entries: [AppEntry]) -> [AppEntry] {
        entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Every app by name (the "all apps" page order), hidden ones removed.
    var visibleApps: [AppEntry] {
        let hidden = AppSettings.shared.hiddenBundleIDs
        return Self.alphabetical(apps.filter { !hidden.contains($0.bundleID) })
    }

    /// The icons shown on the bar itself, honouring the chosen display mode.
    /// An empty custom list falls back to the recent list so the bar is never
    /// blank by accident.
    var barApps: [AppEntry] {
        let hidden = AppSettings.shared.hiddenBundleIDs
        let recent = orderedApps.filter { !hidden.contains($0.bundleID) }

        guard AppSettings.shared.mode == .custom else {
            return Array(recent.prefix(AppSettings.shared.recentLimit))
        }

        let custom = AppSettings.shared.customBundleIDs.filter { !hidden.contains($0) }
        guard !custom.isEmpty else {
            return Array(recent.prefix(AppSettings.shared.recentLimit))
        }

        var byID: [String: AppEntry] = [:]
        for entry in apps {
            byID[entry.bundleID] = entry
        }
        return custom.compactMap { byID[$0] }
    }

    /// True when tapping this app should collapse it: it is either active or
    /// was the app we just brought forward (the bar itself keeps focus, so
    /// `isActive` alone is not reliable).
    func willMinimize(_ bundleID: String) -> Bool {
        // If the app is genuinely frontmost, the bar did not take focus, so the
        // first tap must already minimise instead of activating it again.
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
            return true
        }
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .first(where: { !$0.isTerminated }) {
            // The bar keeps focus, so `isActive` is not reliable; also treat the
            // app we last brought forward as minimisable so a second tap always
            // collapses instead of doing nothing.
            if running.isActive { return true }
        }
        if let lastExternalApp, !lastExternalApp.isTerminated,
           lastExternalApp.bundleIdentifier == bundleID {
            return true
        }
        return false
    }

    private func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        return (value as? Bool) == true
    }

    private func hasMinimizedWindow(_ app: NSRunningApplication) -> Bool {
        windows(of: app).contains(where: isMinimized)
    }

    /// Bring back every minimised window, then activate the app.
    private func restoreWindows(_ app: NSRunningApplication) {
        for window in windows(of: app) where isMinimized(window) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        app.activate(options: [.activateAllWindows])
    }

    /// Whether the app currently owns any window at all.
    private func hasWindow(_ app: NSRunningApplication) -> Bool {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success else {
            return true
        }
        return !((value as? [AXUIElement])?.isEmpty ?? true)
    }

    /// Minimise (or restore) the app's focused window through AX so the system
    /// plays its normal genie animation, like the yellow traffic light.
    @discardableResult
    func minimize(_ app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var windowValue: CFTypeRef?
        func copy(_ attribute: String) -> AXUIElement? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let value,
                  CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! AXUIElement)
        }
        func isFullScreen(_ candidate: AXUIElement) -> Bool {
            var value: CFTypeRef?
            let ok = AXUIElementCopyAttributeValue(candidate, "AXFullScreen" as CFString, &value) == .success
            return ok && (value as? Bool) == true
        }

        // Full-screen windows do not minimise on every app, so prefer a normal
        // window when the focused one is full screen.
        var window = copy(kAXFocusedWindowAttribute)
        if let current = window, isFullScreen(current) {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement],
               let normal = windows.first(where: { !isFullScreen($0) }) {
                window = normal
            }
        }
        if window == nil {
            var windowsValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windowsValue) == .success,
               let windows = windowsValue as? [AXUIElement] {
                window = windows.first { candidate in
                    var minimized: CFTypeRef?
                    return AXUIElementCopyAttributeValue(candidate, kAXMinimizedAttribute as CFString, &minimized) == .success
                }
            }
        }
        guard let window else {
            app.hide()
            return nil
        }

        var minimizedValue: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
        if (minimizedValue as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            app.activate(options: [.activateAllWindows])
            return window
        }
        let setResult = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        if setResult != .success {
            print("INFO  minimize set failed: \(setResult.rawValue)")
            app.hide()
            return nil
        }
        return window
    }

    func launch(_ entry: AppEntry) {
        // Tapping an app that is already open collapses (hides) it; tapping a
        // running background app brings it forward.
        if let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: entry.bundleID)
            .first(where: { !$0.isTerminated }) {
            // A hidden app cannot be minimised; show it instead.
            if running.isHidden {
                running.unhide()
                running.activate(options: [.activateAllWindows])
                lastExternalApp = running
                lastActivated = (entry.bundleID, Date())
                return
            }
            // Restoring beats minimising: a minimised window must come back on
            // the first tap, even if the app is also the last activated one.
            if hasMinimizedWindow(running) {
                restoreWindows(running)
                lastExternalApp = running
                lastActivated = (entry.bundleID, Date())
                return
            }
            // An app with no windows would just get hidden and could never be
            // brought back by a second tap, so activate it instead.
            if willMinimize(entry.bundleID), hasWindow(running) {
                minimize(running)
                lastActivated = nil
            } else {
                running.activate(options: [.activateAllWindows])
                lastExternalApp = running
                lastActivated = (entry.bundleID, Date())
            }
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: entry.url, configuration: configuration) { app, error in
            if let error {
                NSLog("TouchBarPal: failed to launch %@: %@",
                      entry.bundleID, error.localizedDescription)
            } else if let app {
                self.lastExternalApp = app
                self.lastActivated = (entry.bundleID, Date())
            }
        }
    }
}
