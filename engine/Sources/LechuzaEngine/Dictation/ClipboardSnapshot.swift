import AppKit
import Synchronization

/// What was on the clipboard before a dictation replaced it: every item with
/// every type in its order of preference, so a copied image or rich text
/// survives the paste. The dictation goes on the clipboard as a promise:
/// the pasteboard asks Lechuza for the words when an app reads them, which
/// is how Lechuza knows the paste has landed. AppKit delivers that request
/// through the main run loop.
@MainActor
final class ClipboardSnapshot: NSObject, NSPasteboardItemDataProvider {
    /// nspasteboard.org's marker: clipboard managers don't record the dictation.
    static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private let pasteboard: NSPasteboard
    private let text: String
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]
    /// The clipboard's change count with the dictation on it.
    private var changeCount = 0
    private let read = Mutex(false)

    /// Saves the clipboard, then promises `text` on it.
    init(promising text: String, on pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        self.text = text
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        super.init()
        let item = NSPasteboardItem()
        item.setDataProvider(self, forTypes: [.string])
        item.setData(Data(), forType: Self.transient)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        changeCount = pasteboard.changeCount
    }

    /// Waits until an app reads the words, or `timeout` passes. Returns
    /// whether it read them.
    func waitForRead(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !read.withLock({ $0 }), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return read.withLock { $0 }
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

    nonisolated func pasteboard(
        _ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType
    ) {
        item.setString(text, forType: type)
        read.withLock { $0 = true }
    }
}
