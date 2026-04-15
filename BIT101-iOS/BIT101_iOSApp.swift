//
//  BIT101_iOSApp.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI
import BackgroundTasks
import UIKit

/// 每日首次进入应用时的静默 DDL 同步协调器。
///
/// 目标：
/// - 只在当天第一次进入 app 时尝试一次
/// - 不打断前台，不弹成功/失败提示
/// - 仅对“已经启用过乐学 DDL”的账号生效，避免从未使用过 DDL 的用户被动发起请求
enum DDLSilentRefreshCoordinator {
    /// 记录“某个账号今天已经尝试过静默同步”的 key 前缀。
    ///
    /// 这里显式标记成 `nonisolated`，是因为后台任务闭包会在非主线程里拼 key。
    nonisolated private static let lastAttemptKeyPrefix = "schedule.ddl.silent-refresh.last-attempt"
    private static let gate = Gate()

    /// 防止启动、回前台、登录态变化等多个入口在同一时刻重复发起静默同步。
    private actor Gate {
        private var activeStudentIDs: Set<String> = []

        func runIfNeeded(for studentID: String, operation: @Sendable () async -> Void) async {
            guard activeStudentIDs.insert(studentID).inserted else { return }
            defer { activeStudentIDs.remove(studentID) }
            await operation()
        }
    }

