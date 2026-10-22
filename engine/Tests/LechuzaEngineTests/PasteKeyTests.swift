import Carbon
import XCTest

@testable import LechuzaEngine

/// ⌘V is the key that types "v" with ⌘ held in the active layout, which isn't
/// key code 9 on every keyboard.
final class PasteKeyTests: XCTestCase {
    /// An installed layout by its input source ID, enabled or not.
    private func layout(_ id: String) throws -> TISInputSource {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        let sources = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource]
        return try XCTUnwrap(sources?.first, "\(id) isn't installed")
    }

    func testFindsVWhereverTheLayoutPutsIt() throws {
        XCTAssertEqual(Paste.vKey(in: try layout("com.apple.keylayout.US")), 9)
        XCTAssertEqual(Paste.vKey(in: try layout("com.apple.keylayout.Dvorak")), 47, "9 is K on Dvorak")
        XCTAssertEqual(Paste.vKey(in: try layout("com.apple.keylayout.DVORAK-QWERTYCMD")), 9, "QWERTY while ⌘ is held")
    }

    func testFallsBackToQwertysVWhenNoKeyTypesIt() {
        XCTAssertEqual(Paste.vKey { $0 == 47 ? "v" : "x" }, 47)
        XCTAssertEqual(Paste.vKey { _ in "ж" }, 9)
    }
}
