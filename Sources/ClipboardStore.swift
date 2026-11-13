import AppKit
import ApplicationServices

struct ClipItem: Codable, Equatable {
    let text: String
    let date: Date
    /// File name inside the images folder for image entries; nil for text.
    let imageFile: String?
    let imageWidth: Int?
    let imageHeight: Int?
    /// Original file name when the entry came from a copied image *file*.
    let sourceName: String?

    var isImage: Bool { imageFile != nil }
    var isFile: Bool { sourceName != nil }

    init(text: String, date: Date, imageFile: String? = nil,
         imageWidth: Int? = nil, imageHeight: Int? = nil,
         sourceName: String? = nil) {
        self.text = text
        self.date = date
        self.imageFile = imageFile
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.sourceName = sourceName
    }

    private enum CodingKeys: String, CodingKey {
        case text, date, imageFile, imageWidth, imageHeight, sourceName
    }

    /// Older stores only had `text`; missing image keys decode as nil.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        date = try container.decode(Date.self, forKey: .date)
        imageFile = try container.decodeIfPresent(String.self, forKey: .imageFile)
        imageWidth = try container.decodeIfPresent(Int.self, forKey: .imageWidth)
        imageHeight = try container.decodeIfPresent(Int.self, forKey: .imageHeight)
        sourceName = try container.decodeIfPresent(String.self, forKey: .sourceName)
    }

    /// Single-line, length-limited label for the 30pt-high Touch Bar.
    var preview: String {
        if isImage {
            if let name = sourceName { return "文件 \(name)" }
            if let width = imageWidth, let height = imageHeight {
                return "图片 \(width)×\(height)"
            }
            return "图片"
        }
        let flattened = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let compact = flattened.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        guard !compact.isEmpty else { return "空白内容" }
        return compact.count > 16 ? String(compact.prefix(16)) + "…" : compact
    }
}

/// Polls NSPasteboard, keeps a bounded text/image history, and pastes by
/// writing the pasteboard and posting ⌘V to the frontmost app.
final class ClipboardStore {
    static let shared = ClipboardStore()

    /// Bounds keep the history from filling the disk with huge screenshots.
    private static let maxImageBytes = 24 * 1024 * 1024
    private static let maxImageDimension = 4096

    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let storeURL: URL
    private let imagesURL: URL
    private let maxItems: Int
    private var timer: Timer?
    private var lastChangeCount = -1
    private var ignoredChangeCount: Int?

    init(storeURL: URL? = nil, maxItems: Int = 40, startMonitoring: Bool = true) {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TouchBarPal", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        self.storeURL = storeURL ?? support.appendingPathComponent("clipboard.json")
        self.maxItems = maxItems
        self.imagesURL = self.storeURL.deletingLastPathComponent()
            .appendingPathComponent("ClipboardImages", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: self.storeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? FileManager.default.createDirectory(at: self.imagesURL, withIntermediateDirectories: true)

        load()
        pruneOrphans()
        lastChangeCount = NSPasteboard.general.changeCount
        if startMonitoring {
            startMonitoringTimer()
        }
    }

    deinit {
        timer?.invalidate()
    }

    // MARK: - Monitoring

    private func startMonitoringTimer() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Exposed for the self-test; the app calls this from the timer.
    func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if let ignored = ignoredChangeCount {
            ignoredChangeCount = nil
            if count == ignored { return }
        }

        capture(from: pasteboard)
    }

    /// Exposed for the self-test.
    func capture(from pasteboard: NSPasteboard) {
        let types = Set(pasteboard.types ?? [])

        // Well-behaved clipboard managers mark passwords and transient values.
        let blocked: Set<NSPasteboard.PasteboardType> = [
            NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
            NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
            NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")
        ]
        guard blocked.isDisjoint(with: types) else { return }

        // A copied image file carries a generic icon TIFF too, so the file URL
        // must win: pasting the icon into Finder would otherwise do nothing.
        if let raw = pasteboard.string(forType: .fileURL),
           let url = URL(string: raw), url.isFileURL,
           captureFile(url) {
            return
        }

        if types.contains(.png) || types.contains(.tiff),
           let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           captureImage(data) {
            return
        }

        guard let raw = pasteboard.string(forType: .string) else { return }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 20_000 else { return }

        items.removeAll { $0.text == text && !$0.isImage }
        items.insert(ClipItem(text: text, date: Date()), at: 0)
        trim()
        save()
        onChange?()
    }

