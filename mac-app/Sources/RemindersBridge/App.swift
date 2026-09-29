import SwiftUI
import AppKit

@main
struct RemindersBridgeApp: App {
    @StateObject private var controller = SyncController()
    var body: some Scene {
        MenuBarExtra("Obsidian Reminders", systemImage: "checklist") {
            BridgeMenu(controller: controller)
        }
        Window("Obsidian Reminders Bridge", id: "settings") {
            SettingsView(controller: controller)
        }.defaultSize(width: 560, height: 340)
    }
}
private struct BridgeMenu: View {
    @ObservedObject var controller: SyncController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(controller.status)
        Button("Sync now") { Task { await controller.sync() } }.disabled(controller.busy || controller.paused)
        Toggle("Pause sync", isOn: $controller.paused)
        Divider()
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate(ignoringOtherApps: true) }
        Button("Quit") { NSApp.terminate(nil) }
    }
}
private struct SettingsView: View {
    @ObservedObject var controller: SyncController
    @State private var configDraft = ".obsidian"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Obsidian ↔ Apple Reminders").font(.title2.bold())
            Text("Tasks and dates come from Obsidian. Completion syncs both ways.")
            HStack {
                Text(controller.vaultPath.isEmpty ? "No vault selected" : controller.vaultPath)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                Button("Choose vault…") { controller.chooseVault() }.disabled(controller.busy)
            }
            HStack {
                Text("Obsidian config folder")
                TextField(".obsidian", text: $configDraft)
                Button("Apply") { controller.saveConfiguration(configDraft) }.disabled(controller.busy)
            }
            Toggle("Launch at login", isOn: Binding(get: { controller.loginEnabled }, set: { controller.setLogin($0) }))
            Toggle("Pause sync", isOn: $controller.paused)
            Text(controller.status).font(.callout).textSelection(.enabled)
            HStack {
                Button(controller.busy ? "Syncing…" : "Sync now") { Task { await controller.sync() } }
                    .disabled(controller.busy || controller.paused)
                Spacer()
                Text("Keep Obsidian open with the companion plugin enabled.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).onAppear { configDraft = controller.configDirectory }
    }
}
