import SwiftUI
import AppKit

@main
struct RemindersBridgeApp: App {
    @StateObject private var controller = SyncController()

    var body: some Scene {
        MenuBarExtra {
            BridgeMenu(controller: controller)
        } label: {
            Image(systemName: BridgeStatus(controller).menuBarSymbol)
                .accessibilityLabel("Reminders Bridge")
        }.menuBarExtraStyle(.menu)

        Settings {
            SettingsView(controller: controller)
        }.windowResizability(.contentSize)
    }
}

/// One place that turns controller state into what the user sees,
/// so the menu bar icon and menu never disagree.
private struct BridgeStatus {
    enum Kind { case setup, paused, attention, syncing, review, updating, waiting, upToDate }
    let kind: Kind
    let detail: String

    @MainActor init(_ controller: SyncController) {
        let tasks = { (count: Int) in "\(count) \(count == 1 ? "task" : "tasks")" }
        if controller.vaultPath.isEmpty { kind = .setup; detail = "Choose a vault to get started" }
        else if controller.paused { kind = .paused; detail = "Sync paused" }
        else if controller.errorMessage != nil { kind = .attention; detail = "Sync needs attention" }
        else if controller.syncing { kind = .syncing; detail = "Syncing…" }
        else if controller.uncertainCount > 0 { kind = .review; detail = "\(tasks(controller.uncertainCount)) to review" }
        else if controller.pendingCount > 0 { kind = .updating; detail = "Updating Reminders…" }
        else if controller.waitingForObsidian || controller.lastSuccessfulSync == nil { kind = .waiting; detail = "Waiting for Obsidian" }
        else { kind = .upToDate; detail = "Up to date" }
    }

    /// A small status dot, as System Settings shows next to services.
    var tint: Color {
        switch kind {
        case .upToDate: .green
        case .attention, .review: .orange
        case .syncing, .updating: .blue
        case .setup, .paused, .waiting: .gray
        }
    }
    /// The same dot as in Settings. Menus tint images as templates, so this
    /// one is drawn as a non-template image to keep its colour.
    var menuDot: NSImage {
        let color = NSColor(tint)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
    var menuBarSymbol: String {
        switch kind {
        case .attention, .review: "exclamationmark.triangle"
        case .paused: "pause.circle"
        default: "checklist"
        }
    }
}

/// The line under the status: the error when there is one, otherwise when it last synced.
private struct StatusDetail {
    let text: String?

    @MainActor init(_ controller: SyncController, status: BridgeStatus) {
        if status.kind == .attention, let message = controller.errorMessage { text = message }
        else if let date = controller.lastSuccessfulSync { text = "Last synced at \(date.formatted(date: .omitted, time: .shortened))" }
        else { text = nil }
    }
}

// MARK: - Menu bar menu

/// A real system menu, like Time Machine's: status lines on top, then actions.
private struct BridgeMenu: View {
    @ObservedObject var controller: SyncController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let hasVault = !controller.vaultPath.isEmpty
        let status = BridgeStatus(controller)
        Section {
            Button(action: showSettings) {
                Label { Text(status.detail) } icon: { Image(nsImage: status.menuDot) }
            }
            // Same second line as the status row in Settings.
            if let detail = StatusDetail(controller, status: status).text {
                Text(detail)
            }
        }
        if status.kind == .attention, let fix = controller.errorFix {
            switch fix {
            case .openObsidian:
                Button("Open Obsidian", systemImage: "arrow.up.forward.app") { controller.openVault() }
            case .allowRemindersAccess:
                Button("Open Privacy Settings…", systemImage: "hand.raised") { controller.openRemindersPrivacySettings() }
            case .chooseVault:
                Button("Choose Vault…", systemImage: "folder") { controller.chooseVault() }
            }
        }
        if status.kind == .review {
            Button("Review \(controller.uncertainCount) \(controller.uncertainCount == 1 ? "Task" : "Tasks") in Obsidian…",
                   systemImage: "exclamationmark.triangle") { controller.openReviewLinks() }
        }
        Divider()
        if hasVault {
            Button(status.kind == .attention ? "Try Again" : "Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                Task { await controller.sync(userInitiated: true) }
            }.disabled(controller.syncing || controller.paused)
            Button(controller.paused ? "Resume Sync" : "Pause Sync", systemImage: controller.paused ? "play" : "pause") {
                controller.paused.toggle()
                if !controller.paused { Task { await controller.sync(userInitiated: true) } }
            }
        } else {
            Button("Choose Vault…", systemImage: "folder") { controller.chooseVault() }
        }
        Divider()
        Button("Open Vault in Obsidian", systemImage: "arrow.up.forward.app") { controller.openVault() }
            .disabled(!hasVault)
        Button("Open Reminders", systemImage: "checklist", action: openReminders)
        Divider()
        Button("Settings…", systemImage: "gearshape", action: showSettings)
        Button("Quit Reminders Bridge", systemImage: "power") { NSApp.terminate(nil) }
    }