    private static let fileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "gif", "tiff", "tif", "webp", "bmp"
    ]

    /// Copies an image *file* into the store and keeps its name, so the entry
    /// can be pasted back into Finder as a real file.
    private func captureFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size <= Self.maxImageBytes,
              Self.fileExtensions.contains(url.pathExtension.lowercased()),
              let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let png = rep.representation(using: .png, properties: [:])
        else { return false }

        if let existing = items.first(where: { item in
            guard item.isFile, let file = item.imageFile else { return false }
            return (try? Data(contentsOf: imagesURL.appendingPathComponent(file))) == data
        }) {
            removeFiles(in: [existing])
            items.removeAll { $0 == existing }
        }

        let folder = UUID().uuidString
        let name = url.lastPathComponent.isEmpty ? "image.\(url.pathExtension)" : url.lastPathComponent
        let directory = imagesURL.appendingPathComponent(folder, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }

        items.insert(ClipItem(text: "", date: Date(),
                              imageFile: "\(folder)/\(name)",
                              imageWidth: rep.pixelsWide, imageHeight: rep.pixelsHigh,
                              sourceName: name), at: 0)
        trim()
        save()
        onChange?()
        return true
    }

    /// Stores an image as PNG. Returns false when the data is not a usable
    /// image, so the caller can fall back to text.
    private func captureImage(_ data: Data) -> Bool {
        guard let rep = NSBitmapImageRep(data: data) else { return false }

        // A 5K screenshot is overkill for a history entry; shrink it first.
        var bitmap = rep
        var width = rep.pixelsWide
        var height = rep.pixelsHigh
        let longest = max(width, height)
        if longest > Self.maxImageDimension {
            let scale = CGFloat(Self.maxImageDimension) / CGFloat(longest)
            let size = NSSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
            let scaled = NSImage(size: size)
            scaled.lockFocus()
            NSImage(size: rep.size).draw(in: NSRect(origin: .zero, size: size))
            rep.draw(in: NSRect(origin: .zero, size: size))
            scaled.unlockFocus()
            if let tiff = scaled.tiffRepresentation, let resized = NSBitmapImageRep(data: tiff) {
                bitmap = resized
                width = resized.pixelsWide
                height = resized.pixelsHigh
            }
        }

        guard let png = bitmap.representation(using: .png, properties: [:]),
              png.count <= Self.maxImageBytes else { return false }

        // Re-copying the same image should only move it back to the top.
        if let existing = items.first(where: { item in
            guard let file = item.imageFile else { return false }
            return (try? Data(contentsOf: imagesURL.appendingPathComponent(file))) == png
        }) {
            removeFiles(in: [existing])
            items.removeAll { $0 == existing }
        }

        let name = "\(UUID().uuidString).png"
        do {
            try png.write(to: imagesURL.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }

        items.insert(ClipItem(text: "", date: Date(), imageFile: name,
                              imageWidth: width, imageHeight: height), at: 0)
        trim()
        save()
        onChange?()
        return true
    }

    func imageURL(for item: ClipItem) -> URL? {
        guard let file = item.imageFile else { return nil }
        return imagesURL.appendingPathComponent(file)
    }

    private func trim() {
        guard items.count > maxItems else { return }
        let dropped = items.suffix(items.count - maxItems)
        removeFiles(in: dropped)
        items.removeLast(items.count - maxItems)
    }

    private func removeFiles(in items: some Sequence<ClipItem>) {
        for item in items {
            guard let file = item.imageFile else { continue }
            let url = imagesURL.appendingPathComponent(file)
            try? FileManager.default.removeItem(at: url)
            // Copied files live in their own folder; drop the folder too.
            let parent = url.deletingLastPathComponent()
            if parent.standardizedFileURL != imagesURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: parent)
            }
        }
    }

    // MARK: - Actions

    func clear() {
        try? FileManager.default.removeItem(at: imagesURL)
        try? FileManager.default.createDirectory(at: imagesURL, withIntermediateDirectories: true)
        items.removeAll()
        save()
        onChange?()
    }

    /// Writes the entry to the pasteboard and presses ⌘V in the app that was
    /// frontmost. The keystroke is posted *directly to that process*, so a
    /// Touch Bar page switch (or focus change) cannot steal it.
    func paste(_ item: ClipItem, completion: (() -> Void)? = nil) {
        Self.debugLog("paste() enter image=\(item.isImage) text=\(item.text.prefix(20))")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let itemURL = imageURL(for: item), let data = try? Data(contentsOf: itemURL) {
            guard let png = NSBitmapImageRep(data: data)?
                .representation(using: .png, properties: [:]) else {
                NSSound.beep()
                completion?()
                return
            }
            let pasteItem = NSPasteboardItem()
            pasteItem.setData(png, forType: .png)
            if let rep = NSBitmapImageRep(data: png),
               let tiff = rep.representation(using: .tiff, properties: [:]) {
                pasteItem.setData(tiff, forType: .tiff)
            }
            // File-based entries paste back as a file in Finder.
            if item.isFile {
                pasteItem.setString(itemURL.absoluteString, forType: .fileURL)
            }
            pasteboard.writeObjects([pasteItem])
        } else {
            pasteboard.setString(item.text, forType: .string)
        }
        ignoredChangeCount = pasteboard.changeCount

        Self.debugLog("pasteboard written count=\(pasteboard.changeCount) ax=\(AXIsProcessTrusted())")
        guard AXIsProcessTrusted() else {
            // Copy-only fallback: the user can press ⌘V manually.
            Self.debugLog("paste blocked: accessibility not trusted")
            Self.requestAccessibilityOnce()
            NSSound.beep()
            completion?()
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostIsSelf = frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier
        let target: NSRunningApplication? = frontmostIsSelf
            ? AppCatalog.shared.lastExternalApp
            : frontmost

        guard let target, !target.isTerminated, target.processIdentifier > 0 else {
            Self.debugLog("paste skipped: no target, frontmost=\(frontmost?.bundleIdentifier ?? "nil") last=\(AppCatalog.shared.lastExternalApp?.bundleIdentifier ?? "nil")")
            NSSound.beep()
            completion?()
            return
        }
        Self.debugLog("paste to \(target.bundleIdentifier ?? "?") pid=\(target.processIdentifier) frontmost=\(frontmost?.bundleIdentifier ?? "nil")")

        // When the bar's own app owns focus, the keystroke has to be sent to a
        // background process; activate it first so its text field is ready.
        let delay: TimeInterval = frontmostIsSelf ? 0.22 : 0.05
        if frontmostIsSelf {
            let ok = target.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            Self.debugLog("activate \(target.bundleIdentifier ?? "?") -> \(ok)")
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Self.postCommandV(to: target.processIdentifier)
            Self.debugLog("posted cmd-v to pid=\(target.processIdentifier)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                completion?()
            }
        }
    }

    private static var didPromptAccessibility = false

    /// Opens the Accessibility pane once per launch instead of failing silently.
    static func requestAccessibilityOnce() {
        guard !didPromptAccessibility else { return }
        didPromptAccessibility = true
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func debugLog(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let url = URL(fileURLWithPath: "/tmp/touchbarpal-debug.log")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func postCommandV(to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        usleep(8_000)
        up.postToPid(pid)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([ClipItem].self, from: data) else {
            return
        }
        // Drop image entries whose file disappeared between launches.
        items = Array(decoded.prefix(maxItems)).filter { item in
            guard let file = item.imageFile else { return true }
            return FileManager.default.fileExists(
                atPath: imagesURL.appendingPathComponent(file).path
            )
        }
    }

    /// Deletes image files left behind by a crash between writing the file and
    /// saving the index, so the folder never accumulates junk.
    private func pruneOrphans() {
        let referenced = Set(items.compactMap(\.imageFile))
        guard let enumerator = FileManager.default.enumerator(
            at: imagesURL, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return }
        for case let url as URL in enumerator {
            let relative = url.path.replacingOccurrences(of: imagesURL.path + "/", with: "")
            guard !referenced.contains(relative) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
