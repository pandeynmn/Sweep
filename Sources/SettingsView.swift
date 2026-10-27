import AppKit
import Security
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Settings

enum CLI {
    static let link = "/usr/local/bin/sweep" // on the default PATH via /etc/paths
    static var target: String {
        Bundle.main.executablePath!
    }

    static var installed: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == target
    }

    /// Something else already owns the name; don't overwrite it.
    static var taken: Bool {
        Remover.exists(URL(fileURLWithPath: link)) && !installed
    }

    @MainActor static func setInstalled(_ on: Bool) throws {
        let cmd = on ? "mkdir -p /usr/local/bin && ln -sf \(Remover.shellQuote(target)) \(link)" : "rm -f \(link)"
        try Remover.appleScript("do shell script \(Remover.asString(cmd)) with administrator privileges")
    }
}

struct SettingsView: View {
    @State private var installed = CLI.installed
    @State private var login = SMAppService.mainApp.status
    @AppStorage("watchTrash") private var watchTrash = true
    @State private var error: String?

    var body: some View {
        Form {
            Section("General") {
                // Not $state + onChange for these two: the setters re-read the real state, which would fire onChange
                // again.
                Toggle(isOn: Binding(get: { login == .enabled }, set: { setLogin($0) })) {
                    Text("Open at login")
                    if login == .requiresApproval {
                        Text("Allow Sweep in System Settings › General › Login Items.")
                    }
                }
                Toggle(isOn: $watchTrash) {
                    Text("Clean up after apps moved to the Trash")
                    Text("Sweep notices an app landing in the Trash and offers to remove what it left behind.")
                }
                .onChange(of: watchTrash) { _, on in (NSApp.delegate as? AppDelegate)?.watchTrash(on) }
            }

            Section {
                LabeledContent {} label: {
                    Text("Uninstall with Sweep")
                    Text("Review what was found and pick what goes.")
                }
                LabeledContent {} label: {
                    Text("Delete Everything with Sweep")
                    Text("One confirmation, then the app and everything found go to the Trash.")
                }
            } header: {
                Text("Finder Quick Actions")
            } footer: {
                Text(
                    "Right-click an app in Finder and open Quick Actions. Missing? Turn them on in System Settings › Keyboard › Keyboard Shortcuts › Services."
                )
                .foregroundStyle(.secondary)
            }

            Section("Command Line") {
                Toggle(isOn: Binding(get: { installed }, set: { setInstalled($0) })) {
                    Text("Install sweep command")
                    Text(CLI.taken ? "\(CLI.link) already exists and isn't Sweep's, so it's left alone." : CLI.link)
                }
                .disabled(CLI.taken)
                LabeledContent {} label: {
                    Text("List what would be removed")
                    Text(verbatim: "sweep --scan <app>").monospaced().textSelection(.enabled)
                }
                LabeledContent {} label: {
                    Text("Trash the app and everything found, without asking")
                    Text(verbatim: "sweep --uninstall <app>").monospaced().textSelection(.enabled)
                }
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        // A grouped Form is a scroll view; this makes it report its content height so the window can size to fit.
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 520)
        .onAppear(perform: refresh)
    }

    func refresh() {
        installed = CLI.installed
        login = SMAppService.mainApp.status
    }

    func setInstalled(_ on: Bool) {
        error = nil
        do { try CLI.setInstalled(on) } catch { self.error = error.localizedDescription }
        installed = CLI.installed // unchanged if the password prompt was cancelled
    }

    func setLogin(_ on: Bool) {
        error = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        login = SMAppService.mainApp.status
    }
}
