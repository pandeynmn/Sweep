import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Removal

enum Remover {
    /// One uninstall, for Undo: where each item was and where the Trash put it.
    struct Removal {
        let name: String
        var moves: [(from: URL, to: URL)]
    }

    // shortcut: in memory, so Undo is lost on quit; persist to UserDefaults if that matters.
    @MainActor static var history: [Removal] = []
    /// Bundle IDs Sweep trashed itself, so the Trash watcher doesn't offer to clean up after them.
    @MainActor static var removedIDs = Set<String>()

    /// Moves items to the Trash. Returns the paths that are still there afterwards.
    /// `interactive` lets it stop and wait for the user to grant a privacy permission, then retry.
    @MainActor static func remove(_ urls: [URL], bundleIDs: [String], name: String = "",
                                  interactive: Bool = true) throws -> [URL]
    {
        let running = bundleIDs.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        if let r = running.first(where: { !$0.isTerminated }) {
            throw Err("\(r.localizedName ?? "The app") is still running. Quit it and try again.")
        }

        // Only apps that actually go: after "Remove Leftovers Only" the watcher must still notice the app later.
        removedIDs
            .formUnion(urls.filter { $0.pathExtension.lowercased() == "app" }
                .compactMap { Bundle(url: $0)?.bundleIdentifier })
        // Items trashed through Finder below have no resulting URL, so they can't be put back.
        var moves: [(from: URL, to: URL)] = []
        defer {
            if !moves.isEmpty {
                history.append(Removal(name: name, moves: moves))
            }
        }
        func trash(_ u: URL) -> Bool {
            var to: NSURL?
            guard (try? FileManager.default.trashItem(at: u, resultingItemURL: &to)) != nil else { return false }
            if let to {
                moves.append((u, to as URL))
            }
            return true
        }

        // Unload launchd jobs before their plists disappear.
        let uid = getuid()
        for u in urls where u.deletingLastPathComponent().lastPathComponent == "LaunchAgents" {
            run("/bin/launchctl", ["bootout", "gui/\(uid)", u.path])
        }
        let daemons = urls.filter { $0.deletingLastPathComponent().path == "/Library/LaunchDaemons" }
        if !daemons.isEmpty {
            let cmd = daemons.map { "/bin/launchctl bootout system " + shellQuote($0.path) }.joined(separator: "; ")
            try appleScript("do shell script \(asString(cmd + "; true")) with administrator privileges")
        }

        // Skip items already gone (e.g. inside an app folder trashed earlier), or Finder errors on them.
        let failed = urls.filter { exists($0) && !trash($0) }
        // Privacy-guarded items fail even through Finder with a password, so only ownership problems go there.
        var guarded = failed.filter { privacyPane($0) != nil && ownedByUser($0) }
        let owned = failed.filter { !guarded.contains($0) }
        if !owned.isEmpty {
            // Finder handles root-owned items, prompting for a password.
            let files = owned.map { "POSIX file " + asString($0.path) }.joined(separator: ", ")
            try appleScript("tell application \"Finder\" to delete {\(files)}")
        }
        while interactive, !guarded.isEmpty {
            let panes = Array(Set(guarded.compactMap { privacyPane($0) }.map(\.name))).sorted()
            let a = NSAlert()
            a.messageText = "macOS blocked Sweep from removing \(guarded.count) item\(guarded.count == 1 ? "" : "s")."
            a.informativeText = "Turn on Sweep under Privacy & Security › \(panes.joined(separator: " and ")), then click "
                + "Try Again. If it still fails, quit and reopen Sweep.\n\n"
                + guarded.map { ($0.path as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")
            a.addButton(withTitle: "Try Again")
            a.addButton(withTitle: "Open Settings")
            a.addButton(withTitle: "Skip")
            switch a.runModal() {
            case .alertFirstButtonReturn: guarded = guarded.filter { exists($0) && !trash($0) }
            case .alertSecondButtonReturn:
                let anchor = guarded.compactMap { privacyPane($0)?.anchor }.first!
                NSWorkspace.shared
                    .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor)!)
            default: return (owned + guarded).filter(exists)
            }
        }
        return (owned + guarded).filter(exists)
    }

    /// Items macOS guards with a privacy permission rather than file ownership; no password unlocks them.
    static func privacyPane(_ u: URL) -> (name: String, anchor: String)? {
        if u.pathExtension.lowercased() == "app" {
            return ("App Management", "Privacy_AppBundles")
        }
        let lib = Scanner.home.path + "/Library/"
        if u.path.hasPrefix(lib + "Containers/") || u.path.hasPrefix(lib + "Group Containers/") {
            return ("Full Disk Access", "Privacy_AllFiles")
        }
        return nil
    }

    static func ownedByUser(_ u: URL) -> Bool {
        var s = stat()
        return lstat(u.path, &s) == 0 && s.st_uid == getuid()
    }

    /// lstat, so a dangling symlink still counts as present.
    static func exists(_ u: URL) -> Bool {
        var s = stat()
        return lstat(u.path, &s) == 0
    }

    static func run(_ exe: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func asString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func appleScript(_ src: String) throws {
        var err: NSDictionary?
        NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 { // -128 = user cancelled
            throw Err(err[NSAppleScript.errorMessage] as? String ?? "AppleScript failed")
        }
    }
}
