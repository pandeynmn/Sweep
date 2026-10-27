import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

struct Err: LocalizedError {
    let errorDescription: String?
    init(_ s: String) {
        errorDescription = s
    }
}

/// One bundle inside the app, the app itself first. AppCleaner runs its rules once per bundle.
struct BundleKey {
    let raw: String // CFBundleIdentifier as shipped
    let norm: String // after AppCleaner's normalizeBundleId; only drives opt-in matches
    let sub: Bool // nested bundle: ID rules only, no name rules
    let foreign: Bool // nested bundle from another vendor (e.g. com.google.Keystone)
    let exec: String?
    let exact: NSRegularExpression // boundary match on the raw ID: the only default-selected ID match
}

struct Target {
    let app: URL
    let name: String
    let bundles: [BundleKey]
    let helperLabels: [String] // SMPrivilegedExecutables keys
    let groups: [String]
    let names: [NSRegularExpression]
    let bundleName: String // AppCleaner's bundleName, used by its prefix-by-name rules
    let workflows: Set<String> // lowercased .workflow names shipped inside the app
    var bundleID: String {
        bundles[0].raw
    }

    /// The Trash renames on a clash ("Foo 14-13-25-482.app"), so there the bundle's own name reads better.
    var displayName: String {
        app.path.hasPrefix(Scanner.home.path + "/.Trash/") && !bundleName.isEmpty ? bundleName : name
    }

    var running: [String] {
        bundles.map(\.raw)
    }
}

struct Leftover: Identifiable {
    let url: URL
    let reason: String // one of Scanner.rank
    let size: Int64
    var id: URL {
        url
    }
}
