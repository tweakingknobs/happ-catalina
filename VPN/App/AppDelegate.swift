import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private let model = AppModel()
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // If a previous run crashed while connected, restore the user's proxy first.
        model.recoverFromCrashIfNeeded()

        statusController = StatusItemController(model: model)

        // First launch: if a default subscription URL is configured, seed it so the app is
        // usable immediately. Empty by default — add your own via the menu (Change subscription…).
        if model.subscriptions.isEmpty, !AppModel.demoURL.isEmpty {
            model.addOrUpdateSubscription(AppModel.demoURL) { _ in /* best effort */ }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdownForQuit()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
