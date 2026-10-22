import CoreGraphics

/// The key that starts dictation, chosen in Settings. Each is a modifier, so
/// it moves in flagsChanged events: the key code says which key changed and
/// the flags say what is down now. Right-hand keys are told apart by the
/// device bits in the low flags (IOKit's NX_DEVICER*KEYMASK).
enum Hotkey: String, Codable, Sendable {
    case fn, rightOption, rightCommand, controlOption

    private static let rightOptionBit: UInt64 = 0x40
    private static let rightCommandBit: UInt64 = 0x10

    /// Whether the hotkey is down after a flagsChanged event for `keyCode`,
    /// or nil when that key isn't part of the hotkey.
    func isDown(keyCode: Int64, flags: CGEventFlags) -> Bool? {
        switch self {
        case .fn:
            keyCode == 63 ? flags.contains(.maskSecondaryFn) : nil
        case .rightOption:
            keyCode == 61 ? flags.rawValue & Self.rightOptionBit != 0 : nil
        case .rightCommand:
            keyCode == 54 ? flags.rawValue & Self.rightCommandBit != 0 : nil
        case .controlOption:
            [58, 59, 61, 62].contains(keyCode) ? flags.isSuperset(of: [.maskControl, .maskAlternate]) : nil
        }
    }
}
