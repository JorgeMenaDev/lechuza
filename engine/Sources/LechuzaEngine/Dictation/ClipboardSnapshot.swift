import AppKit

/// What was on the clipboard before a dictation replaced it: every item with
/// every type in its order of preference, so a copied image or rich text
/// survives the paste.
@MainActor
final class ClipboardSnapshot {
    /// nspasteboard.org's marker: clipboard managers don't record the dictation.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    /// The clipboard's change count with the dictation on it.
    private let changeCount: Int

    /// Saves the clipboard, then puts `text` on it.
    init(replacingWith text: String, on pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transient)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        changeCount = pasteboard.changeCount
    }

    /// Puts the saved items back, unless something else has changed the
    /// clipboard since. Returns whether it did.
    @discardableResult
    func restore() -> Bool {
        guard pasteboard.changeCount == changeCount else { return false }
        pasteboard.clearContents()
        pasteboard.writeObjects(
            items.map { types in
                let item = NSPasteboardItem()
                for (type, data) in types { item.setData(data, forType: type) }
                return item
            })
        return true
    }
}
