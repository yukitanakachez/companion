import SwiftUI

@main
struct CompanionApp: App {
    var body: some Scene {
        MenuBarExtra("Companion", systemImage: "sparkle") {
            Text("Companion scaffold")
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
