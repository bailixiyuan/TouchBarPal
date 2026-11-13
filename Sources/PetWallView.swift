import AppKit
import QuartzCore

/// Horizontal gallery of every pet, drawn as a seamless marquee.
///
/// The row is laid out as CALayers and repeated enough times to cover the bar,
/// so scrolling by one full set width wraps invisibly: there is no jump-back at
/// the ends. Pets idle-animate in place while the row glides continuously.
final class PetWallView: NSView {
    var onSelect: ((PetAsset) -> Void)?

    private(set) var isScrolling = false
    private(set) var offset: CGFloat = 0

    private var assets: [PetAsset] = []
    private var frames: [String: [CGImage]] = [:]
    private var selectedID = AppSettings.shared.selectedPetID

    private let foreground = CALayer()
    private let background = CALayer()
    private let selectionDot = CALayer()
    private var petLayers: [PetLayer] = []
    private var ghostLayers: [PetLayer] = []

    private var ghostOffset: CGFloat = 0
    private var lastTick = CACurrentMediaTime()
    private var timer: Timer?
    private var animationTimer: Timer?
    private var repeats = 1
    private var dragOrigin: NSPoint?

    private let pitch: CGFloat = 62
    private let petWidth: CGFloat = 36
    private let petHeight: CGFloat = 24
    private let ghostScale: CGFloat = 0.7
    private let speed: CGFloat = 30

    /// Width of one full set of pets; a multiple of this is always on screen.
    var setWidth: CGFloat {
        max(CGFloat(assets.count) * pitch, 1)
    }

    private var overflow: CGFloat {
        max(0, setWidth - (bounds.width > 0 ? bounds.width : 840))
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setUp()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    deinit {
        timer?.invalidate()
        animationTimer?.invalidate()
    }

    private func setUp() {
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(background)
        layer?.addSublayer(foreground)
        selectionDot.cornerRadius = 1.5
        selectionDot.backgroundColor = NSColor.white.withAlphaComponent(0.9).cgColor
        layer?.addSublayer(selectionDot)
        selectionDot.isHidden = true
        for container in [foreground, background] {
            container.actions = ["sublayers": NSNull(), "position": NSNull()]
        }
    }

    // MARK: - Content

    func configure(assets: [PetAsset]) {
        self.assets = assets
        frames.removeAll()
        for asset in assets {
            frames[asset.id] = Self.idleFrames(for: asset)
        }
        selectedID = AppSettings.shared.selectedPetID
        offset = 0
        ghostOffset = 0
        rebuildLayers()
        startTimers()
    }

    func select(_ asset: PetAsset) {
        selectedID = asset.id
        updateSelection()
        onSelect?(asset)
    }

    /// Frame count of one pet, used by the self-test.
    func frameCount(for asset: PetAsset) -> Int {
        frames[asset.id]?.count ?? 0
    }

    /// Decodes the sheet at a reduced size via ImageIO, so a 17-pet wall does
    /// not pull every full-resolution atlas into memory.
    private static func idleFrames(for asset: PetAsset) -> [CGImage] {
        guard let url = asset.sheetURL,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 8 * 96,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let sheet = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return [] }

        let cellWidth = sheet.width / 8
        let cellHeight = Int((Double(cellWidth) * 13.0 / 12.0).rounded())
        guard cellWidth > 0, cellHeight > 0,
              sheet.height >= cellHeight else { return [] }

        var result: [CGImage] = []
        for column in 0..<8 {
            let rect = CGRect(x: column * cellWidth, y: 0,
                              width: cellWidth, height: cellHeight)
            guard let cropped = sheet.cropping(to: rect) else { continue }
            result.append(cropped)
        }
        // Trailing cells are often empty; drop them so the loop never blinks out.
        while result.count > 1, let last = result.last, isBlank(last) {
            result.removeLast()
        }
        return result
    }

