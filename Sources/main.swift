import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

let args = CommandLine.arguments
if args.count == 2, args[1] == "--selftest" {
    let re = Scanner.matcher("com.foo.Bar")
    precondition(Scanner.matches(re, "com.foo.Bar"))
    precondition(Scanner.matches(re, "com.foo.Bar.plist"))
    precondition(Scanner.matches(re, "COM.FOO.BAR.savedState"))
    precondition(Scanner.matches(re, "com.foo.Bar-helper"))
    precondition(!Scanner.matches(re, "com.foo.BarBaz.plist"))
    precondition(!Scanner.matches(re, "xcom.foo.Bar"))
    let idre = Scanner.matcher("com.foo.Bar", dottedPrefix: true)
    precondition(Scanner.matches(idre, "2BUA8C4S2C.com.foo.Bar"))
    precondition(Scanner.matches(idre, "group.com.foo.Bar.shared"))
    precondition(Scanner.matches(idre, "com.foo.Bar.plist"))
    precondition(!Scanner.matches(idre, "xcom.foo.Bar"))
    precondition(!Scanner.matches(idre, "com.foo.BarBaz.plist"))
    precondition(Scanner.protected.contains(Scanner.home.path + "/Library/Fonts"))
    precondition(!Scanner.matches(Scanner.matcher("a.b"), "axb")) // dots are literal
    precondition(Scanner.matches(Scanner.matcher("Foo App"), "Foo App 2"))
    precondition(Scanner.normalizeBundleID("com.foo.Bar.app") == "com.foo.Bar")
    precondition(Scanner.normalizeBundleID("com.foo.Bar.demo2") == "com.foo.Bar")
    precondition(Scanner.normalizeBundleID("com.foo.Bar") == "com.foo.Bar")
    precondition(Scanner.normalizeBundleID("a.b.app") == "a.b.app") // under 8 chars: untouched
    precondition(Scanner.normalized("  Foo. ") == "Foo")
    let k = BundleKey(raw: "com.foo.Bar", norm: "com.foo.Bar", sub: false, foreign: false, exec: nil, exact: idre)
    let t = Target(app: URL(fileURLWithPath: "/Applications/Bar.app"), name: "Bar", bundles: [k], helperLabels: [],
                   groups: [], names: [Scanner.matcher("Bar App")], bundleName: "Bar App", workflows: [])
    precondition(Scanner.standard("com.foo.Bar.plist", k, t) == "bundle ID")
    precondition(Scanner.standard("com.foo.BarPro.plist", k, t) == "ID substring")
    precondition(Scanner.standard("xcom.foo.Bar", k, t) == "ID substring")
    precondition(Scanner.standard("Bar App 2.log", k, t) == "name")
    precondition(Scanner.standard("Unrelated", k, t) == nil)
    let sub = BundleKey(raw: "com.foo.Bar", norm: "com.foo.Bar", sub: true, foreign: true, exec: nil, exact: idre)
    precondition(Scanner.standard("com.foo.Bar.plist", sub, t) == "helper ID")
    precondition(Scanner.standard("Bar App", sub, t) == nil) // nested bundles never match by name
    precondition(Scanner.appFolder(URL(fileURLWithPath: "/Applications/Foobar 2024/Foobar.app"))?
        .path == "/Applications/Foobar 2024")
    precondition(Scanner
        .appFolder(URL(fileURLWithPath: "/Applications/Foo 2024/Foo.app")) == nil) // ≤3 chars: exact only
    precondition(Scanner.appFolder(URL(fileURLWithPath: "/Applications/Foo.app")) == nil)
    precondition(Scanner.appFolder(URL(fileURLWithPath: Scanner.home.path + "/Developer/Foo/Foo.app")) == nil)
    precondition(Scanner.appFolder(URL(fileURLWithPath: "/Applications/Tools/Foo.app")) == nil)
    precondition(Remover.privacyPane(URL(fileURLWithPath: "/Applications/Foo.app"))?.name == "App Management")
    precondition(Remover.privacyPane(Scanner.home.appendingPathComponent("Library/Group Containers/x"))?
        .name == "Full Disk Access")
    precondition(Remover.privacyPane(Scanner.home.appendingPathComponent("Library/Caches/x")) == nil)
    precondition(Remover.shellQuote("it's") == #"'it'\''s'"#)
    precondition(Remover.asString(#"a"b\c"#) == #""a\"b\\c""#)
    precondition(Orphans.id("com.foo.Bar.plist") == "com.foo.Bar")
    precondition(Orphans.id("2BUA8C4S2C.com.foo.Bar") == "com.foo.Bar")
    precondition(Orphans.id("com.foo.Bar.savedState") == "com.foo.Bar")
    precondition(Orphans.id("Foo Folder") == nil)
    precondition(Orphans.id("crash.2024.log") == nil) // not a known first label
    precondition(Orphans.id("com.apple.Safari.plist") == nil)
    precondition(Orphans.id("com.foo") == nil) // two labels: too loose
    precondition(Orphans.known("com.foo.Bar.helper", ["com.foo.bar"], []))
    precondition(Orphans.known("com.foo.Bar-2", ["com.foo.bar"], []))
    precondition(Orphans.known("com.foo", [], ["com.foo"]))
    precondition(!Orphans.known("com.foo.BarBaz", ["com.foo.bar"], ["com.foo"]))
    print("ok")
    exit(0)
}

if args.count == 3, args[1] == "--scan" {
    do {
        let t = try Scanner.target(URL(fileURLWithPath: args[2]))
        print("ids:", t.running, "groups:", t.groups, "helpers:", t.helperLabels, "names:", t.names.map(\.pattern))
        for l in Scanner
            .scan(t)
        {
            print(l.reason.padding(toLength: 13, withPad: " ", startingAt: 0), l.size, l.url.path)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
        exit(1)
    }
}

if args.count == 3, args[1] == "--uninstall" {
    // The "Delete Everything" service without its confirmation: trashes every match, opt-in ones included.
    MainActor.assumeIsolated {
        do {
            let t = try Scanner.target(URL(fileURLWithPath: args[2]))
            let items = Scanner.scan(t)
            let left = try Remover.remove(items.map(\.url), bundleIDs: t.running, interactive: false)
            for i in items {
                print(left.contains(i.url) ? "LEFT   " : "trashed", i.url.path)
            }
            exit(left.isEmpty ? 0 : 1)
        } catch {
            FileHandle.standardError.write((error.localizedDescription + "\n").data(using: .utf8)!)
            exit(1)
        }
    }
}

// Run from a terminal (via the `sweep` link) without a known command: print usage instead of starting a
// second menu bar copy. LaunchServices starts the app with stdin on /dev/null and no arguments.
if ProcessInfo.processInfo.environment["SWEEP_GUI"] == nil, isatty(STDIN_FILENO) != 0 || args.count > 1 {
    let usage = """
    usage: sweep --scan <app>        list what would be removed
           sweep --uninstall <app>   move the app and everything found to the Trash, no prompt
    Right-click an app in Finder › Quick Actions for the same with a review window.
    """
    let help = args.count == 2 && ["-h", "--help"].contains(args[1])
    FileHandle(fileDescriptor: help ? STDOUT_FILENO : STDERR_FILENO).write((usage + "\n").data(using: .utf8)!)
    exit(help ? 0 : 64)
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