    private func openReminders() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: .init())
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Settings

/// Every row is a label on the left and at most one control on the right,
/// so all controls share one trailing edge. Errors appear in the status row.
private struct SettingsView: View {
    @ObservedObject var controller: SyncController
    private enum Field { case list, configuration }

    @State private var listDraft = "Obsidian"
    @State private var configDraft = ".obsidian"
    @FocusState private var focus: Field?
    /// Buttons share one width so they read as a column.
    private static let buttonWidth: CGFloat = 76

    var body: some View {
        let status = BridgeStatus(controller)
        Form {
            Section {
                LabeledContent {
                    if !controller.vaultPath.isEmpty {
                        Button {
                            Task { await controller.sync(userInitiated: true) }
                        } label: {
                            Text(status.kind == .attention ? "Try Again" : "Sync Now").frame(width: Self.buttonWidth)
                        }.disabled(controller.syncing || controller.paused)
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(status.tint).frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(status.detail)
                            if let detail = StatusDetail(controller, status: status).text {
                                Text(detail).font(.callout).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            Section {
                LabeledContent {
                    Button { controller.chooseVault() } label: {
                        Text("Choose…").frame(width: Self.buttonWidth)
                    }.disabled(controller.busy)
                } label: {
                    Text("Obsidian vault")
                    Text(controller.vaultPath.isEmpty ? "None selected" : (controller.vaultPath as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1).truncationMode(.middle)
                        .help(controller.vaultPath)
                }
                LabeledContent {
                    TextField("Reminders list", text: $listDraft, prompt: Text("Obsidian"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading).frame(width: 160)
                        .focused($focus, equals: .list)
                        .onSubmit(commitListName)
                        .disabled(controller.vaultPath.isEmpty)
                } label: {
                    Text("Reminders list name")
                    Text("Synced tasks go into this list")
                }
                LabeledContent {
                    TextField("Configuration folder", text: $configDraft, prompt: Text(".obsidian"))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.leading).frame(width: 160)
                        .focused($focus, equals: .configuration)
                        .onSubmit(commitConfiguration)
                        .disabled(controller.vaultPath.isEmpty)
                } label: {
                    Text("Configuration folder")
                    Text("Usually .obsidian; found automatically")
                }
            }

            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { controller.loginEnabled },
                    set: { controller.setLogin($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(TextFieldFocusBehavior())
        .navigationTitle("Reminders Bridge Settings")
        .onAppear {
            listDraft = controller.listName
            configDraft = controller.configDirectory
        }
        .onChange(of: controller.listName) { _, name in listDraft = name }
        .onChange(of: controller.configDirectory) { _, name in configDraft = name }
        .onChange(of: focus) { previous, _ in
            if previous == .list { commitListName() }
            if previous == .configuration { commitConfiguration() }
        }
    }

    private func commitConfiguration() {
        let name = configDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != controller.configDirectory, !controller.busy else { configDraft = controller.configDirectory; return }
        controller.saveConfiguration(name)
    }

    private func commitListName() {
        let name = listDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != controller.listName, !controller.busy else { listDraft = controller.listName; return }
        Task { await controller.saveListName(name) }
    }
}

/// Two AppKit focus habits that feel wrong in a settings window:
/// it opens with the first text field selected, and clicking elsewhere
/// never ends editing. Clear focus on open and on any click outside the field.
private struct TextFieldFocusBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) { }

    private final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        private var clickMonitor: Any?
        private var opened = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            // Clear once per opening, so switching apps mid-edit keeps the cursor.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.opened else { return }
                    self.opened = true
                    DispatchQueue.main.async { window?.makeFirstResponder(nil) }
                }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.opened = false }
            })
            clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak window] event in
                guard let window, event.window === window,
                      let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                      let field = editor.delegate as? NSView else { return event }
                if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                    window.makeFirstResponder(nil)
                }
                return event
            }
        }

        private func stopObserving() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
            clickMonitor = nil
        }

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        }
    }
}
