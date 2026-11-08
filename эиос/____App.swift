import SwiftUI

@main
@MainActor
struct EIOSApp: App {
    @UIApplicationDelegateAdaptor(SmartTableAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
