import AppKit
import ApplicationServices

/// One shortcut advertised by an app's menu bar.
struct AppShortcut {
    let title: String
    let menu: String
    let display: String
    let element: AXUIElement
}

/// Reads the menu bar of the frontmost app through Accessibility and presses
/// the matching menu item, so shortcuts can be offered without synthesising
/// keystrokes.
enum ShortcutReader {
    private struct CacheEntry {
        let pid: pid_t
        let date: Date
        let shortcuts: [AppShortcut]
    }

    private static var cache: [String: CacheEntry] = [:]

    /// Menu shortcuts rarely change, so a short cache avoids rebuilding the
    /// tree every time the page is opened.
    private static let cacheLifetime: TimeInterval = 20

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func targetApp() -> NSRunningApplication? {
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            return AppCatalog.shared.lastExternalApp
        }
        return frontmost
    }

    static func shortcuts(for app: NSRunningApplication) -> [AppShortcut] {
        guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else { return [] }
        if let entry = cache[bundleID],
           entry.pid == app.processIdentifier,
           Date().timeIntervalSince(entry.date) < cacheLifetime {
            return entry.shortcuts
        }

        let shortcuts = readMenu(for: app.processIdentifier)
        cache[bundleID] = CacheEntry(pid: app.processIdentifier, date: Date(), shortcuts: shortcuts)
        return shortcuts
    }

    // MARK: - Menu traversal

    private static func readMenu(for pid: pid_t) -> [AppShortcut] {
        guard isTrusted else { return [] }
        let application = AXUIElementCreateApplication(pid)
        guard let menuBar = attribute(application, kAXMenuBarAttribute) as! AXUIElement? else {
            return []
        }

        var result: [AppShortcut] = []
        let topMenus = (attribute(menuBar, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        for (offset, menu) in topMenus.enumerated() {
            // The leading Apple menu is identical in every app and would fill
            // the first screen; app-specific menus are more useful here.
            let title = (attribute(menu, kAXTitleAttribute) as? String) ?? ""
            if offset == 0, title == "Apple" || title == "苹果" { continue }
            collect(menu, menu: title, depth: 1, into: &result)
        }
        return Array(result.prefix(200))
    }

    private static func collect(
        _ element: AXUIElement,
        menu: String,
        depth: Int,
        into result: inout [AppShortcut]
    ) {
        guard depth < 5 else { return }
        let role = attribute(element, kAXRoleAttribute) as? String
        var currentMenu = menu

        if role == kAXMenuBarItemRole as String {
            currentMenu = (attribute(element, kAXTitleAttribute) as? String) ?? menu
        }

        if role == kAXMenuItemRole as String,
           let shortcut = shortcut(for: element, menu: currentMenu) {
            result.append(shortcut)
        }

        guard let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] else {
            return
        }
        for child in children {
            collect(child, menu: currentMenu, depth: depth + 1, into: &result)
        }
    }

    private static func shortcut(for element: AXUIElement, menu: String) -> AppShortcut? {
        guard attribute(element, kAXEnabledAttribute) as? Bool != false,
              attribute(element, kAXHiddenAttribute) as? Bool != true,
              let title = attribute(element, kAXTitleAttribute) as? String,
              !title.isEmpty else { return nil }

        let rawChar = (attribute(element, "AXMenuItemCmdChar") as? String) ?? ""
        let virtualKey = attribute(element, "AXMenuItemCmdVirtualKey") as? Int
        guard let key = keyName(char: rawChar, virtualKey: virtualKey) else { return nil }

        let modifiers = (attribute(element, "AXMenuItemCmdModifiers") as? Int) ?? 0
        // Bit 3 means "no Command"; bits 0-2 are Shift, Option, Control.
        var parts: [String] = []
        if modifiers & 4 != 0 { parts.append("⌃") }
        if modifiers & 2 != 0 { parts.append("⌥") }
        if modifiers & 1 != 0 { parts.append("⇧") }
        if modifiers & 8 == 0 { parts.append("⌘") }
        parts.append(key)
        let display = parts.joined(separator: "+")

        return AppShortcut(title: title, menu: menu, display: display, element: element)
    }

    private static func keyName(char: String, virtualKey: Int?) -> String? {
        if let virtualKey, let named = virtualKeyNames[virtualKey] { return named }
        guard let scalar = char.unicodeScalars.first else { return nil }
        switch Int(scalar.value) {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF704: return "⇞"
        case 0xF705: return "⇟"
        case 0xF706: return "↖"
        case 0xF707: return "↘"
        case 0xF708: return "↗"
        case 0xF709: return "⌦"
        case 0x0D: return "↩"
        case 0x09: return "⇥"
        case 0x1B: return "⎋"
        case 0x20: return "Space"
        default:
            let text = char.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return text.uppercased()
        }
    }

    private static let virtualKeyNames: [Int: String] = [
        0x7E: "↑", 0x7D: "↓", 0x7B: "←", 0x7C: "→",
        0x73: "↖", 0x77: "↘", 0x74: "⇞", 0x79: "⇟",
        0x33: "⌫", 0x75: "⌦", 0x24: "↩", 0x4C: "⌤",
        0x35: "⎋", 0x30: "⇥", 0x31: "Space"
    ]

    private static func attribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    // MARK: - Execution

    /// Press the original menu item. This is more reliable than posting keys,
    /// and also works for items without a key equivalent of their own.
    @discardableResult
    static func perform(_ shortcut: AppShortcut, in app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        if !app.isActive {
            app.activate(options: [])
        }
        return AXUIElementPerformAction(shortcut.element, kAXPressAction as CFString) == .success
    }
}
