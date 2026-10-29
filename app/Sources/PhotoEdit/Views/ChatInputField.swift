import AppKit
import SwiftUI

/// 对话输入框：回车发送，Shift＋回车换行。输入法还在选字（有未确认的拼音）时，回车交给输入法，不会误发。
struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = SubmitTextView(frame: .zero)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.delegate = context.coordinator
        view.placeholder = placeholder
        view.onSubmit = { context.coordinator.parent.onSubmit() }
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? SubmitTextView else { return }
        if view.string != text && !view.hasMarkedText() { view.string = text; view.needsDisplay = true }
        view.placeholder = placeholder
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField
        init(parent: ChatInputField) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
        }
    }
}

final class SubmitTextView: NSTextView {
    var onSubmit: () -> Void = {}
    var placeholder = "" { didSet { needsDisplay = true } }

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if isReturn && !hasMarkedText() && !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.option) {
            onSubmit()
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 14), .foregroundColor: NSColor.tertiaryLabelColor]
        placeholder.draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}