    /// 在合适时机尝试静默同步当日 DDL。
    ///
    /// 调用方不需要关心“今天是否已经试过”或“当前是否有其它入口正在同步”；
    /// 这些约束统一由协调器内部处理。
    nonisolated static func refreshIfNeeded(trigger: String) {
        Task(priority: .utility) {
            // 登录态和本地账号信息目前仍由主 actor 托管，因此这里先切回主线程
            // 把参与静默同步判断的最小信息读出来，再在后台继续执行后续流程。
            let (fakeCookie, studentID) = await MainActor.run {
                (
                    LoginStorage.shared.fakeCookie.trimmingCharacters(in: .whitespacesAndNewlines),
                    LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard !fakeCookie.isEmpty else { return }
            guard !studentID.isEmpty else { return }

            await gate.runIfNeeded(for: studentID) {
                // `ScheduleCacheStore` 仍是主端真相源的一部分，这里复用主 actor 上的快照。
                let cache = await MainActor.run { ScheduleCacheStore.load() }
                let hasLexueSyncHistory =
                    !cache.lexueCalendarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    cache.ddlEvents.contains(where: { $0.group == "lexue" })
                guard hasLexueSyncHistory else { return }

                let attemptKey = "\(lastAttemptKeyPrefix).\(studentID)"
                let todayStamp = dayStamp(for: Date())
                guard UserDefaults.standard.string(forKey: attemptKey) != todayStamp else { return }

                // 这里按“尝试一次”记账，而不是按“成功一次”记账。
                // 用户要求的是“当天首次进入 app 时静默拉取一次”，而不是失败后反复重试。
                UserDefaults.standard.set(todayStamp, forKey: attemptKey)

                do {
                    // `ScheduleService` 当前还依赖主端登录态与 cookie 存储，因此在主 actor 上构造。
                    let service = await MainActor.run { ScheduleService() }
                    let manualEvents = cache.ddlEvents.filter { $0.group != "lexue" }
                    let payload = try await service.syncDDLEvents(
                        existingEvents: cache.ddlEvents,
                        storedURL: cache.lexueCalendarURL
                    )

                    var updatedCache = cache
                    updatedCache.lexueCalendarURL = payload.url
                    updatedCache.ddlEvents = (manualEvents + payload.events).sorted { $0.dueAt < $1.dueAt }
                    let cacheToSave = updatedCache
                    // 保存动作会顺带触发共享快照导出与外部展示刷新，因此也回到主 actor 执行。
                    await MainActor.run { ScheduleCacheStore.save(cacheToSave) }
                } catch {
                    // 静默同步失败不打断前台，也不弹提示。
                    _ = trigger
                }
            }
        }
    }

    /// 生成“本地自然日”粒度的日期戳。
    ///
    /// 使用当前时区的 `yyyy-MM-dd`，确保“每天一次”的判定和用户体感一致。
    nonisolated private static func dayStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

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
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        ScheduleReminderBackgroundRefresh.register()
        return true
    }

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

/// 课前提醒的后台刷新协调器。
///
/// 这条链路只是 best-effort：
/// - 由系统决定实际什么时候唤醒 app
/// - 唤醒后重新执行一遍日程提醒计算，尽量让灵动岛在后台也有机会启动
/// - 同时重新提交下一次刷新请求，维持后续链路
enum ScheduleReminderBackgroundRefresh {
    /// 后台刷新任务标识。
    ///
    /// 与 Info.plist 中的 `BGTaskSchedulerPermittedIdentifiers` 保持同源，避免切换 bundle id
    /// 或调试/正式包共存时出现 identifier 不一致。
    static var identifier: String {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "BIT101-dev.BIT101-iOS"
        return "\(bundleIdentifier).schedule-refresh"
    }

    /// 在应用启动阶段注册后台刷新任务。
    ///
    /// Apple 要求所有 BGTask 都必须在启动序列结束前注册；因此这里放在
    /// `UIApplicationDelegate` 的 `didFinishLaunching` 里最稳妥。
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask)
        }
    }

    /// 根据下一次课前提醒边界，提交一条后台刷新请求。
    ///
    /// 重新提交同一 identifier 的请求时，系统会用新的请求替换旧请求。
    static func schedule(earliestBeginDate: Date?) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        guard let earliestBeginDate else { return }

        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate

        try? BGTaskScheduler.shared.submit(request)
    }

    /// 后台刷新任务入口。
    ///
    /// 一旦系统真的唤醒 app，这里就重新跑一遍提醒计算，并预排下一次后台刷新。
    private static func handle(task: BGAppRefreshTask) {
        let operation = Task {
            let nextBeginDate = ScheduleLiveActivityManager.shared.preferredBackgroundRefreshBeginDate()
            schedule(earliestBeginDate: nextBeginDate)
            await ScheduleLiveActivityManager.shared.refreshFromCurrentCache(trigger: "bg_app_refresh")
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            operation.cancel()
        }
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
            let nextBeginDate = ScheduleLiveActivityManager.shared.preferredBackgroundRefreshBeginDate()
            ScheduleReminderBackgroundRefresh.schedule(earliestBeginDate: nextBeginDate)

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
                    // 启动后先激活 WatchConnectivity，保证 watch 端发来的“重新同步”请求有人接。
                    WatchScheduleSyncManager.shared.activateIfNeeded()

                    // 启动时补做一次导出与提醒刷新，保证外部展示拿到的是当前账号的最新缓存。
                    refreshScheduleExternalDisplays(trigger: "app_launch_task", syncWidgetSnapshot: true)
                    DDLSilentRefreshCoordinator.refreshIfNeeded(trigger: "app_launch_task")
                }
                .onReceive(NotificationCenter.default.publisher(for: .loginStorageDidChange)) { _ in
                    // 切换账号后，组件和灵动岛必须立即改读新账号的缓存。
                    refreshScheduleExternalDisplays(trigger: "login_storage_changed", syncWidgetSnapshot: true)
                    DDLSilentRefreshCoordinator.refreshIfNeeded(trigger: "login_storage_changed")
                }
                .onReceive(NotificationCenter.default.publisher(for: .scheduleCacheDidChange)) { _ in
                    // 这里主要负责刷新 Live Activity。
                    // widget 快照本身已经在 `ScheduleCacheStore.save` 时同步导出了。
                    refreshScheduleExternalDisplays(trigger: "schedule_cache_changed", syncWidgetSnapshot: false)
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                // 应用重新回到前台时，同时补做一次 widget 快照导出与时间线刷新。
                // 否则即便用户主动打开 app，桌面/锁屏小组件也可能继续沿用后台停留期间的旧条目。
                refreshScheduleExternalDisplays(trigger: "scene_active", syncWidgetSnapshot: true)
                DDLSilentRefreshCoordinator.refreshIfNeeded(trigger: "scene_active")
            }
        }
    }
}
