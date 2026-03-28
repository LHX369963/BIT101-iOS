//
//  AppSettingsStore.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation
import SwiftUI

extension Notification.Name {
    static let loginStorageDidChange = Notification.Name("BIT101.LoginStorageDidChange")
}

/// 应用层主题模式。
enum AppThemeMode: String, CaseIterable, Identifiable, Codable {
    case system
    case light
    case dark

    /// 供 `Picker` 和持久化使用的稳定标识。
    var id: String { rawValue }

    /// 设置页展示的主题标题。
    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 对应 SwiftUI 使用的 `ColorScheme`。
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

/// 被用户本地隐藏的帖子摘要。
struct HiddenPosterRecord: Codable, Equatable, Identifiable, Hashable {
    let id: Int
    let title: String
    let userID: Int
    let userNickname: String
    let createdTime: String
}

/// 持久化到 `UserDefaults` 的设置快照。
struct AppSettingsSnapshot: Codable, Equatable {
    /// 启动后默认选中的 tab。
    var homeTab: AppTab = .schedule
    /// 底部栏页面顺序。
    var pageOrder: [AppTab] = AppTab.allCases
    /// 被用户隐藏的 tab。
    var hiddenTabs: [AppTab] = []
    /// 是否允许动态主题效果。
    var dynamicTheme = true
    /// 用户主动指定的主题模式。
    var themeMode: AppThemeMode = .system
    /// 是否允许界面自动旋转。
    var autoRotate = false
    /// 是否隐藏带机器人标签的帖子。
    var galleryHideBotPoster = false
    /// 是否在搜索结果里也隐藏机器人帖子。
    var galleryHideBotPosterInSearch = false
    /// 是否启用更严格的话题过滤。
    var galleryHideStrictMode = false
    /// 是否允许话题页左右轻扫切换。
    var galleryAllowHorizontalScroll = false
    /// 用户主动屏蔽的用户 ID 列表。
    var galleryHiddenUserIDs: [Int] = []
    /// 用户主动隐藏的帖子摘要。
    var galleryHiddenPosters: [HiddenPosterRecord] = []
    /// 当前设备接受过的社区规则版本号。
    var galleryCommunityRulesAcceptedVersion = 0
    /// 是否自动检查新版本。
    var autoDetectUpgrade = true
    /// 被用户忽略的版本号。
    var ignoredVersion: Int = -1
}

@MainActor
/// 全局设置仓库。
///
/// 页面顺序、主题、话题过滤规则等都会统一写入这里，再由具体页面按需读取。
final class AppSettingsStore: ObservableObject {
    static let shared = AppSettingsStore()
    nonisolated static let storageKeyPrefix = "app.settings.snapshot"
    nonisolated static let currentCommunityRulesVersion = 2

    @Published private(set) var snapshot = AppSettingsSnapshot()

    private let defaults = UserDefaults.standard
    private var accountObserver: NSObjectProtocol?

    private init() {
        load()
        accountObserver = NotificationCenter.default.addObserver(
            forName: .loginStorageDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.load()
        }
    }

    deinit {
        if let accountObserver {
            NotificationCenter.default.removeObserver(accountObserver)
        }
    }

    var homeTab: AppTab { snapshot.homeTab }
    var pageOrder: [AppTab] { snapshot.pageOrder }
    var hiddenTabs: [AppTab] { snapshot.hiddenTabs }
    var dynamicTheme: Bool { snapshot.dynamicTheme }
    var themeMode: AppThemeMode { snapshot.themeMode }
    var autoRotate: Bool { snapshot.autoRotate }
    var galleryHideBotPoster: Bool { snapshot.galleryHideBotPoster }
    var galleryHideBotPosterInSearch: Bool { snapshot.galleryHideBotPosterInSearch }
    var galleryHideStrictMode: Bool { snapshot.galleryHideStrictMode }
    var galleryAllowHorizontalScroll: Bool { snapshot.galleryAllowHorizontalScroll }
    var galleryHiddenUserIDs: [Int] { snapshot.galleryHiddenUserIDs }
    var galleryHiddenPosters: [HiddenPosterRecord] { snapshot.galleryHiddenPosters }
    var galleryHiddenPosterIDs: [Int] { snapshot.galleryHiddenPosters.map(\.id) }
    var hasAcceptedCurrentCommunityRules: Bool { snapshot.galleryCommunityRulesAcceptedVersion >= Self.currentCommunityRulesVersion }
    var autoDetectUpgrade: Bool { snapshot.autoDetectUpgrade }
    var ignoredVersion: Int { snapshot.ignoredVersion }

