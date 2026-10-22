import AppKit

/// What was on the clipboard before a dictation replaced it: every item with
/// every type in its order of preference, so a copied image or rich text
/// survives the paste.
struct ClipboardSnapshot {
    /// nspasteboard.org's marker: clipboard managers don't record the dictation.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    /// The clipboard's change count with the dictation on it.
    private let changeCount: Int

    /// Saves the clipboard, then puts `text` on it.
    init(replacingWith text: String, on pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: Self.transient)
        changeCount = pasteboard.changeCount
    }

    /// Puts the saved items back, unless something else has changed the
    /// clipboard since. Returns whether it did.
    @discardableResult
    func restore(on pasteboard: NSPasteboard) -> Bool {
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
