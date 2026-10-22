import CoreGraphics
import XCTest

@testable import LechuzaEngine

/// Which flagsChanged events move each hotkey.
final class HotkeyTests: XCTestCase {
    private let rightOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    private let leftOption = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)

    func testFnFollowsItsOwnKey() {
        XCTAssertEqual(Hotkey.fn.isDown(keyCode: 63, flags: .maskSecondaryFn), true)
        XCTAssertEqual(Hotkey.fn.isDown(keyCode: 63, flags: []), false)
        XCTAssertNil(Hotkey.fn.isDown(keyCode: 56, flags: [.maskShift, .maskSecondaryFn]), "shift moved, not fn")
    }

    func testRightOptionIgnoresTheLeftOne() {
        XCTAssertEqual(Hotkey.rightOption.isDown(keyCode: 61, flags: rightOption), true)
        XCTAssertEqual(Hotkey.rightOption.isDown(keyCode: 61, flags: leftOption), false, "left still held")
        XCTAssertEqual(Hotkey.rightOption.isDown(keyCode: 61, flags: []), false)
        XCTAssertNil(Hotkey.rightOption.isDown(keyCode: 58, flags: leftOption))
    }

    func testRightCommand() {
        let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        XCTAssertEqual(Hotkey.rightCommand.isDown(keyCode: 54, flags: flags), true)
        XCTAssertEqual(Hotkey.rightCommand.isDown(keyCode: 54, flags: []), false)
        XCTAssertNil(Hotkey.rightCommand.isDown(keyCode: 55, flags: .maskCommand))
    }

    func testControlOptionIsDownWhileBothAre() {
        XCTAssertEqual(Hotkey.controlOption.isDown(keyCode: 59, flags: .maskControl), false)
        XCTAssertEqual(Hotkey.controlOption.isDown(keyCode: 58, flags: [.maskControl, .maskAlternate]), true)
        XCTAssertEqual(Hotkey.controlOption.isDown(keyCode: 61, flags: [.maskControl, .maskAlternate]), true)
        XCTAssertEqual(Hotkey.controlOption.isDown(keyCode: 62, flags: .maskAlternate), false)
        XCTAssertNil(Hotkey.controlOption.isDown(keyCode: 63, flags: .maskSecondaryFn))
    }
}
