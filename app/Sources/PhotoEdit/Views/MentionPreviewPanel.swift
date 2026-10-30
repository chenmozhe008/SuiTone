import AppKit

/// 鼠标停在（或点中）输入框里的「图N」图片块上时，浮出来的一张小预览：
/// 图片铺满卡片，左上角一行「图N · 文件名」，和即梦那种「@ 一张图能看见是哪张」一样。
/// 只负责画和摆位置，不接鼠标事件——挡在字上面也不会把输入框的悬停打断。
final class MentionPreviewPanel: NSPanel {
    private let card = MentionPreviewCard()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        contentView = card
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var showingKey: String?

    /// 在 `anchor`（屏幕坐标，图片块自己的矩形）正上方弹出；上面放不下就落到下方。
    func show(key: String, image: NSImage, caption: String, above anchor: NSRect) {
        guard let size = Self.cardSize(for: image) else { return }
        card.image = image
        card.caption = caption

        let gap: CGFloat = 8
        var origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.maxY + gap)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) ?? NSScreen.main {
            let area = screen.visibleFrame
            if origin.y + size.height > area.maxY {
                origin.y = anchor.minY - size.height - gap
            }
            origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
            origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        }

        showingKey = key
        card.frame = NSRect(origin: .zero, size: size)
        setFrame(NSRect(origin: origin, size: size), display: true)
        if !isVisible { orderFrontRegardless() } else { card.needsDisplay = true }
    }

    func hide() {
        showingKey = nil
        if isVisible { orderOut(nil) }
    }

    /// 预览最多 300×220，按原图比例缩；小图不硬放大，避免糊成马赛克。
    private static func cardSize(for image: NSImage) -> NSSize? {
        let source = image.size
        guard source.width > 1, source.height > 1 else { return nil }
        let maxWidth: CGFloat = 300
        let maxHeight: CGFloat = 220
        let scale = min(maxWidth / source.width, maxHeight / source.height, 1)
        let size = NSSize(width: (source.width * scale).rounded(), height: (source.height * scale).rounded())
        guard size.width >= 40, size.height >= 40 else { return nil }
        return size
    }
}

private final class MentionPreviewCard: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var caption = "" { didSet { needsDisplay = true } }

    private static let corner: CGFloat = 10
    private static let captionFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        context.saveGState()
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil))
        context.clip()
        NSColor(white: 0.13, alpha: 1).setFill()
        bounds.fill()
        if let image {
            // 卡片尺寸就是按比例算出来的，这里铺满不会变形。
            image.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        }
        drawCaption(in: bounds)
        context.restoreGState()

        NSColor(white: 1, alpha: 0.16).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                  xRadius: Self.corner, yRadius: Self.corner)
        border.lineWidth = 1
        border.stroke()
    }

    /// 左下角一枚深色小胶囊，照片再亮也压得住字。
    private func drawCaption(in bounds: NSRect) {
        guard !caption.isEmpty else { return }
        let font = Self.captionFont
        let inset: CGFloat = 8
        let padding = NSSize(width: 8, height: 3)
        let limit = bounds.width - inset * 2 - padding.width * 2

        var text = caption as NSString
        var size = text.size(withAttributes: [.font: font])
        if size.width > limit, limit > 20 {
            var cut = caption
            while !cut.isEmpty {
                cut = String(cut.dropLast())
                let candidate = (cut + "…") as NSString
                let width = candidate.size(withAttributes: [.font: font]).width
                if width <= limit { text = candidate; size = NSSize(width: width, height: size.height); break }
            }
        }

        let capsule = NSRect(x: inset, y: inset,
                             width: min(size.width + padding.width * 2, bounds.width - inset * 2),
                             height: size.height + padding.height * 2)
        NSColor(white: 0, alpha: 0.62).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2).fill()
        text.draw(at: NSPoint(x: capsule.minX + padding.width, y: capsule.minY + padding.height),
                  withAttributes: [.font: font, .foregroundColor: NSColor.white])
    }
}
