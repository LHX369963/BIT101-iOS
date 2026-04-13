import SwiftUI

@main
struct BIT101WatchExtensionApp: App {
    @StateObject private var model = WatchScheduleStatusModel()

    var body: some Scene {
        WindowGroup {
            WatchScheduleRootView(model: model)
                .task {
                    model.activate()
                }
        }
    }
}
