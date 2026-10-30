import AppKit
import SwiftUI

/// 「@ 一张图」的输入框：图片不是默认列一串，而是打了 @ 选完才以图片块的形式嵌进文字里。
/// 发给模型的文字里，图片块会还原成「图1」「图2」，跟插入顺序一致。
extension NSAttributedString.Key {
    static let mentionName = NSAttributedString.Key("suitone.mentionName")
    /// 图片块对应的文件路径：删掉又插、或者从外面改字之后，鼠标悬停还能找到那张图。
    static let mentionPath = NSAttributedString.Key("suitone.mentionPath")
}

extension Notification.Name {
    /// 验收用：让输入框把第一张图片块的预览弹出来（截图核对小图长什么样）。
    static let debugMentionPreview = Notification.Name("suitone.debugMentionPreview")
}

/// SwiftUI 与文本视图之间的桥：文字内容、@ 触发、插入图片块都从这里走。
@MainActor
final class MentionEditorModel: ObservableObject {
    /// 只有「空 / 非空」变化才通知界面。每敲一个字就 @Published 一次，会把整个面板
    /// （含参考图缩略图解码）重画一遍，打 @ 时就卡。
    @Published private(set) var isEmpty = true
    @Published private(set) var hasReferenceMentions = false
    private(set) var text = ""
    weak var view: MentionTextView?

    func applyText(_ value: String) {
        text = value
        let empty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if empty != isEmpty { isEmpty = empty }
        let hasReferences = value.range(of: "图(?:[2-9]|1[0-4])", options: .regularExpression) != nil
        if hasReferences != hasReferenceMentions { hasReferenceMentions = hasReferences }
    }

    func insert(name: String, path: String?) { view?.insertMention(name: name, path: path) }
    func setText(_ value: String) { view?.setPlainText(value) }
}

final class MentionTextView: NSTextView {
    var onText: ((String) -> Void)?
    var onMention: (() -> Void)?
    /// 继续打字时通知外面（用来收起 @ 列表）
    var onTyping: (() -> Void)?
    var placeholder = "" {
        didSet { needsDisplay = true }
    }

    // MARK: 图片块的小预览

    /// 鼠标停在「图N」上、或者点一下它，就在上面浮一张小图告诉用户这是哪张照片。
    private var previewPanel: MentionPreviewPanel?
    /// 点过之后小图不再跟着鼠标走，再点一下或换个地方点才收。
    private var previewPinned = false
    private var hoverKey: String?
    private var pendingHover: DispatchWorkItem?
    private var hoverTracking: NSTrackingArea?
    private var observers: [NSObjectProtocol] = []

