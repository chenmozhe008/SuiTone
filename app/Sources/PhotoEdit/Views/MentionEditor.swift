import AppKit
import SwiftUI

/// 「@ 一张图」的输入框：图片不是默认列一串，而是打了 @ 选完才以图片块的形式嵌进文字里。
/// 发给模型的文字里，图片块会还原成「图1」「图2」，跟插入顺序一致。
extension NSAttributedString.Key {
    static let mentionName = NSAttributedString.Key("suitone.mentionName")
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
        chip.addAttribute(.mentionName, value: name, range: NSRange(location: 0, length: chip.length))
        chip.addAttribute(.font, value: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                          range: NSRange(location: 0, length: chip.length))
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

    /// 只解码缩略图尺寸的像素（ImageIO 直接抽缩），不会为了画 11pt 去读整张 6000px 的原图。
    private static func thumbnail(path: String, side: CGFloat) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(2, Int(side * 3)),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: side, height: side))
    }

    /// 图片引用与正文使用相近字号，保持缩略图与文字居中对齐。
    private func chipImage(name: String, path: String?) -> NSImage {
        let key = "\(name)|\(path ?? "")" as NSString
        if let cached = Self.chipCache.object(forKey: key) { return cached }
        let height: CGFloat = 20
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let text = name as NSString
        let textSize = text.size(withAttributes: [.font: font])
        let textWidth = textSize.width
        let thumbSide: CGFloat = 14
        let width = 3 + thumbSide + 3 + textWidth + 6
        let size = NSSize(width: ceil(width), height: height)

        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let body = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: height / 2, yRadius: height / 2)
        NSColor(white: 0.28, alpha: 1).setFill()
        body.fill()
        NSColor(white: 1, alpha: 0.18).setStroke()
        body.lineWidth = 0.8
        body.stroke()

        if let path, let thumbnail = Self.thumbnail(path: path, side: thumbSide) {
            let rect = NSRect(x: 3, y: (height - thumbSide) / 2, width: thumbSide, height: thumbSide)
            let clip = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            thumbnail.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
        }

        let textRect = NSRect(x: 3 + thumbSide + 3, y: (height - textSize.height) / 2,
                              width: textWidth, height: textSize.height)
        text.draw(in: textRect, withAttributes: [.font: font, .foregroundColor: NSColor.white])
        Self.chipCache.setObject(image, forKey: key)
        return image
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
