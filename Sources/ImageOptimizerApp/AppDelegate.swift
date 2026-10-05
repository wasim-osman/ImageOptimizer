import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var mainViewController: MainViewController!
    private var settingsController: SettingsWindowController?
    /// Files that arrived via application(_:openFiles:) before the view controller existed. On a
    /// cold launch triggered by opening a file, AppKit doesn't guarantee that callback comes after
    /// applicationDidFinishLaunching has built the window, so buffer rather than drop them.
    private var pendingOpenURLs: [URL] = []

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()

        let mainVC = MainViewController()
        mainVC.view.frame = NSRect(x: 0, y: 0, width: 560, height: 400)
        mainViewController = mainVC

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "ImageOptimizer"
        window.contentViewController = mainVC
        window.minSize = NSSize(width: 420, height: 300)
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        if !pendingOpenURLs.isEmpty {
            mainViewController.enqueueExternally(pendingOpenURLs)
            pendingOpenURLs.removeAll()
        }
    }

    /// Quitting mid-batch must stop the encoder processes, not orphan them (VideoOptimizer's
    /// ffmpeg kept running with nothing left able to see or cancel it).
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainViewController?.hasJobsWorthWarningAboutOnQuit == true else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Images are still being optimised"
        alert.informativeText = "Quitting now stops the work in progress. Finished images are kept."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop and Quit")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task { @MainActor in
            await mainViewController?.stopAllJobsForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @MainActor
    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About ImageOptimizer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        appMenu.addItem(withTitle: "Hide ImageOptimizer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit ImageOptimizer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        mainMenu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Open…", action: #selector(openFilesDialog(_:)), keyEquivalent: "o")
        fileMenu.addItem(.separator())
        // No target: routed down the responder chain to MainViewController, which enables it only
        // while something is actually running.
        let stop = NSMenuItem(title: "Stop", action: #selector(MainViewController.stopConverting(_:)), keyEquivalent: ".")
        stop.keyEquivalentModifierMask = [.command]
        fileMenu.addItem(stop)
        fileItem.submenu = fileMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor
    @objc func showSettings(_ sender: Any?) {
        if settingsController == nil { settingsController = SettingsWindowController() }
        settingsController?.showWindow(nil)
        settingsController?.window?.makeKeyAndOrderFront(nil)
    }

    @MainActor
    @objc func openFilesDialog(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Optimise"
        guard panel.runModal() == .OK else { return }
        mainViewController.enqueueExternally(panel.urls)
    }

    // Dock / Finder "Open With" file delivery.
    @MainActor
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        if let mainViewController {
            mainViewController.enqueueExternally(urls)
        } else {
            pendingOpenURLs.append(contentsOf: urls)
        }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
