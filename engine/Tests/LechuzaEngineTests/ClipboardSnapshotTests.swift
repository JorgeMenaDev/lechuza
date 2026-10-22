import AppKit
import XCTest

@testable import LechuzaEngine

/// Dictation pastes through the clipboard and puts back what was there.
final class ClipboardSnapshotTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private let custom = NSPasteboard.PasteboardType("app.lechuza.test.custom")

    override func setUp() {
        pasteboard = NSPasteboard(name: .init("app.lechuza.test.\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
    }

    func testPutsTheTextOnTheClipboardForClipboardManagersToSkip() {
        _ = ClipboardSnapshot(replacingWith: "Hola", on: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hola")
        XCTAssertNotNil(pasteboard.data(forType: ClipboardSnapshot.transient))
    }

    func testRestoresEveryItemAndType() {
        let first = NSPasteboardItem()
        first.setString("plain", forType: .string)
        first.setData(Data("{\\rtf1 rich}".utf8), forType: .rtf)
        let second = NSPasteboardItem()
        second.setData(Data([0, 1, 2]), forType: custom)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let snapshot = ClipboardSnapshot(replacingWith: "dictated", on: pasteboard)
        XCTAssertTrue(snapshot.restore(on: pasteboard))

        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first?.string(forType: .string), "plain")
        XCTAssertEqual(items.first?.data(forType: .rtf), Data("{\\rtf1 rich}".utf8))
        XCTAssertEqual(items.last?.data(forType: custom), Data([0, 1, 2]))
        XCTAssertNil(pasteboard.data(forType: ClipboardSnapshot.transient))
    }

    func testRestoresAnEmptyClipboard() {
        pasteboard.clearContents()
        let snapshot = ClipboardSnapshot(replacingWith: "dictated", on: pasteboard)
        XCTAssertTrue(snapshot.restore(on: pasteboard))
        XCTAssertEqual(pasteboard.pasteboardItems?.count ?? 0, 0)
    }

    func testKeepsWhatTheUserCopiedMeanwhile() {
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let snapshot = ClipboardSnapshot(replacingWith: "dictated", on: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("copied since", forType: .string)
        XCTAssertFalse(snapshot.restore(on: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "copied since")
    }
}
