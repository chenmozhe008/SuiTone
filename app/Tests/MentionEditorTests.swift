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
}
