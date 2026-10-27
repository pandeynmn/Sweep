import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Orphans

/// Library items named after a bundle ID that no installed app has: leftovers of apps deleted without Sweep.
enum Orphans {
    /// Group Containers are left out: group names don't map back to bundle IDs.
    static let dirs = [
        "Preferences",
        "Application Support",
        "Application Scripts",
        "Caches",
        "Containers",
        "Cookies",
        "HTTPStorages",
        "LaunchAgents",
        "Logs",
        "Saved Application State",
        "WebKit"
    ]
    /// First labels that make a name look like a reverse-DNS ID rather than "crash.2024.log".
    static let tlds: Set<String> = [
        "ai", "app", "at", "au", "be", "biz", "br", "ca", "cc", "ch", "cn", "co", "com", "de", "dev", "dk", "edu", "es",
        "eu", "fi", "fr", "gg", "gov", "im", "in", "info", "io", "is", "it", "jp", "kr", "ly", "md", "me", "net", "nl",
        "no", "org", "pl", "pro", "pt", "ru", "se", "sh", "so", "tech", "to", "tv", "uk", "us", "xyz"
    ]
    /// An optional team-ID prefix, then three or more labels.
    static let pattern =
        // swiftlint:disable:next force_try - constant pattern
        try! NSRegularExpression(pattern: #"^(?:[A-Z0-9]{10}\.)?([A-Za-z0-9-]+(?:\.[A-Za-z0-9_-]+){2,})$"#)

    /// The bundle ID a Library entry is named after, or nil.
    static func id(_ name: String) -> String? {
        var n = name
        for ext in [".plist", ".savedState", ".binarycookies"]
            where n.hasSuffix(ext)
        {
            n = String(n.dropLast(ext.count))
        }
        guard let m = pattern.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)),
              let r = Range(m.range(at: 1), in: n) else { return nil }
        let id = String(n[r]), low = id.lowercased()
        guard tlds.contains(String(low.prefix { $0 != "." })), !low.hasPrefix("com.apple.") else { return nil }
        return id
    }

    /// True if `c` is an installed ID, something under one ("com.foo.Bar.helper", "com.foo.Bar-2"), or a vendor
    /// prefix of one ("com.foo"). `ids` and `prefixes` are lowercased.
    static func known(_ c: String, _ ids: Set<String>, _ prefixes: Set<String>) -> Bool {
        let c = c.lowercased()
        if ids.contains(c) || prefixes.contains(c) {
            return true
        }
        return c.indices.contains { ".-_ ".contains(c[$0]) && ids.contains(String(c[..<$0])) }
    }

    /// Bundle IDs Spotlight knows about, nested helpers and plug-ins included, plus the usual app folders in case
    /// they aren't indexed.
    static func installedIDs() -> Set<String> {
        var ids = Set<String>()
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-attr", "kMDItemCFBundleIdentifier", "kMDItemCFBundleIdentifier == '*'"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let data = out.fileHandleForReading.readDataToEndOfFile() // before waiting, or a full pipe deadlocks
            p.waitUntilExit()
            // swiftlint:disable:next optional_data_string_conversion - lossy on purpose: one bad byte mustn't drop every ID
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if let r = line.range(of: "kMDItemCFBundleIdentifier = ", options: .backwards) {
                    ids.insert(String(line[r.upperBound...]))
                }
            }
        }
        let dirs = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            Scanner.home.path + "/Applications"
        ]
        for d in dirs {
            for u in (try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: d),
                includingPropertiesForKeys: nil
            )) ?? []
                where u.pathExtension == "app"
            {
                if let id = Bundle(url: u)?.bundleIdentifier {
                    ids.insert(id)
                }
            }
        }
        return ids
    }

    static func scan(running: Set<String>) -> [Leftover] {
        let ids = Set((installedIDs().union(running).union([Bundle.main.bundleIdentifier ?? ""]))
            .map { $0.lowercased() })
        var prefixes = Set<String>()
        for id in ids {
            let parts = id.split(separator: ".")
            for n in stride(from: 2, to: parts.count, by: 1) {
                prefixes.insert(parts.prefix(n).joined(separator: "."))
            }
        }
        var out: [Leftover] = []
        for sub in dirs {
            let dir = Scanner.home.appendingPathComponent("Library/" + sub)
            for u in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard !Scanner.protected.contains(u.path), let id = id(u.lastPathComponent), !known(id, ids, prefixes)
                else { continue }
                out.append(Leftover(url: u, reason: id, size: Scanner.size(u)))
            }
        }
        // Same ID together, so one app's leftovers read as a group.
        return out.sorted { ($0.reason.lowercased(), $0.url.path) < ($1.reason.lowercased(), $1.url.path) }
    }
}
