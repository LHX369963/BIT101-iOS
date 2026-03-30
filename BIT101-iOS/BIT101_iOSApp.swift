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
    /// 根据设置快照里的自动旋转选项，生成 UIKit 需要的方向掩码。
    ///
    /// iOS 最终认的是 `UIInterfaceOrientationMask`，而不是 SwiftUI 自己的某种抽象。
    /// 因此这里单独抽出一个转换函数，避免不同入口各自写一遍相同的条件判断。
    static func supportedMask(autoRotate: Bool) -> UIInterfaceOrientationMask {
        autoRotate ? .allButUpsideDown : .portrait
    }

    /// 读取当前持久化设置，给 `UIApplicationDelegate` 提供实时方向限制。
    ///
    /// 这个方法会在系统询问“当前窗口支持哪些方向”时被调用，所以不能依赖
    /// 某个特定的 SwiftUI 视图状态，只能从共享设置快照中读取一个稳定结果。
    static func currentMask() -> UIInterfaceOrientationMask {
        let snapshot = AppSettingsStore.loadSnapshotFromDefaults() ?? AppSettingsSnapshot()
        return supportedMask(autoRotate: snapshot.autoRotate)
    }

    /// 将用户刚修改的自动旋转偏好立即同步给所有已连接的 window scene。
    ///
    /// 仅仅修改设置快照还不够；如果不主动调用 `requestGeometryUpdate`，
    /// 系统通常要等到下一次界面层级变化时才会重新评估方向能力。
    /// 这里遍历所有 scene 和 window，是为了保证主窗口、sheet 以及未来可能
    /// 出现的其它窗口场景都能收到新的方向约束。
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
    /// 提供应用级的方向策略。
    ///
    /// SwiftUI App 生命周期下，大部分 UI 都由 SwiftUI 管，但方向能力的最终仲裁
    /// 仍然会回到 UIKit delegate。这里故意保持极简，只把请求转发给
    /// `AppOrientationController`，避免在 delegate 内部再持有一套重复状态。
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
    /// 全局设置单例，负责驱动主题模式、旋转等跨页面偏好。
    @StateObject private var settings = AppSettingsStore.shared
    /// 保留一个 UIKit delegate 入口，用于响应方向能力查询。
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// 统一触发“共享课表快照 + Live Activity 刷新”。
    ///
    /// 只有在启动和切号这两类场景里，主 app 才需要显式把课表缓存再导出一遍；
    /// 其它常规课表写回路径会在 `ScheduleCacheStore.save` 内部自己完成共享快照导出。
    private func refreshScheduleExternalDisplays(trigger: String, syncWidgetSnapshot: Bool) {
        if syncWidgetSnapshot {
            ScheduleWidgetExporter.syncFromCurrentCache()
        }

        Task {
            // 退出登录或登录失效后，直接结束现有提醒，避免旧 activity 继续挂在灵动岛上。
            let fakeCookie = LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines)
            if fakeCookie.isEmpty {
                await ScheduleLiveActivityManager.shared.endAllActivities()
                return
            }

            await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: trigger)
        }
    }

    /// 根场景定义。
    ///
    /// 当前应用只有一个主窗口，主题模式直接由设置中心快照驱动。
    /// 另外，应用入口也是最适合放置“小组件/灵动岛与登录态、缓存变化保持同步”
    /// 的地方，因为这些副作用本质上都属于“全局应用状态发生变化”。
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(settings.themeMode.colorScheme)
                .onAppear {
                    // 首次挂载时，立即把当前旋转偏好下发给 UIKit。
                    AppOrientationController.applyPreference(autoRotate: settings.autoRotate)
                }
                .onChange(of: settings.autoRotate) { _, newValue in
                    // 设置页改动后，实时收紧或放开方向限制。
                    AppOrientationController.applyPreference(autoRotate: newValue)
                }
                .task {
                    // 启动时补做一次导出与提醒刷新，保证外部展示拿到的是当前账号的最新缓存。
                    refreshScheduleExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .loginStorageDidChange)) { _ in
                    // 切换账号后，组件和灵动岛必须立即改读新账号的缓存。
                    refreshScheduleExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
                }
                .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
                    // 这里主要负责刷新 Live Activity。
                    // widget 快照本身已经在 `ScheduleCacheStore.save` 时同步导出了。
                    refreshScheduleExternalDisplays(trigger: "schedule_cache_changed", syncWidgetSnapshot: false)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // 应用重新回到前台时做一次兜底刷新，避免后台停留期间
                // 课表提醒状态与实际时间脱节。
                refreshScheduleExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: false)
            }
        }
    }
}
