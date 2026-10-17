import AppKit
import Testing
@testable import ClipboardBridge

/// Uses a uniquely named pasteboard so the user's real clipboard is never touched.
@MainActor
@Suite("Clipboard transaction (real NSPasteboard)")
struct ClipboardTransactionTests {
    let raw: NSPasteboard
    let pasteboard: SystemPasteboard

    init() {
        raw = NSPasteboard(name: NSPasteboard.Name("LayoutFixTests-\(UUID().uuidString)"))
        pasteboard = SystemPasteboard(raw)
    }

    private func putUserContent() {
        raw.clearContents()
        let first = NSPasteboardItem()
        first.setString("original text", forType: .string)
        first.setData(Data("{\\rtf1 original}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
        raw.writeObjects([first, second])
    }

    @Test("All items and types are restored after our write")
    func restoresEverything() throws {
        putUserContent()
        let before = try pasteboard.snapshot()
        let tx = try ClipboardTransaction(pasteboard: pasteboard)
        _ = tx.write("변환된 텍스트")
        #expect(tx.finish() == .restored)
        #expect(try pasteboard.snapshot() == before)
        #expect(raw.pasteboardItems?.count == 2)
        #expect(raw.string(forType: .string) == "original text")
        #expect(raw.pasteboardItems?[1].data(forType: .png) == Data([0x89, 0x50, 0x4E, 0x47]))
        raw.releaseGlobally()
    }

    @Test("Newer content written by someone else is kept")
    func keepsNewerContent() throws {
        putUserContent()
        let tx = try ClipboardTransaction(pasteboard: pasteboard)
        _ = tx.write("temporary")
        raw.clearContents()
        raw.setString("user copied this later", forType: .string)
        #expect(tx.finish() == .keptNewerContent)
        #expect(raw.string(forType: .string) == "user copied this later")
        raw.releaseGlobally()
    }

    @Test("A copy we triggered is accepted, then the original is restored")
    func acceptsTriggeredCopy() throws {
        putUserContent()
        let tx = try ClipboardTransaction(pasteboard: pasteboard)
        raw.clearContents()
        raw.setString("copied from target app", forType: .string) // what ⌘C in the target does
        tx.acceptCurrentChange()
        #expect(tx.finish() == .restored)
        #expect(raw.string(forType: .string) == "original text")
        #expect(tx.finish() == .alreadyFinished)
        raw.releaseGlobally()
    }

    @Test("Empty clipboard is restored as empty")
    func emptyClipboard() throws {
        raw.clearContents()
        let tx = try ClipboardTransaction(pasteboard: pasteboard)
        _ = tx.write("temporary")
        #expect(tx.finish() == .restored)
        #expect(raw.pasteboardItems?.isEmpty ?? true)
        raw.releaseGlobally()
    }

    @Test("Our text is lazy, marked transient/concealed, and reading it is detected")
    func lazyTransientWrite() {
        putUserContent()
        let handle = pasteboard.writeTransientString("안녕")
        let types = raw.types?.map(\.rawValue) ?? []
        #expect(types.contains(PasteboardMarkers.transient))
        #expect(types.contains(PasteboardMarkers.concealed))
        #expect(!handle.wasRead)
        #expect(raw.string(forType: .string) == "안녕")
        #expect(handle.wasRead)
        raw.releaseGlobally()
    }

    @Test("A representation that cannot be read makes the transaction refuse, leaving the clipboard alone")
    func unreadableData() {
        raw.clearContents()
        let item = NSPasteboardItem()
        item.setString("visible", forType: .string)
        item.setDataProvider(NeverProvides(), forTypes: [NSPasteboard.PasteboardType("com.example.promised")])
        raw.writeObjects([item])
        let changeCount = raw.changeCount
        #expect(throws: ClipboardUnavailable.unreadable) { try ClipboardTransaction(pasteboard: pasteboard) }
        #expect(raw.changeCount == changeCount)
        #expect(raw.string(forType: .string) == "visible")
        raw.releaseGlobally()
    }

    @Test("A clipboard nothing changed is not rewritten")
    func untouched() throws {
        putUserContent()
        let changeCount = raw.changeCount
        let tx = try ClipboardTransaction(pasteboard: pasteboard)
        #expect(tx.finish() == .untouched)
        #expect(raw.changeCount == changeCount)
        raw.releaseGlobally()
    }

    @Test("Type order inside an item survives the round trip")
    func typeOrder() throws {
        raw.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
        item.setString("plain", forType: .string)
        item.setData(Data("<b>html</b>".utf8), forType: .html)
        raw.writeObjects([item])
        let order = raw.pasteboardItems?.first?.types.map(\.rawValue)
        let tx = try ClipboardTransaction(pasteboard: pasteboard)
        _ = tx.write("temporary")
        #expect(tx.finish() == .restored)
        #expect(raw.pasteboardItems?.first?.types.map(\.rawValue) == order)
        raw.releaseGlobally()
    }

    @Test("Concealed content (password managers) is refused")
    func concealed() {
        raw.clearContents()
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarkers.concealed))
        raw.writeObjects([item])
        #expect(throws: ClipboardUnavailable.sensitiveContent) { try ClipboardTransaction(pasteboard: pasteboard) }
        #expect(raw.string(forType: .string) == "hunter2")
        raw.releaseGlobally()
    }
}

/// A promise that is never kept, like data from an app that has quit.
final class NeverProvides: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}
