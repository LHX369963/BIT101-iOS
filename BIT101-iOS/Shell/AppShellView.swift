//
//  AppShellView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

/// 应用底部 Tab 的稳定标识。
///
/// 页面设置和启动默认页都依赖这个枚举持久化。
enum AppTab: String, CaseIterable, Identifiable, Codable {
    case schedule
    case map
    case gallery
    case score = "home"
    case mine

    /// 供 `TabView` 和设置持久化使用的稳定标识。
    var id: String { rawValue }

    /// 底部栏上展示的标题。
    var title: String {
        switch self {
        case .schedule:
            return "日程"
        case .map:
            return "地图"
        case .score:
            return "成绩"
        case .gallery:
            return "话题"
        case .mine:
            return "我的"
        }
    }

    /// 底部栏对应的 SF Symbol。
    var systemImage: String {
        switch self {
        case .schedule:
            return "calendar"
        case .map:
            return "map"
        case .score:
            return "chart.bar.doc.horizontal"
        case .gallery:
            return "bubble.left.and.bubble.right"
        case .mine:
            return "person.crop.circle"
        }
    }

    /// 当前 tab 选中时使用的强调色。
    var tintColor: Color {
        switch self {
        case .schedule:
            return .indigo
        case .map:
            return .green
        case .score:
            return .pink
        case .gallery:
            return .orange
        case .mine:
            return .blue
        }
    }
}

/// 登录后真正进入的应用壳层。
///
/// 壳层只关心两件事：按照设置中心决定展示哪些 tab，以及把退出登录回调继续往下传。
struct AppShellView: View {
    let studentID: String
    let onLogout: () -> Void

    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var selectedTab: AppTab = .schedule
    @State private var isShowingGalleryEULA = false
    @State private var isShowingStartupNotice = false
    @State private var requestedScheduleSection: ScheduleSection?

    /// 登录后的应用壳层主体。
    var body: some View {
        TabView(selection: tabSelection) {
            ForEach(settings.visibleTabs) { tab in
                NavigationStack {
                    switch tab {
                    case .schedule:
                        ScheduleRootView(requestedSection: $requestedScheduleSection)
                    case .map:
                        CampusMapScreen()
                    case .score:
                        ScoreRootView()
                    case .gallery:
                        GalleryRootView()
                    case .mine:
                        MineRootView(fallbackStudentID: studentID, onLogout: onLogout)
                    }
                }
                .tag(tab)
                .tabItem {
                    Label(tab.title, systemImage: tab.systemImage)
                }
            }
        }
        .tint(selectedTab.tintColor)
        .sheet(isPresented: $isShowingGalleryEULA) {
            GalleryCommunityRulesSheet(
                contactEmail: CommunitySupport.email,
                onAccept: {
                    settings.acceptCurrentCommunityRules()
                    selectedTab = .gallery
                    isShowingGalleryEULA = false
                },
                onDecline: {
                    isShowingGalleryEULA = false
                }
            )
        }
        .alert("1.1.0版本更新", isPresented: $isShowingStartupNotice) {
            Button("确定") {
                settings.markCurrentStartupNoticeSeen()
            }
        } message: {
            Text("1、bugfix\n2、支持桌面小组件\n3、灵动岛")
        }
        .onAppear {
            let initial = settings.visibleTabs.contains(settings.homeTab) ? settings.homeTab : (settings.visibleTabs.first ?? .schedule)
            if selectedTab != initial {
                selectTab(initial)
            }
            if settings.shouldShowCurrentStartupNotice {
                isShowingStartupNotice = true
            }
        }
        .onChange(of: settings.snapshot) { _, _ in
            if !settings.visibleTabs.contains(selectedTab) {
                selectedTab = settings.visibleTabs.first ?? .schedule
            }
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    /// 统一拦截 tab 切换，把话题 EULA 的弹出逻辑收束到这里。
    private var tabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { newTab in
                selectTab(newTab)
            }
        )
    }

    /// 切换底部 tab，必要时先要求用户同意社区规则。
    private func selectTab(_ tab: AppTab) {
        if tab == .gallery, !settings.hasAcceptedCurrentCommunityRules {
            isShowingGalleryEULA = true
            return
        }
        selectedTab = tab
    }

    /// 处理来自小组件等入口的 app 深链。
    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "bit101" else { return }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        let routeHead = url.host ?? pathComponents.first ?? ""

        if routeHead == "schedule" {
            selectedTab = .schedule
            let routeTail = url.host == nil ? pathComponents.dropFirst().first : pathComponents.first
            if routeTail == "courses" {
                requestedScheduleSection = .courses
            }
        }
    }
}

/// 首次进入话题前展示的社区规则弹层。
private struct GalleryCommunityRulesSheet: View {
    let contactEmail: String
    let onAccept: () -> Void
    let onDecline: () -> Void

    /// 首次进入话题前的社区规则确认页。
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("在继续进入话题前，请确认你已阅读并同意社区规则。")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("1. 禁止发布政治敏感、色情低俗、辱骂骚扰、隐私泄露、谣言和广告刷屏内容。")
                        Text("2. 话题内容会在本地进行敏感词过滤，以通过 Apple 审查；命中的帖子会被直接隐藏，因此显示的帖子数量可能会比网页端少。")
                        Text("3. 你可以在帖子菜单中举报并隐藏帖子，或举报并屏蔽用户。")
                        Text("4. 举报信息会异步提交给开发者进行处理。")
                        Text("5. 如需联系开发者，请使用邮箱：\(contactEmail)")
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text("继续使用话题功能即表示你同意遵守以上规则。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            .navigationTitle("社区规则")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("暂不进入", action: onDecline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("同意并继续", action: onAccept)
                }
            }
        }
    }
}
