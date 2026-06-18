import AppKit
import ApplicationServices

/// Result of a capture attempt: the text plus which method produced it.
struct Capture {
    enum Method: String { case accessibility = "Accessibility", clipboard = "Clipboard", none = "None" }
    var text: String
    var method: Method
}

/// System-wide selected-text capture. Tries the Accessibility API first
/// (no clipboard side effects), falls back to a Cmd+C clipboard round-trip
/// that restores the user's original clipboard.
enum TextCapture {

    static func capture(mode: CaptureMode) -> Capture {
        switch mode {
        case .accessibility:
            if let t = viaAccessibility() { return Capture(text: t, method: .accessibility) }
            return Capture(text: "", method: .none)
        case .clipboard:
            if let t = viaClipboard() { return Capture(text: t, method: .clipboard) }
            return Capture(text: "", method: .none)
        case .auto:
            if let t = viaAccessibility(), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return Capture(text: t, method: .accessibility)
            }
            if let t = viaClipboard() { return Capture(text: t, method: .clipboard) }
            return Capture(text: "", method: .none)
        }
    }

    /// Read currently selected text from the focused UI element via AXUIElement.
    static func viaAccessibility() -> String? {
        guard Permissions.axTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        let el = element as! AXUIElement

        // Direct selected-text attribute.
        var sel: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &sel) == .success,
           let s = sel as? String, !s.isEmpty {
            return s
        }
        // Some elements expose selection via range + value.
        var rangeVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeVal) == .success,
           let rv = rangeVal {
            var range = CFRange()
            if AXValueGetValue(rv as! AXValue, .cfRange, &range), range.length > 0 {
                var sub: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(
                    el, kAXStringForRangeParameterizedAttribute as CFString,
                    rv, &sub) == .success, let s = sub as? String, !s.isEmpty {
                    return s
                }
            }
        }
        return nil
    }

    /// Clipboard fallback: save pasteboard, send Cmd+C, read, restore.
    static func viaClipboard() -> String? {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)
        let beforeCount = pb.changeCount

        sendCopy()

        // Poll briefly for the clipboard to update.
        var text: String?
        let deadline = Date().addingTimeInterval(0.6)
        while Date() < deadline {
            if pb.changeCount != beforeCount {
                text = pb.string(forType: .string)
                break
            }
            usleep(20_000) // 20 ms
        }
        if text == nil { text = pb.string(forType: .string) }

        restore(pb, saved)
        if let t = text, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return t }
        return nil
    }

    // MARK: - clipboard plumbing

    private static func snapshot(_ pb: NSPasteboard) -> [[String: Data]] {
        var items: [[String: Data]] = []
        for item in pb.pasteboardItems ?? [] {
            var dict: [String: Data] = [:]
            for type in item.types {
                if let d = item.data(forType: type) { dict[type.rawValue] = d }
            }
            items.append(dict)
        }
        return items
    }

    private static func restore(_ pb: NSPasteboard, _ items: [[String: Data]]) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        var newItems: [NSPasteboardItem] = []
        for dict in items {
            let item = NSPasteboardItem()
            for (type, data) in dict {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            newItems.append(item)
        }
        pb.writeObjects(newItems)
    }

    private static func sendCopy() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let cKey: CGKeyCode = 8 // 'c'
        let down = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: cKey, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
