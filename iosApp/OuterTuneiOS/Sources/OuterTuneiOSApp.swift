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
            switch phase {
            case .active, .inactive, .background:
                AudioSessionConfigurator.configureForPlayback()
            @unknown default:
                break
            }
        }
    }
}
