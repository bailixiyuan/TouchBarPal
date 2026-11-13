import AppKit

/// The pet that strolls across the whole bar. It is a transparent overlay above
/// the buttons, so it can wander from the clipboard chip to the app icons
/// without reserving any layout space.
///
/// Spritesheets use the Codex pet layout: 8 columns, standard 192×208 cells and
/// at least 9 rows (version 1) or 11 rows (version 2, which adds dance rows).
/// Row 1 is idle, rows 2 and 3 walk right/left, the rest are actions.
final class PetRunView: NSView {
    var onPet: (() -> Void)?
    private(set) var isReacting = false

    private enum State {
        case idle
        case walking
        case action(Int)
    }

    private var rows: [Int: [NSImage]] = [:]
    private var actionRows: [Int] = []
    private var state: State = .idle {
        didSet { stateStart = CACurrentMediaTime() }
    }
    private var stateStart = CACurrentMediaTime()
    private var frameIndex = 0
    private var position: CGFloat = 80
    private var travelFrom: CGFloat = 0
    private var travelTo: CGFloat = 0
    private var travelDuration: TimeInterval = 0
    private var nextDecision: TimeInterval = 0
    private var heartUntil: TimeInterval = 0
    private var timer: Timer?

    private let spriteSize = NSSize(width: 28, height: 30)
    private(set) var assetID: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let asset = PetLibrary.shared.selected()
        assetID = asset.id
        load(asset)
        nextDecision = CACurrentMediaTime() + 2
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stop() : start()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 15.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Frames

    func load(_ asset: PetAsset) {
        rows.removeAll()
        actionRows.removeAll()
        guard let url = asset.sheetURL, let image = NSImage(contentsOf: url) else {
            if asset.id != PetAsset.builtIn.id { load(.builtIn) }
            return
        }
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let sheet = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            if asset.id != PetAsset.builtIn.id { load(.builtIn) }
            return
        }

        let columns = 8
        let cellWidth = sheet.width / columns
        let cellHeight = Int((Double(cellWidth) * 13.0 / 12.0).rounded())
        guard cellWidth > 0, cellHeight > 0 else { return }
        let rowCount = sheet.height / cellHeight

        for row in 0..<rowCount {
            var frames: [NSImage] = []
            for column in 0..<columns {
                let rect = CGRect(x: column * cellWidth,
                                  y: row * cellHeight,
                                  width: cellWidth,
                                  height: cellHeight)
                guard let cropped = sheet.cropping(to: rect) else { continue }
                frames.append(NSImage(cgImage: cropped,
                                      size: NSSize(width: cellWidth, height: cellHeight)))
            }
            frames = PetRunView.trimTrailingBlanks(frames)
            if !frames.isEmpty { rows[row] = frames }
        }

        guard rows[0] != nil else {
            if asset.id != PetAsset.builtIn.id { load(.builtIn) }
            return
        }

        // Rows 0-2 are idle/walk; row 5 is tired. The remaining rows are
        // actions, including any extra dance rows in newer sheets.
        actionRows = (3..<rowCount).filter { $0 != 5 && rows[$0] != nil }
        if rows[5] != nil { actionRows.append(5) }

        assetID = asset.id
        beginIdle()
        needsDisplay = true
    }

    /// Trailing cells in action rows are often empty; drop them so the
    /// animation stops on the last real frame.
    private static func trimTrailingBlanks(_ frames: [NSImage]) -> [NSImage] {
        var frames = frames
        while frames.count > 1, let last = frames.last, isBlank(last) {
            frames.removeLast()
        }
        return frames
    }

    private static func isBlank(_ image: NSImage) -> Bool {
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
            return false
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        let stepX = max(1, rep.pixelsWide / 12)
        let stepY = max(1, rep.pixelsHigh / 12)
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { return false }
            }
        }
        return true
    }

    // MARK: - Animation

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = now - stateStart

        switch state {
        case .idle:
            frameIndex = Int(elapsed * 5) % max(currentFrames.count, 1)
            if now >= nextDecision, bounds.width > 0 {
                beginWalk()
            }
        case .walking:
            let progress = travelDuration <= 0 ? 1 : min(1, elapsed / travelDuration)
            let eased = progress * progress * (3 - 2 * progress)
            position = travelFrom + (travelTo - travelFrom) * eased
            frameIndex = Int(elapsed * 10) % max(currentFrames.count, 1)
            if progress >= 1 {
                arrive()
            }
        case .action(let row):
            let index = Int(elapsed * 9)
            if index >= (rows[row]?.count ?? 0) {
                isReacting = false
                beginIdle()
            } else {
                frameIndex = index
            }
        }
        needsDisplay = true
    }

    private var currentFrames: [NSImage] {
        switch state {
        case .idle:
            // Blink every few idle seconds by borrowing a wink frame.
            if let wink = rows[8]?.last, Int(CACurrentMediaTime() * 5) % 27 == 0 {
                return [wink]
            }
            return rows[0] ?? []
        case .walking:
            return rows[travelTo >= travelFrom ? 1 : 2] ?? rows[0] ?? []
        case .action(let row):
            return rows[row] ?? []
        }
    }

    private func beginWalk() {
        let half = spriteSize.width / 2
        var target = CGFloat.random(in: half...(max(bounds.width - half, half + 1)))
        if abs(target - position) < 50 {
            target = target > bounds.width / 2 ? half + 20 : bounds.width - half - 20
        }
        travelFrom = position
        travelTo = max(half, min(target, bounds.width - half))
        let distance = abs(travelTo - travelFrom)
        travelDuration = TimeInterval(distance / CGFloat.random(in: 30...48))
        state = .walking
        frameIndex = 0
    }

    private func arrive() {
        // Sometimes celebrate or dance after a stroll, otherwise rest.
        if Int.random(in: 0..<3) == 0, !actionRows.isEmpty {
            state = .action(actionRows.randomElement() ?? actionRows[0])
        } else {
            beginIdle()
        }
    }

    private func beginIdle() {
        state = .idle
        frameIndex = 0
        nextDecision = CACurrentMediaTime() + Double.random(in: 1.4...4.5)
    }

    override func layout() {
        super.layout()
        let half = spriteSize.width / 2
        if bounds.width > spriteSize.width {
            position = max(half, min(position, bounds.width - half))
        }
    }

    // MARK: - Drawing

    private var spriteRect: NSRect {
        NSRect(x: position - spriteSize.width / 2,
               y: (bounds.height - spriteSize.height) / 2,
               width: spriteSize.width,
               height: spriteSize.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let frames = currentFrames
        guard !frames.isEmpty else { return }
        let frame = frames[min(frameIndex, frames.count - 1)]
        guard frame.size.width > 0, frame.size.height > 0 else { return }
        frame.draw(in: spriteRect)

        let now = CACurrentMediaTime()
        if now < heartUntil {
            let remaining = heartUntil - now
            let alpha = min(1, remaining / 0.5)
            let heart = NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)
            heart?.draw(in: NSRect(x: spriteRect.maxX - 2, y: spriteRect.maxY - 4,
                                   width: 10, height: 10),
                        from: .zero, operation: .sourceOver, fraction: alpha)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let local = convert(point, from: superview)
        return spriteRect.insetBy(dx: -5, dy: -4).contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        react()
    }

    func react() {
        onPet?()
        isReacting = true
        if let row = actionRows.randomElement() {
            state = .action(row)
        } else {
            state = .action(0)
        }
        frameIndex = 0
        heartUntil = CACurrentMediaTime() + 1
        needsDisplay = true
    }
}
