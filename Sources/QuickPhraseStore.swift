import AppKit

/// Saved snippets shown on the Quick Input page. Tapping one types it into the
/// app that was frontmost before the bar.
final class QuickPhraseStore {
    static let shared = QuickPhraseStore()

    private let key = "quickPhrases"
    private(set) var items: [String]
    var onChange: (() -> Void)?

    private init() {
        items = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    @discardableResult
    func add(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !items.contains(trimmed) else { return false }
        items.append(trimmed)
        persist()
        return true
    }

    @discardableResult
    func replace(at index: Int, with text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard items.indices.contains(index), !trimmed.isEmpty,
              !items.enumerated().contains(where: { $0.offset != index && $0.element == trimmed }) else {
            return false
        }
        items[index] = trimmed
        persist()
        return true
    }

    func remove(at index: Int) {
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        persist()
    }

    func move(from source: Int, to destination: Int) {
        guard items.indices.contains(source) else { return }
        let value = items.remove(at: source)
        items.insert(value, at: min(max(destination, 0), items.count))
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(items, forKey: key)
        onChange?()
    }

    // MARK: - Typing

    /// Type `text` into the previously frontmost app as if typed on the keyboard.
    static func type(_ text: String) {
        guard !text.isEmpty else { return }
        guard AXIsProcessTrusted() else {
            ClipboardStore.requestAccessibilityOnce()
            NSSound.beep()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsSelf = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        let target: NSRunningApplication? = frontmostIsSelf
            ? AppCatalog.shared.lastExternalApp
            : frontmost

        guard let target, !target.isTerminated, target.processIdentifier > 0 else {
            NSSound.beep()
            return
        }

        let delay: TimeInterval = frontmostIsSelf ? 0.22 : 0.05
        if frontmostIsSelf {
            _ = target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
            let units = Array(text.utf16)
            guard !units.isEmpty else { return }
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else {
                    continue
                }
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.postToPid(target.processIdentifier)
            }
        }
    }
}
