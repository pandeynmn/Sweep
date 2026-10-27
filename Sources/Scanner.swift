import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Scanning (ported from AppCleaner 3.6.8's -[ACAppBundle fetchRelatedFiles])

enum Scanner {
    typealias Match = (_ file: String, _ bundle: BundleKey, _ target: Target) -> String?

    static let home = FileManager.default.homeDirectoryForCurrentUser
    /// ~/Library/sub and /Library/sub, like AppCleaner's libraryPathsByAppendingPathComponent:.
    static func lib(_ sub: String) -> [URL] {
        [home.appendingPathComponent("Library"), URL(fileURLWithPath: "/Library")]
            .map { sub.isEmpty ? $0 : $0.appendingPathComponent(sub) }
    }

    // Strongest first. Only "app" and "bundle ID" are selected by default. "app group" outranks "bundle ID"
    // because a team-prefixed group ("TEAM.com.foo.Bar") also matches the ID, and shared groups stay opt-in.
    static let rank = ["app", "app group", "bundle ID", "helper ID", "ID substring", "app folder", "name"]
    static let selectedByDefault: Set<String> = ["app", "bundle ID"]

    /// AppCleaner's +[ACBundle protectedPaths]: Library subfolders never offered for removal, in ~ and /.
    static let protected: Set<String> = {
        let names = [
            "Accounts", "Application Support", "Audio", "Autosave Information", "Caches", "Caches/Metadata",
            "ColorPickers", "Colors", "ColorSync", "Components", "Compositions", "Containers",
            "Contextual Menu Items", "Cookies", "CoreMediaIO", "Desktop Pictures", "Developer", "Dictionaries",
            "DirectoryServices", "Extensions", "Favorites", "Filesystems", "FontCollections", "Fonts", "Frameworks",
            "Graphics", "Group Containers", "IdentityServices", "Image Capture", "Input Methods",
            "Internet Plug-Ins", "Keyboard Layouts", "Keychains", "LanguageModeling", "LaunchAgents",
            "LaunchDaemons", "Logs", "MobileDevice", "Modem Scripts", "OpenDirectory", "PDF Services",
            "PreferencePanes", "Preferences", "Printers", "PrivilegedHelperTools", "PubSub", "QuickLook",
            "QuickTime", "Receipts", "Recent Documents", "Sandbox", "Saved Application State",
            "ScriptingAdditions", "Scripts", "Security", "Services", "Sounds", "Speech", "Spelling", "Spotlight",
            "StartupItems", "SyncedPreferences", "Video", "Voices", "WebKit", "Widgets"
        ]
        return Set(names.flatMap { ["/Library/" + $0, home.path + "/Library/" + $0] })
    }()

    // MARK: Target

    static func target(_ app: URL) throws -> Target {
        guard let b = Bundle(url: app), let id = b.bundleIdentifier, let info = b.infoDictionary else {
            throw Err("\(app.lastPathComponent) has no bundle identifier.")
        }
        if app.path.hasPrefix("/System/") || id.hasPrefix("com.apple.") || id == Bundle.main.bundleIdentifier {
            throw Err("Refusing to remove \(id).")
        }
        let vendor = id.split(separator: ".").prefix(2).joined(separator: ".") + "."
        func key(_ raw: String, sub: Bool, exec: String?) -> BundleKey {
            BundleKey(raw: raw, norm: normalizeBundleID(raw), sub: sub, foreign: sub && !raw.hasPrefix(vendor),
                      exec: exec, exact: matcher(raw, dottedPrefix: true))
        }
        var bundles = [key(id, sub: false, exec: info["CFBundleExecutable"] as? String)]
        var groups = appGroups(app), workflows = Set<String>()

        // -[ACAppBundle parseBundle]: every nested bundle, or bare executable with an embedded Info.plist,
        // down to 7 levels, except Sparkle; plus the .workflow names its Services leftovers would have.
        let props: [URLResourceKey] = [.isPackageKey, .isRegularFileKey, .isExecutableKey]
        let e = FileManager.default.enumerator(at: app, includingPropertiesForKeys: props)
        while let u = e?.nextObject() as? URL {
            if (e?.level ?? 0) >= 7 {
                e?.skipDescendants()
            }
            if u.pathExtension.lowercased() == "workflow" {
                workflows.insert(u.lastPathComponent.lowercased())
                continue
            }
            guard let v = try? u.resourceValues(forKeys: Set(props)) else { continue }
            let nested: [String: Any]?
            if v.isPackage == true {
                nested = u.pathExtension == "framework" ? nil : Bundle(url: u)?.infoDictionary
            } else if v.isRegularFile == true, v.isExecutable == true {
                nested = CFBundleCopyInfoDictionaryForURL(u as CFURL) as? [String: Any]
            } else {
                continue
            }
            guard let nid = nested?["CFBundleIdentifier"] as? String, !nid.isEmpty,
                  !nid.lowercased().hasPrefix("org.sparkle-project"), !bundles.contains(where: { $0.raw == nid })
            else { continue }
            bundles.append(key(nid, sub: true, exec: nested?["CFBundleExecutable"] as? String))
            groups += appGroups(u)
        }

        let fileName = app.deletingPathExtension().lastPathComponent
        var bundleName = normalized(info["CFBundleName"] as? String ?? "")
        if bundleName.isEmpty { // -[ACBundle initWithURL:] falls back to the file name minus a " 12.34.56" suffix
            bundleName = normalized(fileName)
                .replacingOccurrences(of: #"(?<=.) \d{2}.\d{2}.\d{2}$"#, with: "", options: .regularExpression)
        }
        let display = normalized(info["CFBundleDisplayName"] as? String ?? "")
        // -[ACBundle relatedFilesInDirectories:maxDepth:]'s name list, plus the file name.
        let names = [
            bundleName,
            noSpace(bundleName),
            bundleName.replacingOccurrences(of: #"\s*\d+$"#, with: "", options: .regularExpression),
            display,
            noSpace(display),
            fileName,
            noSpace(fileName)
        ].filter { $0.count >= 3 }
        let helpers = ((info["SMPrivilegedExecutables"] as? [String: Any])?.keys).map(Array.init) ?? []
        return Target(app: app, name: fileName, bundles: bundles, helperLabels: helpers, groups: Array(Set(groups)),
                      names: Array(Set(names)).map { matcher($0) }, bundleName: bundleName, workflows: workflows)
    }

    static func appGroups(_ u: URL) -> [String] {
        var code: SecStaticCode?
        var info: CFDictionary?
        guard SecStaticCodeCreateWithPath(u as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) ==
              errSecSuccess,
              let ent = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return [] }
        return ent["com.apple.security.application-groups"] as? [String] ?? []
    }

    // MARK: String helpers (AppCleaner's NSString categories)

    /// -[NSString normalizedString]: trim whitespace, then dots.
    static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    static func noSpace(_ s: String) -> String {
        s.filter { !$0.isWhitespace }
    }

    static func hasIPrefix(_ s: String, _ p: String) -> Bool {
        !p.isEmpty && s.range(of: p, options: [.caseInsensitive, .anchored]) != nil
    }

    static func icontains(_ s: String,
                          _ p: String) -> Bool
    {
        !p.isEmpty && s.range(of: p, options: .caseInsensitive) != nil
    }

    // swiftlint:disable:next force_try - constant pattern
    static let idSuffix = try! NSRegularExpression(pattern: #"\.(app|application|demo|trial)?[0-9-_ab]*$"#)
    /// -[ACBundle normalizeBundleId]: "com.foo.Bar.app" / ".demo2" / "-b1" endings are cut off. It can over-trim
    /// ("com.example.a" → "com.example"), which is why the result only feeds opt-in matches.
    static func normalizeBundleID(_ id: String) -> String {
        guard id.count >= 8, let m = idSuffix.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)),
              m.range.location > 0 else { return id }
        return (id as NSString).substring(to: m.range.location)
    }

    /// AppCleaner's pattern: ^key(?:[\.\-_\s\d]+.*)?$
    /// IDs may also carry a dotted prefix (team ID or "group."); anchoring on the dot avoids "xcom.foo.Bar".
    static func matcher(_ key: String, dottedPrefix: Bool = false) -> NSRegularExpression {
        // swiftlint:disable:next force_try - the key is escaped
        try! NSRegularExpression(
            pattern: (dottedPrefix ? #"^(?:.+\.)?"# : "^") + NSRegularExpression.escapedPattern(for: key)
                + #"(?:[.\-_\s\d]+.*)?$"#,
            options: .caseInsensitive
        )
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    // MARK: Rules

    /// An exact-ID match is a bundle ID hit; AppCleaner's looser test for this folder alone is opt-in.
    static func idReason(_ f: String, _ b: BundleKey, _ appCleaner: Bool) -> String? {
        if matches(b.exact, f) {
            return b.foreign ? "helper ID" : "bundle ID"
        }
        return appCleaner ? "ID substring" : nil
    }

    static func nameReason(_ f: String, _ t: Target) -> String? {
        let bare = (f as NSString).deletingPathExtension
        return t.names.contains { matches($0, f) || matches($0, bare) } ? "name" : nil
    }

    /// The default block in -[ACBundle relatedFilesInDirectories:maxDepth:]: ID substring (≥8 chars) or
    /// prefix (≥4), then, for the app itself, the name patterns.
    static let standard: Match = { f, b, t in
        let n = b.norm
        if let r = idReason(f, b, (n.count >= 8 && icontains(f, n)) || (n.count >= 4 && hasIPrefix(f, n))) {
            return r
        }
        return b.sub ? nil : nameReason(f, t)
    }

    static func prefixID(minLength: Int) -> Match {
        { f, b, _ in idReason(f, b, b.norm.count >= minLength && hasIPrefix(f, b.norm)) }
    }

    static func mainOnly(_ m: @escaping Match) -> Match {
        { f, b, t in b.sub ? nil : m(f, b, t) }
    }

    static let helpd: Match = { f, b, _ in
        idReason(f, b, b.norm.count >= 4 && hasIPrefix((f as NSString).deletingPathExtension, b.norm))
    }

    /// (folders, depth, test). Depth 0 is the top level only; n checks n-1 levels below it.
    static let rules: [(dirs: [URL], depth: Int, match: Match)] = [
        // -[ACAppBundle preferencesFiles] / -[ACBundle preferencesFiles]
        (lib("Preferences"), 0, { f, b, t in
            if !b.sub && hasIPrefix(f, "widget-") {
                return nil
            }
            let n = b.norm
            let byID = n != "net.sourceforge"
                && (n.count <= 3 ? f.caseInsensitiveCompare(n + ".plist") == .orderedSame : hasIPrefix(f, n))
            if let r = idReason(f, b, byID) {
                return r
            }
            guard !b.sub else { return nil }
            let bn = noSpace(t.bundleName)
            let byName = (bn.count >= 4 && (hasIPrefix(f, t.bundleName) || hasIPrefix(f, bn)))
                || (bn.count >= 8 && (icontains(f, t.bundleName) || icontains(f, bn)))
            return byName ? "name" : nil
        }),
        (lib("Preferences/ByHost") + lib("SyncedPreferences"), 0, prefixID(minLength: 4)),
        // -[ACBundle miscFiles]
        (lib("") + lib("Application Support") + lib("Services") + lib("Safari/Extensions")
            + [URL(fileURLWithPath: "/Users/Shared")], 0, mainOnly(standard)),
        (lib("PreferencePanes"), 0, { f, b, t in
            t.app.pathExtension.lowercased() == "prefpane" ? nil : mainOnly(standard)(f, b, t) }),
        (lib("Cookies") + lib("HTTPStorages") + lib("WebKit")
            + lib("Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments"),
            0, mainOnly(prefixID(minLength: 8))),
        // -[ACBundle containersFiles]. Group Containers are forced opt-in in scan().
        (lib("Containers") + lib("Application Scripts"), 0, { f, b, _ in
            idReason(f, b, f.caseInsensitiveCompare(b.norm) == .orderedSame) }),
        (lib("Group Containers"), 0, { f, b, t in
            f.caseInsensitiveCompare(b.norm) == .orderedSame || t.groups.contains(f) ? "app group" : nil }),
        // -[ACBundle savedStateFiles]
        (lib("Saved Application State"), 0, { f, b, t in
            if let r = idReason(f, b, hasIPrefix(f, b.norm)) {
                return r
            }
            return !b.sub && t.bundleName.count >= 8 && hasIPrefix(f, t.bundleName) ? "name" : nil
        }),
        // -[ACBundle agentsAndDaemonsFiles], incl. SMJobBless helpers by exact label
        (lib("LaunchAgents") + lib("LaunchDaemons"), 0, { f, b, t in
            if !b.sub, t.helperLabels.contains(where: { f == $0 + ".plist" }) {
                return "bundle ID"
            }
            return idReason(f, b, b.norm.count >= 8 && hasIPrefix(f, b.norm))
        }),
        (lib("PrivilegedHelperTools"), 0, { f, b, t in
            if !b.sub, t.helperLabels.contains(f) {
                return "bundle ID"
            }
            return idReason(f, b, b.norm.count >= 8 && hasIPrefix(f, b.norm))
        }),
        // -[ACBundle logsFiles]. Executable names collide (every Electron app is "Electron"), so opt-in.
        (lib("Application Support/CrashReporter") + lib("Logs/DiagnosticReports"), 0, { f, b, _ in
            guard let x = b.exec, hasIPrefix(f, x + "_") else { return nil }
            return "name"
        }),
        (lib("Logs"), 3, standard),
        // -[ACAppBundle cachesFiles]
        (lib("Caches") + lib("Caches/Metadata") + lib("Caches/com.apple.Safari/Extensions"), 0, mainOnly(standard)),
        (lib("Caches/com.apple.helpd/Generated"), 0, mainOnly(helpd)),
        (lib("Caches/com.apple.helpd/SDMHelpData"), 4, mainOnly(helpd)),
        // -[ACAppBundle packageFiles]
        ([URL(fileURLWithPath: "/private/var/db/receipts")], 0, mainOnly(prefixID(minLength: 4))),
        // -[ACAppBundle servicesFiles]: workflows the app ships
        (lib("Services"), 0, mainOnly { f, _, t in t.workflows.contains(f.lowercased()) ? "bundle ID" : nil }),
        // Folders Sweep checked before AppCleaner's rules were ported.
        (lib("Autosave Information") + lib("Internet Plug-Ins") + lib("QuickLook") + lib("Screen Savers")
            + lib("Spotlight") + lib("Audio/Plug-Ins/HAL") + lib("Audio/Plug-Ins/Components"), 0, standard)
    ]

    /// Visits entries of dir like AppCleaner's relatedFilesInDirectories:maxDepth:matching:.
    /// `visit` returns true for a match, and a matched folder isn't descended into.
    static func walk(_ dir: URL, depth: Int, _ visit: (URL) -> Bool) {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                     options: depth == 0 ? .skipsSubdirectoryDescendants : [])
        else { return }
        while let u = e.nextObject() as? URL {
            if depth > 0, e.level >= depth {
                e.skipDescendants()
                continue
            }
            if visit(u) {
                e.skipDescendants()
            }
        }
    }

    /// -[ACAppBundle relatedParentDir]: an app shipped in its own folder, e.g. /Applications/Foo 2024/Foo.app.
    /// AppCleaner takes any parent whose name contains the app's; this only looks inside Applications folders,
    /// so ~/Developer/Foo/Foo.app never offers the source tree.
    static func appFolder(_ app: URL) -> URL? {
        let parent = app.deletingLastPathComponent()
        if app.path.hasPrefix("/opt/homebrew-cask/") {
            return parent
        }
        guard ["/Applications", home.path + "/Applications"].contains(parent.deletingLastPathComponent().path)
        else { return nil }
        let p = noSpace(parent.lastPathComponent), n = noSpace(app.deletingPathExtension().lastPathComponent)
        let hit = n.count <= 3 ? p.caseInsensitiveCompare(n) == .orderedSame : icontains(p, n)
        return hit ? parent : nil
    }

    static func scan(_ t: Target) -> [Leftover] {
        func rankOf(_ r: String) -> Int {
            rank.firstIndex(of: r)!
        }
        var found: [URL: String] = [:]
        func add(_ u: URL, _ r: String) {
            if let old = found[u], rankOf(old) <= rankOf(r) {
                return
            }
            found[u] = r
        }
        let groupRes = t.groups.map { matcher($0) }
        let groupDirs = Set(lib("Group Containers"))
        for rule in rules {
            for dir in rule.dirs {
                walk(dir, depth: rule.depth) { u in
                    guard !protected.contains(u.path),
                          u.standardizedFileURL != t.app.standardizedFileURL else { return false }
                    let f = normalized(u.lastPathComponent)
                    // AppCleaner's test for this folder, plus Sweep's exact-ID, app-group and name patterns
                    // everywhere (what Sweep matched before the port).
                    var reasons = [nameReason(f, t)]
                    if groupRes.contains(where: { matches($0, f) }) {
                        reasons.append("app group")
                    }
                    for b in t.bundles {
                        reasons += [rule.match(f, b, t), idReason(f, b, false)]
                    }
                    guard var best = reasons.compactMap(\.self).min(by: { rankOf($0) < rankOf($1) })
                    else { return false }
                    if groupDirs.contains(dir) {
                        best = "app group"
                    } // AppCleaner deselects all group containers
                    add(u, best)
                    return true
                }
            }
        }
        if let folder = appFolder(t.app) {
            add(folder, "app folder")
        }
        // Drop items inside other found items (Logs is walked 3 deep). The app is listed separately, so
        // unticking its folder still removes the app.
        let paths = Set(found.keys.map(\.path))
        let items = found.filter { u, _ in !paths.contains { u.path.hasPrefix($0 + "/") } }
            .sorted { $0.key.path < $1.key.path }
        return [Leftover(url: t.app, reason: "app", size: size(t.app))]
            + items.map { Leftover(url: $0.key, reason: $0.value, size: size($0.key)) }
    }

    static func size(_ u: URL) -> Int64 {
        let k: URLResourceKey = .totalFileAllocatedSizeKey
        guard let v = try? u.resourceValues(forKeys: [.isDirectoryKey, k]) else { return 0 }
        guard v.isDirectory == true else { return Int64(v.totalFileAllocatedSize ?? 0) }
        var total: Int64 = 0
        let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [k])
        while let f = e?.nextObject() as? URL {
            total += Int64((try? f.resourceValues(forKeys: [k]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
