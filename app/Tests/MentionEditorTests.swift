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

    /// 悬停预览靠这个命中：块身上要能认出是哪张图，块旁边一个字都不许误触。
    @Test func hoveringAChipFindsItsImage() throws {
        let view = MentionTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        view.font = .systemFont(ofSize: 13)
        view.insertMention(name: "图2", path: "/tmp/ref.jpg")
        view.appendText(" 后面的字")
        let layout = try #require(view.layoutManager)
        let container = try #require(view.textContainer)
        layout.ensureLayout(for: container)

        let chip = layout.boundingRect(forGlyphRange: NSRange(location: 0, length: 1), in: container)
        let hit = try #require(view.mention(at: NSPoint(x: chip.midX, y: chip.midY)))
        #expect(hit.name == "图2")
        #expect(hit.path == "/tmp/ref.jpg")
        // 块右边的文字、块的上下方都不该命中
        #expect(view.mention(at: NSPoint(x: chip.maxX + 6, y: chip.midY)) == nil)
        #expect(view.mention(at: NSPoint(x: chip.midX, y: chip.maxY + 30)) == nil)
    }

    /// 路径要跟着图片块一起存进富文本，否则从外面改字之后预览就找不到图了。
    @Test func chipKeepsItsImagePath() throws {
        let view = MentionTextView()
        view.insertMention(name: "图1", path: "/tmp/a.png")
        let storage = try #require(view.textStorage)
        #expect(storage.attribute(.mentionPath, at: 0, effectiveRange: nil) as? String == "/tmp/a.png")
        // 纯文字里仍然只说「图1」，发给模型的提示词不变。
        #expect(view.plainText == "图1 ")
    }

    @Test func aspectFillCoversTheSquare() {
        // 宽图：铺满后比格子宽，左右被裁
        let wide = MentionTextView.aspectFill(NSSize(width: 400, height: 100), in: NSRect(x: 0, y: 0, width: 20, height: 20))
        #expect(abs(wide.width - 80) < 0.01)
        #expect(abs(wide.height - 20) < 0.01)
        #expect(abs(wide.midX - 10) < 0.01)
        // 竖图：铺满后比格子高，上下被裁
        let tall = MentionTextView.aspectFill(NSSize(width: 100, height: 400), in: NSRect(x: 0, y: 0, width: 20, height: 20))
        #expect(abs(tall.height - 80) < 0.01)
        #expect(abs(tall.midY - 10) < 0.01)
    }
}