    /// 当前真正可见的底部页面集合。
    var visibleTabs: [AppTab] {
        snapshot.pageOrder.filter { tab in
            tab == .mine || !snapshot.hiddenTabs.contains(tab)
        }
    }

    /// 修改默认启动页。
    func setHomeTab(_ tab: AppTab) {
        snapshot.homeTab = tab
        save()
    }

    /// 保存底部栏顺序。
    func setPageOrder(_ tabs: [AppTab]) {
        snapshot.pageOrder = normalizePageOrder(tabs)
        save()
    }

    /// 保存被隐藏的 tab 集合。
    func setHiddenTabs(_ tabs: [AppTab]) {
        snapshot.hiddenTabs = tabs.filter { $0 != .mine }
        if snapshot.hiddenTabs.contains(snapshot.homeTab) {
            snapshot.homeTab = visibleTabs.first ?? .schedule
        }
        save()
    }

    /// 重置页面顺序和默认页设置。
    func resetPageSettings() {
        snapshot.pageOrder = AppTab.allCases
        snapshot.hiddenTabs = []
        snapshot.homeTab = .schedule
        save()
    }

    /// 修改动态主题开关。
    func setDynamicTheme(_ enabled: Bool) {
        snapshot.dynamicTheme = enabled
        save()
    }

    /// 修改固定主题模式。
    func setThemeMode(_ mode: AppThemeMode) {
        snapshot.themeMode = mode
        save()
    }

    /// 修改自动旋转开关。
    func setAutoRotate(_ enabled: Bool) {
        snapshot.autoRotate = enabled
        save()
    }

    /// 一次性更新话题治理相关设置。
    func updateGallerySettings(
        hideBotPoster: Bool? = nil,
        hideBotPosterInSearch: Bool? = nil,
        hideStrictMode: Bool? = nil,
        allowHorizontalScroll: Bool? = nil,
        hiddenUserIDs: [Int]? = nil
    ) {
        if let hideBotPoster { snapshot.galleryHideBotPoster = hideBotPoster }
        if let hideBotPosterInSearch { snapshot.galleryHideBotPosterInSearch = hideBotPosterInSearch }
        if let hideStrictMode { snapshot.galleryHideStrictMode = hideStrictMode }
        if let allowHorizontalScroll { snapshot.galleryAllowHorizontalScroll = allowHorizontalScroll }
        if let hiddenUserIDs { snapshot.galleryHiddenUserIDs = hiddenUserIDs }
        save()
    }

    /// 在隐藏匿名用户和恢复匿名用户之间切换。
    func toggleHideAnonymous() {
        if snapshot.galleryHiddenUserIDs.first == -1 {
            snapshot.galleryHiddenUserIDs.removeFirst()
        } else {
            snapshot.galleryHiddenUserIDs.insert(-1, at: 0)
        }
        save()
    }

    /// 删除一条已屏蔽用户记录。
    func removeHiddenUser(at index: Int) {
        guard snapshot.galleryHiddenUserIDs.indices.contains(index) else { return }
        snapshot.galleryHiddenUserIDs.remove(at: index)
        save()
    }

    /// 把一条帖子加入本地隐藏列表。
    func hidePoster(id: Int, title: String, userID: Int, userNickname: String, createdTime: String) {
        snapshot.galleryHiddenPosters.removeAll { $0.id == id }
        snapshot.galleryHiddenPosters.insert(
            HiddenPosterRecord(
                id: id,
                title: title,
                userID: userID,
                userNickname: userNickname,
                createdTime: createdTime
            ),
            at: 0
        )
        save()
    }

