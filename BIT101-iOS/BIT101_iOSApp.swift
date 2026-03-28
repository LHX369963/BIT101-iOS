//
//  BIT101_iOSApp.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI

/// iOS 端应用入口。
///
/// 这里仅负责挂载根视图，并把全局主题设置注入到整个场景。
@main
struct BIT101_iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = AppSettingsStore.shared

    /// 根场景定义。
    ///
    /// 当前应用只有一个主窗口，主题模式直接由设置中心快照驱动。
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.themeMode.colorScheme)
                .task {
                    ScheduleWidgetExporter.syncFromCurrentCache()
                    await ScheduleLiveActivityManager.shared.refreshFromCurrentCache()
                }
                .onReceive(NotificationCenter.default.publisher(for: .loginStorageDidChange)) { _ in
                    ScheduleWidgetExporter.syncFromCurrentCache()
                    Task {
                        await ScheduleLiveActivityManager.shared.refreshFromCurrentCache()
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
                    Task {
                        await ScheduleLiveActivityManager.shared.refreshFromCurrentCache()
                    }
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                Task {
                    await ScheduleLiveActivityManager.shared.refreshFromCurrentCache()
                }
            }
        }
    }
}
