//
//  BIT101_iOSApp.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI
import UIKit

/// 统一管理应用允许的方向集合。
///
/// 项目默认只允许竖屏；当用户在设置里打开自动旋转时，再放开系统旋转。
enum AppOrientationController {
    static func supportedMask(autoRotate: Bool) -> UIInterfaceOrientationMask {
        autoRotate ? .allButUpsideDown : .portrait
    }

    static func currentMask() -> UIInterfaceOrientationMask {
        let snapshot = AppSettingsStore.loadSnapshotFromDefaults() ?? AppSettingsSnapshot()
        return supportedMask(autoRotate: snapshot.autoRotate)
    }

    @MainActor
    static func applyPreference(autoRotate: Bool) {
        let mask = supportedMask(autoRotate: autoRotate)

        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            let preferences = UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: mask)
            windowScene.requestGeometryUpdate(preferences) { _ in }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
}

/// 让 UIKit 在需要时回调当前允许的方向集合。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationController.currentMask()
    }
}

/// iOS 端应用入口。
///
/// 这里仅负责挂载根视图，并把全局主题设置注入到整个场景。
@main
struct BIT101_iOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = AppSettingsStore.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 根场景定义。
    ///
    /// 当前应用只有一个主窗口，主题模式直接由设置中心快照驱动。
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.themeMode.colorScheme)
                .onAppear {
                    AppOrientationController.applyPreference(autoRotate: settings.autoRotate)
                }
                .onChange(of: settings.autoRotate) { _, newValue in
                    AppOrientationController.applyPreference(autoRotate: newValue)
                }
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
