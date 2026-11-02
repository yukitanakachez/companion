import SwiftUI

@main
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Companion", systemImage: "sparkle") {
            Button("Ask…  ⌥Space") { delegate.environment?.coordinator.summon() }
            Button("Settings…") { delegate.environment?.settingsWindow.show() }
            Button("Latency Report") { showLatencyReport() }
            Divider()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }

    private func showLatencyReport() {
        let alert = NSAlert()
        alert.messageText = "Latency Report"
        alert.informativeText = delegate.environment?.trace.summaryText ?? ""
        alert.runModal()
    }
}
