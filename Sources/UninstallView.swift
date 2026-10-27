import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - UI

@MainActor @Observable final class Model {
    let title: String
    let subtitle: String
    let icon: NSImage
    let running: [String]
    let sureTitle: String
    let looseNote: String
    var items: [Leftover]?
    var selected = Set<URL>()
    var status: String?
    var query = ""
    var bySize = false
    /// Looked up once per scan, not on every row redraw.
    var icons: [URL: NSImage] = [:]

    init(title: String, subtitle: String, icon: NSImage, running: [String], sureTitle: String, looseNote: String,
         scan: @escaping () -> [Leftover])
    {
        (self.title, self.subtitle, self.icon, self.running) = (title, subtitle, icon, running)
        (self.sureTitle, self.looseNote) = (sureTitle, looseNote)
        Task.detached {
            // An app found by the Trash watcher is already in the Trash: nothing to move there.
            let trash = Scanner.home.path + "/.Trash/"
            let items = scan().filter { !$0.url.path.hasPrefix(trash) }
            await MainActor.run {
                self.icons = Dictionary(items.map { ($0.url, NSWorkspace.shared.icon(forFile: $0.url.path)) },
                                        uniquingKeysWith: { a, _ in a })
                self.items = items
                // Name, group and partial-ID matches can hit other apps: leave them for the user to opt into.
                self.selected = Set(items.filter { Scanner.selectedByDefault.contains($0.reason) }.map(\.url))
            }
        }
    }

    convenience init(_ t: Target) {
        self.init(title: t.displayName, subtitle: t.bundleID, icon: NSWorkspace.shared.icon(forFile: t.app.path),
                  running: t.running, sureTitle: "Belongs to \(t.displayName)",
                  looseNote: "Matched by name, app group or partial ID. These may belong to another app, so they're not ticked.")
        {
            Scanner.scan(t)
        }
    }

    var selectedSize: Int64 {
        (items ?? []).filter { selected.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    var hasApp: Bool {
        items?.contains { $0.reason == "app" } ?? false
    }

    func visible(_ items: [Leftover]) -> [Leftover] {
        let hits = query.isEmpty ? items : items.filter { $0.url.path.localizedCaseInsensitiveContains(query) }
        return bySize ? hits.sorted { $0.size > $1.size } : hits
    }

    /// `keepApp` is AppCleaner's reset: everything selected except the app itself.
    func remove(keepApp: Bool = false, close: () -> Void) {
        let urls = (items ?? []).filter { selected.contains($0.url) && !(keepApp && $0.reason == "app") }.map(\.url)
        do {
            let left = try Remover.remove(urls, bundleIDs: running, name: title)
            if left.isEmpty {
                return close()
            }
            status = "Could not remove:\n" + left.map(\.path).joined(separator: "\n")
            items = items?.filter { left.contains($0.url) || !urls.contains($0.url) }
            selected = Set(left)
        } catch {
            status = error.localizedDescription
        }
    }
}

struct UninstallView: View {
    @Bindable var m: Model
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: m.icon).resizable().frame(width: 56, height: 56).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.title2).bold()
                    Text(m.subtitle).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                if let items = m.items {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("^[\(items.count) item](inflect: true) found")
                        Text(ByteCountFormatter.string(
                            fromByteCount: items.reduce(0) { $0 + $1.size },
                            countStyle: .file
                        ))
                        .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .padding()

            HStack {
                TextField("Filter", text: $m.query, prompt: Text("Filter by path"))
                    .textFieldStyle(.roundedBorder)
                Picker("Sort by", selection: $m.bySize) {
                    Text("Name").tag(false)
                    Text("Size").tag(true)
                }
                .pickerStyle(.segmented).fixedSize()
            }
            .padding([.horizontal, .bottom])

            if let items = m.items {
                let shown = m.visible(items)
                let sure = shown.filter { Scanner.selectedByDefault.contains($0.reason) }
                let loose = shown.filter { !Scanner.selectedByDefault.contains($0.reason) }
                List {
                    if !sure.isEmpty {
                        Section {
                            ForEach(sure) { LeftoverRow(item: $0, m: m) }
                        } header: {
                            SectionHeader(title: m.sureTitle, items: sure, m: m)
                        }
                    }
                    if !loose.isEmpty {
                        Section {
                            ForEach(loose) { LeftoverRow(item: $0, m: m) }
                        } header: {
                            SectionHeader(title: "Possible matches", items: loose, m: m)
                        } footer: {
                            Text(m.looseNote).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(items.isEmpty ? "Nothing Found" : "No Matches",
                                               systemImage: items.isEmpty ? "checkmark.circle" : "magnifyingglass")
                    }
                }
            } else {
                ProgressView("Scanning…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let s = m.status {
                Label(s, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])
            }

            HStack {
                Text(
                    "^[\(m.selected.count) item](inflect: true) selected · \(ByteCountFormatter.string(fromByteCount: m.selectedSize, countStyle: .file))"
                )
                .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                if m.hasApp {
                    Button("Remove Leftovers Only", action: removeLeftovers)
                        .disabled(m.selected.subtracting((m.items ?? []).filter { $0.reason == "app" }.map(\.url))
                            .isEmpty)
                        .help("Keep the app and remove the rest of the selection, like a fresh install.")
                }
                Button("Move to Trash", systemImage: "trash", role: .destructive, action: remove)
                    .buttonStyle(.borderedProminent).tint(.red)
                    .keyboardShortcut(.defaultAction).disabled(m.items == nil || m.selected.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 680, minHeight: 540)
    }

    func remove() {
        m.remove(close: close)
    }

    func removeLeftovers() {
        m.remove(keepApp: true, close: close)
    }
}

struct SectionHeader: View {
    let title: String
    let items: [Leftover]
    let m: Model

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button("Select All", action: selectAll)
            Button("Select None", action: selectNone)
        }
        .buttonStyle(.link)
    }

    func selectAll() {
        m.selected.formUnion(items.map(\.url))
    }

    func selectNone() {
        m.selected.subtract(items.map(\.url))
    }
}

struct LeftoverRow: View {
    let item: Leftover
    let m: Model

    var body: some View {
        Toggle(isOn: Binding(get: { m.selected.contains(item.url) },
                             set: {
                                 if $0 {
                                     m.selected.insert(item.url)
                                 } else {
                                     m.selected.remove(item.url)
                                 }
                             })) {
            HStack(spacing: 8) {
                if let icon = m.icons[item.url] {
                    Image(nsImage: icon).resizable().frame(width: 24, height: 24).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Text((item.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .help(item.url.path)
                Spacer()
                // Only opt-in rows need the reason (the default section is all app or bundle ID), and not when
                // the file name already says it, as with most orphans.
                if !Scanner.selectedByDefault.contains(item.reason),
                   !item.url.lastPathComponent.hasPrefix(item.reason)
                {
                    Text(item.reason)
                        .font(.caption)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                        .foregroundStyle(.secondary)
                }
                Text(ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
            .padding(.vertical, 2)
        }
        .contextMenu { Button("Reveal in Finder", systemImage: "folder", action: reveal) }
    }

    func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}