    /// 删除一条已隐藏帖子记录。
    func removeHiddenPoster(at index: Int) {
        guard snapshot.galleryHiddenPosters.indices.contains(index) else { return }
        snapshot.galleryHiddenPosters.remove(at: index)
        save()
    }

    /// 记录当前设备已经同意最新社区规则。
    func acceptCurrentCommunityRules() {
        snapshot.galleryCommunityRulesAcceptedVersion = Self.currentCommunityRulesVersion
        save()
    }

    /// 撤销社区规则同意状态，方便重新验证 EULA。
    func revokeCommunityRulesAcceptance() {
        snapshot.galleryCommunityRulesAcceptedVersion = 0
        save()
    }

    /// 修改自动检查更新开关。
    func setAutoDetectUpgrade(_ enabled: Bool) {
        snapshot.autoDetectUpgrade = enabled
        save()
    }

    /// 记录用户忽略的版本号。
    func setIgnoredVersion(_ version: Int) {
        snapshot.ignoredVersion = version
        save()
    }

    /// 把设置恢复到默认值。
    func resetToDefaults() {
        snapshot = AppSettingsSnapshot()
        save()
    }

    /// 从 `UserDefaults` 加载设置快照。
    private func load() {
        guard let snapshot = Self.loadSnapshotFromDefaults() else {
            self.snapshot = AppSettingsSnapshot()
            return
        }
        self.snapshot = snapshot
        self.snapshot.pageOrder = normalizePageOrder(self.snapshot.pageOrder)
        self.snapshot.hiddenTabs = self.snapshot.hiddenTabs.filter { $0 != .mine }
    }

    /// 把当前快照写回 `UserDefaults`。
    private func save() {
        if let data = try? JSONEncoder().encode(snapshot) {
            defaults.set(data, forKey: currentStorageKey)
        }
    }

    /// 提供给非主线程读取的只读快照加载入口。
    static func loadSnapshotFromDefaults() -> AppSettingsSnapshot? {
        loadSnapshotFromDefaults(for: currentAccountIdentifier())
    }

    /// 读取指定账号对应的设置快照。
    static func loadSnapshotFromDefaults(for accountID: String) -> AppSettingsSnapshot? {
        guard
            let data = UserDefaults.standard.data(forKey: storageKey(for: accountID)),
            let snapshot = try? JSONDecoder().decode(AppSettingsSnapshot.self, from: data)
        else {
            return nil
        }
        return snapshot
    }

    private var currentStorageKey: String {
        Self.storageKey(for: Self.currentAccountIdentifier())
    }

    private static func storageKey(for accountID: String) -> String {
        "\(storageKeyPrefix).\(accountID)"
    }

    private static func currentAccountIdentifier() -> String {
        let raw = LoginStorage.shared.currentStudentID.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "__default__" : raw
    }

    /// 修正页面顺序，避免重复、缺失和旧版本快照造成的异常。
    private func normalizePageOrder(_ tabs: [AppTab]) -> [AppTab] {
        // 防止重复 tab、缺失 tab 或旧版本快照导致页面顺序异常。
        var ordered: [AppTab] = []
        for tab in tabs where !ordered.contains(tab) {
            ordered.append(tab)
        }
        for tab in AppTab.allCases where !ordered.contains(tab) {
            ordered.append(tab)
        }
        if
            let galleryIndex = ordered.firstIndex(of: .gallery),
            let scoreIndex = ordered.firstIndex(of: .score),
            scoreIndex < galleryIndex
        {
            let scoreTab = ordered.remove(at: scoreIndex)
            let targetIndex = ordered.firstIndex(of: .gallery).map { $0 + 1 } ?? ordered.count
            ordered.insert(scoreTab, at: targetIndex)
        }
        return ordered
    }
}
