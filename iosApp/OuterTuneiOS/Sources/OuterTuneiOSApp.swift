import SwiftUI

@main
struct OuterTuneiOSApp: App {
    init() {
        AudioSessionConfigurator.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
