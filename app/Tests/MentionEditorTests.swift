import AppKit
import Testing
@testable import PhotoEdit

@MainActor @Suite struct MentionEditorTests {
    @Test func mentionReplacesAtSignAtCursorInMiddle() {
        let view = MentionTextView()
        view.font = .systemFont(ofSize: 13)
        view.setPlainText("前@后@")
        view.setSelectedRange(NSRange(location: 2, length: 0))
        view.deleteTrailingAtSign()
        view.insertMention(name: "图2", path: nil)
        #expect(view.plainText == "前图2 后@")
    }

    @Test func mentionDoesNotRemoveUnrelatedAtSign() {
        let view = MentionTextView()
        view.setPlainText("文字@")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.deleteTrailingAtSign()
        #expect(view.plainText == "文字@")
    }

    @Test func referenceRemovalGuardTracksPromptChanges() {
        let model = MentionEditorModel()
        model.applyText("参考图2的构图")
        #expect(model.hasReferenceMentions)
        model.applyText("只修改图1")
        #expect(!model.hasReferenceMentions)
        model.applyText("参考图14")
        #expect(model.hasReferenceMentions)
    }

    @Test func consecutiveMentionsShareTheSameBaseline() throws {
        let view = MentionTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        view.font = .systemFont(ofSize: 13)
        for index in 1...3 { view.insertMention(name: "图\(index)", path: nil) }
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)
        let rects = [0, 2, 4].map { layout.boundingRect(forGlyphRange: NSRange(location: $0, length: 1), in: container) }
        #expect(rects.allSatisfy { abs($0.minY - rects[0].minY) < 0.5 })
    }
}
