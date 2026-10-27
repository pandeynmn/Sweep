import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate,
    UNUserNotificationCenterDelegate
{
    var statusItem: NSStatusItem!
    var undoItem: NSMenuItem!
    var windows: [NSWindow] = []
    var settings: NSWindow?
    var trashSource: DispatchSourceFileSystemObject?
    var trashApps = Set<URL>()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "trash", accessibilityDescription: "Sweep")
        // Apps dropped on the icon: the status item's window forwards drag events to its delegate.
        statusItem.button?.window?.registerForDraggedTypes([.fileURL])
        statusItem.button?.window?.delegate = self
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Uninstall App…", action: #selector(choose), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Find Leftovers…", action: #selector(findLeftovers), keyEquivalent: "l").target = self
        undoItem = menu.addItem(withTitle: "Undo", action: #selector(undo), keyEquivalent: "z")
        undoItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Sweep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        UNUserNotificationCenter.current().delegate = self
        UserDefaults.standard.register(defaults: ["watchTrash": true])
        watchTrash(UserDefaults.standard.bool(forKey: "watchTrash"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        undoItem.isHidden = Remover.history.isEmpty
        undoItem.title = "Undo Uninstall of \(Remover.history.last?.name ?? "")"
    }

    @objc func showSettings() {
        NSApp.activate()
        if settings == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Sweep Settings"
            w.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: SettingsView())
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.center()
            settings = w
        }
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc func choose() {
        NSApp.activate()
        let p = NSOpenPanel()
        p.directoryURL = URL(fileURLWithPath: "/Applications")
        p.allowedContentTypes = [.applicationBundle]
        p.allowsMultipleSelection = true
        p.treatsFilePackagesAsDirectories = false
        if p.runModal() == .OK {
            p.urls.forEach(show)
        }
    }

    @objc func findLeftovers() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let m = Model(title: "Leftovers", subtitle: "Library items of apps that are no longer installed",
                      icon: NSWorkspace.shared.icon(forFile: Scanner.home.path + "/Library"), running: [],
                      sureTitle: "",
                      looseNote: "Named after a bundle ID no installed app has. Command-line tools and services can look "
                          + "like this too, so check each one.") { Orphans.scan(running: running) }
        present(m, title: "Leftovers")
    }

    /// Moves the last uninstall back out of the Trash.
    @objc func undo() {
        guard let r = Remover.history.popLast() else { return }
        var failed: [String] = []
        // Reversed, so an app folder is back before the app that went into it.
        for (from, to) in r.moves.reversed() {
            do { try FileManager.default.moveItem(at: to, to: from) } catch {
                failed.append((from.path as NSString).abbreviatingWithTildeInPath + ": " + error.localizedDescription)
            }
        }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = failed.isEmpty ? "Put back \(r.name)." : "Put back \(r.moves.count - failed.count) of \(r.moves.count) items."
        var info = failed
        let jobs = ["LaunchAgents", "LaunchDaemons"]
        if r.moves.contains(where: { jobs.contains($0.from.deletingLastPathComponent().lastPathComponent) }) {
            info.append("Its background items come back after you log out and in again.")
        }
        a.informativeText = info.joined(separator: "\n\n")
        a.runModal()
    }

    // Finder: right-click › Quick Actions/Services › Uninstall with Sweep
    @objc func uninstall(_ pb: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        (pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).forEach(show)
    }

    // Finder: right-click › Quick Actions/Services › Delete Everything with Sweep. One confirmation, no review list.
    @objc func uninstallAll(_ pb: NSPasteboard, userData: String?,
                            error: AutoreleasingUnsafeMutablePointer<NSString?>)
    {
        for app in pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? [] {
            Task.detached {
                let r = Result { () throws -> (Target, [Leftover]) in
                    let t = try Scanner.target(app)
                    return (t, Scanner.scan(t))
                }
                await MainActor.run { self.confirmDeleteAll(r) }
            }
        }
    }

    func confirmDeleteAll(_ r: Result<(Target, [Leftover]), Error>) {
        NSApp.activate()
        do {
            let (t, items) = try r.get()
            let total = ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file)
            let loose = items.filter { !Scanner.selectedByDefault.contains($0.reason) }.count
            let list = items.prefix(25).map { ($0.url.path as NSString).abbreviatingWithTildeInPath }
            let a = NSAlert()
            a.messageText = "Move \(t.name) and \(items.count - 1) related items to the Trash?"
            a.informativeText = "\(total) in total."
                + (loose > 0 ? " \(loose) matched only by name, app group or partial ID." : "")
                + "\n\n" + list.joined(separator: "\n") + (items.count > 25 ? "\n…and \(items.count - 25) more" : "")
            a.addButton(withTitle: "Move to Trash")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
            let left = try Remover.remove(items.map(\.url), bundleIDs: t.running, name: t.name)
            if !left.isEmpty {
                throw Err("Could not remove:\n" + left.map(\.path).joined(separator: "\n"))
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// `open -a Sweep Foo.app`
    func application(_ sender: NSApplication, open urls: [URL]) {
        urls.forEach(show)
    }

    func show(_ app: URL) {
        let t: Target
        do { t = try Scanner.target(app) } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
            return
        }
        present(Model(t), title: "Uninstall \(t.displayName)")
    }

    func present(_ m: Model, title: String) {
        NSApp.activate()
        let w = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: UninstallView(m: m) { [weak self, weak w] in
            w?.close()
            self?.windows.removeAll { $0 === w }
        })
        w.center()
        w.makeKeyAndOrderFront(nil)
        windows.append(w)
    }

    // MARK: Drop on the menu bar icon

    static func apps(_ s: NSDraggingInfo) -> [URL] {
        let urls = s.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        return (urls as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "app" }
    }

    func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation {
        Self.apps(s).isEmpty ? [] : .generic
    }

    func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        let apps = Self.apps(s)
        // After the drag session ends, so the review window can take focus.
        DispatchQueue.main.async { apps.forEach(self.show) }
        return !apps.isEmpty
    }

    // MARK: Trash watcher

    func watchTrash(_ on: Bool) {
        trashSource?.cancel()
        trashSource = nil
        guard on else { return }
        // shortcut: only ~/.Trash; apps trashed on other volumes land in /Volumes/X/.Trashes/<uid> and aren't seen.
        let dir = Scanner.home.appendingPathComponent(".Trash")
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return } // no Full Disk Access
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        trashApps = Self.apps(in: dir)
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        s.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.trashChanged(dir) } }
        s.setCancelHandler { close(fd) }
        s.resume()
        trashSource = s
    }

    static func apps(in dir: URL) -> Set<URL> {
        let all = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return Set(all.filter { $0.pathExtension.lowercased() == "app" })
    }

    func trashChanged(_ dir: URL) {
        let now = Self.apps(in: dir)
        let new = now.subtracting(trashApps)
        trashApps = now
        for app in new {
            Task.detached {
                guard let t = try? Scanner.target(app) else { return }
                let items = Scanner.scan(t).filter { $0.reason != "app" }
                await MainActor.run { self.offerCleanup(t, items) }
            }
        }
    }

    func offerCleanup(_ t: Target, _ items: [Leftover]) {
        // Sweep's own uninstalls also land here; they're already cleaned up.
        if Remover.removedIDs.remove(t.bundleID) != nil || items.isEmpty {
            return
        }
        let c = UNMutableNotificationContent()
        c.title = "\(t.displayName) is in the Trash"
        let size = ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file)
        c.body = "It left \(items.count) item\(items.count == 1 ? "" : "s") behind (\(size)). Click to review."
        c.userInfo = ["app": t.app.path]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.app.path, content: c, trigger: nil))
    }

    /// A menu bar app counts as frontmost, so without this the banner is suppressed.
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions)
                                                -> Void)
    {
        done([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse,
                                            withCompletionHandler done: @escaping () -> Void)
    {
        if let path = r.notification.request.content.userInfo["app"] as? String {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.show(URL(fileURLWithPath: path)) } }
        }
        done()
    }
}