    /// 纯文字：图片块还原成「图N」，其余原样。生成时发的就是这段。
    var plainText: String {
        guard let storage = textStorage else { return string }
        var out = ""
        let whole = storage.string as NSString
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
            if let name = attributes[.mentionName] as? String { out += name }
            else { out += whole.substring(with: range) }
        }
        return out
    }

    /// 在光标处替换触发候选列表的 @，支持在已有文字中间插入。
    func deleteTrailingAtSign() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let whole = storage.string as NSString
        let cursor = selectedRange()
        guard cursor.length == 0, cursor.location > 0, cursor.location <= storage.length,
              whole.substring(with: NSRange(location: cursor.location - 1, length: 1)) == "@" else { return }
        let range = NSRange(location: cursor.location - 1, length: 1)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.replaceCharacters(in: range, with: "")
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: 0))
    }

    override func didChangeText() {
        super.didChangeText()
        onText?(plainText)
        onTyping?()
        needsDisplay = textStorage?.length == 0
        hidePreview(force: true)
    }

    // MARK: - 图片块预览

    /// 文本视图要能收到 mouseMoved，靠的是这块铺满可视区的 tracking area；
    /// 只挂一次，滚动和改窗口大小时由 .inVisibleRect 自己跟着走。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        guard let window else { hidePreview(force: true); return }
        window.acceptsMouseMovedEvents = true
        // 窗口失焦、滚动、换尺寸：预览停在一个跟图片无关的位置上不如收起来。
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePreview(force: true) }
        })
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hidePreview(force: true) }
            })
        }
        // 验收用：`-debugMentionPreview` 让第一张图片块直接弹出预览（不用真鼠标去悬停）。
        observers.append(center.addObserver(forName: .debugMentionPreview, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.debugPreviewFirstMention() }
        })
    }

    /// 验收钩子：找到第一张图片块，按它自己的矩形把预览弹出来，并把结果打到标准输出。
    func debugPreviewFirstMention() {
        guard let storage = textStorage, storage.length > 0 else { print("debugMention 没有文字"); fflush(stdout); return }
        var found: Int?
        storage.enumerateAttribute(.mentionName, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            if value != nil { found = range.location; stop.pointee = true }
        }
        guard let index = found, let layout = layoutManager, let container = textContainer else {
            print("debugMention 没找到图片块"); fflush(stdout); return
        }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        // 顺手自测一次命中：块中心应该命中，块右边 40pt 之外应该不命中。
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let beside = NSPoint(x: rect.maxX + 40, y: rect.midY)
        let hit = mention(at: center)
        print("debugMention 命中=\(hit?.name ?? "无") 旁边命中=\(mention(at: beside)?.name ?? "无")")
        guard let hit else { fflush(stdout); return }
        present(hit)
        previewPinned = true
        print("debugMention 预览 \(hit.name) path=\(hit.path) 块=\(rect) 悬浮窗=\(previewPanel?.frame ?? .zero) 可见=\(previewPanel?.isVisible ?? false)")
        fflush(stdout)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = mention(at: point) else {
            hidePreview(force: false)
            return
        }
        if previewPanel?.isVisible == true, previewPinned { return }
        if hoverKey == hit.key, previewPanel?.isVisible == true { return }
        // 鼠标扫过一行字时不要一路弹，稍微停一下才算「看这张」。
        pendingHover?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.present(hit) }
        }
        pendingHover = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        pendingHover?.cancel()
        hoverKey = nil
        hidePreview(force: false)
    }

    /// 点图片块＝把小图钉住看；点别处先收起来，再照常放光标。
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = mention(at: point) else {
            if previewPanel?.isVisible == true { hidePreview(force: true) }
            super.mouseDown(with: event)
            return
        }
        pendingHover?.cancel()
        if previewPanel?.isVisible == true, previewPinned, hoverKey == hit.key {
            hidePreview(force: true)
        } else {
            present(hit)
            previewPinned = true
        }
        window?.makeFirstResponder(self)
    }

    override func cancelOperation(_ sender: Any?) {
        if previewPanel?.isVisible == true { hidePreview(force: true) } else { super.cancelOperation(sender) }
    }

    override func resignFirstResponder() -> Bool {
        hidePreview(force: true)
        return super.resignFirstResponder()
    }

    /// 光标处（或鼠标处）落在哪个图片块上；命中不成矩形就当没点到，免得旁边一个字也弹图。
    func mention(at point: NSPoint) -> (key: String, name: String, path: String, rect: NSRect)? {
        guard let layout = layoutManager, let container = textContainer,
              let storage = textStorage, storage.length > 0 else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < storage.length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        let textRect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        guard textRect.insetBy(dx: -1, dy: -2).contains(local) else { return nil }
        guard let name = storage.attribute(.mentionName, at: index, effectiveRange: nil) as? String,
              let path = storage.attribute(.mentionPath, at: index, effectiveRange: nil) as? String,
              !path.isEmpty else { return nil }
        let rect = textRect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        return ("\(name)|\(path)", name, path, rect)
    }

    private func present(_ hit: (key: String, name: String, path: String, rect: NSRect)) {
        guard let window, let image = Self.previewImage(path: hit.path) else { return }
        let panel = previewPanel ?? {
            let panel = MentionPreviewPanel()
            previewPanel = panel
            return panel
        }()
        hoverKey = hit.key
        panel.show(key: hit.key,
                   image: image,
                   caption: "\(hit.name) · \((hit.path as NSString).lastPathComponent)",
                   above: window.convertToScreen(convert(hit.rect, to: nil)))
    }

    private func hidePreview(force: Bool) {
        guard force || !previewPinned else { return }
        pendingHover?.cancel()
        pendingHover = nil
        previewPinned = false
        hoverKey = nil
        previewPanel?.hide()
    }


    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        // 刚打出一个 @：让界面弹出可引用的图片
        if let typed = string as? String, typed == "@" { onMention?() }
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        // 占位文字跟着文本容器一起排，所以和光标永远在同一条基线上。
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding, y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    /// 插一个图片块（缩略图 + 「图N」），后面跟一个空格。
    func insertMention(name: String, path: String?) {
        guard let storage = textStorage else { return }
        let chip = NSMutableAttributedString(attachment: chipAttachment(name: name, path: path))
        let chipRange = NSRange(location: 0, length: chip.length)
        chip.addAttribute(.mentionName, value: name, range: chipRange)
        if let path { chip.addAttribute(.mentionPath, value: path, range: chipRange) }
        chip.addAttribute(.font, value: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize), range: chipRange)
        chip.append(NSAttributedString(string: " ", attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]))
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.replaceCharacters(in: range, with: chip)
        didChangeText()
        setSelectedRange(NSRange(location: min(range.location + chip.length, storage.length), length: 0))
        window?.makeFirstResponder(self)
    }

    /// 在末尾追加一段纯文字（验收脚本拼提示词用）。
    func appendText(_ value: String) {
        guard let storage = textStorage else { return }
        storage.append(NSAttributedString(string: value, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]))
        didChangeText()
    }

    func setPlainText(_ value: String) {
        guard let storage = textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: value, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
        ]))
        didChangeText()
        setSelectedRange(NSRange(location: storage.length, length: 0))
    }

    private func chipAttachment(name: String, path: String?) -> NSTextAttachment {
        let attachment = NSTextAttachment()
        let image = chipImage(name: name, path: path)
        attachment.image = image
        // 图片块要落在文字行的正中间：用字体自身的 ascent/descent 算中线，
        // 不写死偏移量——换字号、换系统版本都不会再往上飘。
        let metrics = font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let center = (metrics.ascender + metrics.descender) / 2
        attachment.bounds = CGRect(x: 0, y: center - image.size.height / 2,
                                   width: image.size.width, height: image.size.height)
        return attachment
    }

    private static let chipCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    private static let previewCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 24
        return cache
    }()

    /// 只解码缩略图尺寸的像素（ImageIO 直接抽缩），不会为了画 16pt 去读整张 6000px 的原图。
    /// 返回的是**原比例**的小图：方块里怎么摆放由调用方裁，别在这里拉变形。
    private static func thumbnail(path: String, maxPixel: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(2, maxPixel),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// 悬停预览用：长边 560 像素足够铺满 280pt 的卡片，视网膜屏也不虚。
    private static func previewImage(path: String) -> NSImage? {
        let key = path as NSString
        if let cached = previewCache.object(forKey: key) { return cached }
        guard let image = thumbnail(path: path, maxPixel: 560) else { return nil }
        previewCache.setObject(image, forKey: key, cost: 560 * 560 * 4)
        return image
    }

    /// 图片块：一张方缩略图 + 「图N」。整块按 2 倍像素画，视网膜屏上不糊。
    private func chipImage(name: String, path: String?) -> NSImage {
        let key = "\(name)|\(path ?? "")" as NSString
        if let cached = Self.chipCache.object(forKey: key) { return cached }

        let height: CGFloat = 22
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = name as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let thumbSide: CGFloat = 16
        let leftInset: CGFloat = 3
        let gap: CGFloat = 4
        let width = leftInset + thumbSide + gap + textSize.width + 7
        let size = NSSize(width: ceil(width), height: height)

        let scale: CGFloat = 2
        let image = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return image }
        rep.size = size
        image.addRepresentation(rep)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let body = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: height / 2, yRadius: height / 2)
        NSColor(white: 0.28, alpha: 1).setFill()
        body.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        body.lineWidth = 0.8
        body.stroke()

        if let path, let thumbnail = Self.thumbnail(path: path, maxPixel: Int(thumbSide * 4)) {
            let rect = NSRect(x: leftInset, y: (height - thumbSide) / 2, width: thumbSide, height: thumbSide)
            let clip = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            // 铺满方格再裁：竖图横图都不会被拉扁。
            let fill = Self.aspectFill(thumbnail.size, in: rect)
            thumbnail.draw(in: fill, from: .zero, operation: .sourceOver, fraction: 1,
                           respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }

        let textRect = NSRect(x: leftInset + thumbSide + gap, y: (height - textSize.height) / 2,
                              width: textSize.width, height: textSize.height)
        text.draw(in: textRect, withAttributes: [.font: font, .foregroundColor: NSColor.white])

        NSGraphicsContext.restoreGraphicsState()
        Self.chipCache.setObject(image, forKey: key)
        return image
    }

    /// 把 `source` 比例的画面铺满 `rect`（超出部分裁掉），返回要画的矩形（可能比 rect 大）。
    static func aspectFill(_ source: NSSize, in rect: NSRect) -> NSRect {
        guard source.width > 0, source.height > 0 else { return rect }
        let scale = max(rect.width / source.width, rect.height / source.height)
        let size = NSSize(width: source.width * scale, height: source.height * scale)
        return NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

/// 把 MentionTextView 包进 SwiftUI：没有背景、没有边框，样式交给外层容器。
struct MentionEditor: NSViewRepresentable {
    @ObservedObject var model: MentionEditorModel
    var placeholder: String
    /// 打了 @：外层据此展开候选列表
    var onMention: () -> Void
    /// 继续打字：外层据此收起候选列表
    var onTyping: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        let text = MentionTextView()
        text.drawsBackground = false
        text.isRichText = false
        text.isEditable = true
        text.isSelectable = true
        text.allowsUndo = true
        text.font = .systemFont(ofSize: NSFont.systemFontSize)
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = true
        text.isHorizontallyResizable = false
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.placeholder = placeholder
        text.onText = { value in context.coordinator.update(value) }
        text.onMention = onMention
        text.onTyping = onTyping
        text.string = ""
        scroll.documentView = text
        model.view = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? MentionTextView else { return }
        text.onMention = onMention
        text.onTyping = onTyping
        text.placeholder = placeholder
        if text.plainText != model.text, !text.hasMarkedText() { text.setPlainText(model.text) }
        model.view = text
    }

    final class Coordinator {
        let model: MentionEditorModel
        init(model: MentionEditorModel) { self.model = model }
        func update(_ value: String) {
            // 回调一定发生在主线程（文本视图的编辑事件），这里只是把隔离信息补上。
            MainActor.assumeIsolated {
                model.applyText(value)
            }
        }
    }
}
