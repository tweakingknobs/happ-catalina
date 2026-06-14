import AppKit

/// Modal dialog to enter/change a subscription URL.
enum AddSubscriptionWindow {

    static func present(prefill: String, completion: @escaping (String?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Add or change subscription"
        alert.informativeText = "Paste a subscription URL. The bundled demo key is pre-filled."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = prefill
        field.placeholderString = "https://example.com/sub/XXXXXXXX"
        field.lineBreakMode = .byTruncatingMiddle
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            completion(value.isEmpty ? nil : value)
        } else {
            completion(nil)
        }
    }

    static func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "VPN"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
