import SwiftUI

@main
struct OuterTuneiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AudioSessionConfigurator.configureForPlayback()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                AudioSessionConfigurator.configureForPlayback()
            }
        }
    }
}