    private static func isBlank(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        let stepX = max(1, rep.pixelsWide / 12)
        let stepY = max(1, rep.pixelsHigh / 12)
        for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
                if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 { return false }
            }
        }
        return true
    }

    // MARK: - Layers

    private final class PetLayer: CALayer {
        var petIndex = 0
        var frameIndex = 0
        var isGhost = false
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func rebuildLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in petLayers { layer.removeFromSuperlayer() }
        for layer in ghostLayers { layer.removeFromSuperlayer() }
        petLayers.removeAll()
        ghostLayers.removeAll()
        selectionDot.isHidden = true
        guard !assets.isEmpty else {
            CATransaction.commit()
            stopScrolling()
            return
        }

        let width = bounds.width > 0 ? bounds.width : 840
        // One extra set guarantees coverage even when the visible width is just
        // under a set width and the row has wrapped.
        repeats = max(1, Int(ceil((width + setWidth) / setWidth)) + 1)
        let total = repeats * assets.count
        let scale = backingScale

        for index in 0..<total {
            let petIndex = index % assets.count
            for ghost in [false, true] {
                let layer = PetLayer()
                layer.petIndex = petIndex
                layer.isGhost = ghost
                layer.contentsGravity = .resizeAspect
                layer.contentsScale = scale
                layer.magnificationFilter = .linear
                layer.minificationFilter = .linear
                layer.actions = ["contents": NSNull(), "position": NSNull(),
                                 "bounds": NSNull(), "opacity": NSNull()]
                let height = ghost ? petHeight * ghostScale : petHeight
                layer.bounds = CGRect(x: 0, y: 0, width: petWidth, height: height)
                layer.opacity = ghost ? 0.14 : (isChosen(petIndex) ? 1 : 0.72)
                layer.contents = frames[assets[petIndex].id]?.first
                if ghost {
                    background.addSublayer(layer)
                    ghostLayers.append(layer)
                } else {
                    foreground.addSublayer(layer)
                    petLayers.append(layer)
                }
            }
        }
        CATransaction.commit()

        layoutLayers()
        updateSelection()
    }

    private func isChosen(_ index: Int) -> Bool {
        index < assets.count && assets[index].id == selectedID
    }

    /// Only positions change while scrolling; bounds/contents are set once at
    /// rebuild time so Core Animation never re-rasterises during the marquee.
    private func layoutLayers() {
        for (index, layer) in petLayers.enumerated() {
            let x = CGFloat(index) * pitch - offset
            layer.position = CGPoint(x: x + pitch / 2, y: bounds.midY)
        }
        for (index, layer) in ghostLayers.enumerated() {
            let x = CGFloat(index) * pitch - ghostOffset
            layer.position = CGPoint(x: x + pitch / 2, y: bounds.midY + 1)
        }

        guard let chosen = assets.firstIndex(where: { $0.id == selectedID }) else {
            selectionDot.isHidden = true
            return
        }
        // Pick the copy of the chosen pet that is actually on screen.
        var x = wrappedX(CGFloat(chosen) * pitch - offset)
        if x > bounds.width { x -= setWidth }
        guard x > -pitch, x < bounds.width else {
            selectionDot.isHidden = true
            return
        }
        selectionDot.isHidden = false
        selectionDot.bounds = CGRect(x: 0, y: 0, width: 8, height: 3)
        selectionDot.position = CGPoint(x: x + pitch / 2, y: 2)
    }

    /// Repeats make any x position equivalent modulo the set width.
    private func wrappedX(_ x: CGFloat) -> CGFloat {
        var value = x.truncatingRemainder(dividingBy: setWidth)
        if value < 0 { value += setWidth }
        return value
    }

    private func updateSelection() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in petLayers {
            layer.opacity = isChosen(layer.petIndex) ? 1 : 0.72
        }
        CATransaction.commit()
        layoutLayers()
    }

    // MARK: - Animation

    private func startTimers() {
        if timer == nil, overflow > 0 {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            lastTick = CACurrentMediaTime()
            isScrolling = true
        } else if overflow <= 0 {
            stopScrolling()
        }

        if animationTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 10.0, repeats: true) { [weak self] _ in
                self?.advanceFrames()
            }
            RunLoop.main.add(timer, forMode: .common)
            animationTimer = timer
        }
    }

    private func stopScrolling() {
        timer?.invalidate()
        timer = nil
        isScrolling = false
    }

    /// Advances the marquee by `elapsed` seconds. Wrapping at the set width is
    /// invisible because the layer row repeats at exactly that period.
    func tick(_ elapsed: TimeInterval? = nil) {
        let now = CACurrentMediaTime()
        let delta = elapsed ?? min(now - lastTick, 0.05)
        lastTick = now
        guard overflow > 0 else { return }

        offset = wrappedX(offset + speed * CGFloat(delta))
        ghostOffset = wrappedX(offset * 0.45)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    private func advanceFrames() {
        guard !assets.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in petLayers + ghostLayers {
            guard let list = frames[assets[layer.petIndex].id], list.count > 1 else { continue }
            layer.frameIndex = (layer.frameIndex + 1) % list.count
            layer.contents = list[layer.frameIndex]
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let width = bounds.width > 0 ? bounds.width : 840
        let needed = max(1, Int(ceil((width + setWidth) / setWidth)))
        if needed != repeats {
            rebuildLayers()
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            background.frame = bounds
            foreground.frame = bounds
            layoutLayers()
            CATransaction.commit()
        }
        if overflow > 0 {
            startTimers()
        } else {
            stopScrolling()
        }
    }

    // MARK: - Interaction

    private func petIndex(at point: NSPoint) -> Int? {
        guard !assets.isEmpty else { return nil }
        let local = wrappedX(point.x + offset)
        let index = Int(local / pitch)
        guard index >= 0, index < assets.count else { return nil }
        let center = CGFloat(index) * pitch + pitch / 2
        return abs(local - center) <= petWidth / 2 + 4 ? index : nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let index = petIndex(at: point) {
            dragOrigin = nil
            select(assets[index])
        } else {
            dragOrigin = point
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        offset = wrappedX(offset - (point.x - origin.x))
        ghostOffset = wrappedX(offset * 0.45)
        dragOrigin = point
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layoutLayers()
        CATransaction.commit()
    }

    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        lastTick = CACurrentMediaTime()
    }
}
