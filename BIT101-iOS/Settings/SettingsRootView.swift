//
//  SettingsRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import PhotosUI
import SwiftUI
import WebKit

private let mitLicenseText = """
MIT License

Copyright (c) 2026 BIT101 Contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

/// 设置中心支持的一级菜单。
enum SettingsRoute: String, CaseIterable, Identifiable {
    case account
    case pages
    case theme
    case calendar
    case ddl
    case gallery
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .account: return "账号设置"
        case .pages: return "页面设置"
        case .theme: return "外观设置"
        case .calendar: return "课程表设置"
        case .ddl: return "DDL设置"
        case .gallery: return "话廊设置"
        case .about: return "关于"
        }
    }

    var subtitle: String {
        switch self {
        case .account: return "个人信息编辑及登录状态管理"
        case .pages: return "启动页及页面顺序"
        case .theme: return "主题及暗黑模式"
        case .calendar: return "课程表数据及显示方式"
        case .ddl: return "日程数据及显示方式"
        case .gallery: return "话廊数据及显示方式"
        case .about: return "关于 BIT101"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.crop.circle"
        case .pages: return "square.grid.2x2"
        case .theme: return "paintpalette"
        case .calendar: return "calendar.badge.clock"
        case .ddl: return "list.bullet.clipboard"
        case .gallery: return "bubble.left.and.bubble.right"
        case .about: return "info.circle"
        }
    }
}

/// 全局设置中心入口。
///
/// “我的”页右上角设置、课程表页齿轮、DDL 页齿轮都应当汇入这里。
struct SettingsRootView: View {
    let initialRoute: SettingsRoute?
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        Group {
            if let initialRoute {
                SettingsRoutePage(route: initialRoute, studentID: studentID, onLogout: onLogout)
            } else {
                SettingsIndexPage(studentID: studentID, onLogout: onLogout)
            }
        }
        .navigationTitle(initialRoute?.title ?? "设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 设置首页，负责列出全部一级菜单。
private struct SettingsIndexPage: View {
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(SettingsRoute.allCases) { route in
                    NavigationLink {
                        SettingsRoutePage(route: route, studentID: studentID, onLogout: onLogout)
                    } label: {
                        SettingsIndexCard(route: route)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        .background(Color(.systemGroupedBackground))
    }
}

/// 设置首页卡片样式。
private struct SettingsIndexCard: View {
    let route: SettingsRoute

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: route.systemImage)
                .frame(width: 24, height: 24)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 3) {
                Text(route.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(route.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 根据 route 分发到具体设置页面。
private struct SettingsRoutePage: View {
    let route: SettingsRoute
    let studentID: String
    let onLogout: () -> Void

    var body: some View {
        switch route {
        case .account:
            AccountSettingsPage(studentID: studentID, onLogout: onLogout)
        case .pages:
            PagesSettingsPage()
        case .theme:
            ThemeSettingsPage()
        case .calendar:
            CalendarSettingsPage()
        case .ddl:
            DDLSettingsPage()
        case .gallery:
            GallerySettingsPage()
        case .about:
            AboutSettingsPage(onLogout: onLogout)
        }
    }
}

/// 账号设置页。
///
/// 包含个人资料编辑、头像上传、登录状态检查和退出登录。
private struct AccountSettingsPage: View {
    let studentID: String
    let onLogout: () -> Void

    @State private var profile: MineUserInfo?
    @State private var isCheckingLogin = false
    @State private var isLoggedIn = true
    @State private var isUpdating = false
    @State private var showNicknameEditor = false
    @State private var showMottoEditor = false
    @State private var nicknameText = ""
    @State private var mottoText = ""
    @State private var isShowingStudentID = false
    @State private var isShowingUID = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var alert: LoginAlert?

    private let service = SettingsNetworkService()

    var body: some View {
        List {
            if let profile {
                Section("个人信息") {
                    HStack {
                        Text("头像")
                        Spacer()
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            CachedRemoteImage(url: URL(string: profile.user.avatar.url)) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Circle().fill(Color.blue.opacity(0.15))
                            }
                            .frame(width: 40, height: 40)
                            .clipShape(Circle())
                        }
                        .disabled(isUpdating)
                    }

                    Button {
                        nicknameText = profile.user.nickname
                        showNicknameEditor = true
                    } label: {
                        LabeledContent("昵称", value: profile.user.nickname)
                    }
                    .disabled(isUpdating)

                    Button {
                        mottoText = profile.user.motto
                        showMottoEditor = true
                    } label: {
                        LabeledContent("个性签名", value: profile.user.motto.isEmpty ? "空" : profile.user.motto)
                    }
                    .disabled(isUpdating)

                    SettingsSensitiveValueRow(
                        title: "学号",
                        value: studentID,
                        isRevealed: $isShowingStudentID
                    )

                    SettingsSensitiveValueRow(
                        title: "UID",
                        value: String(profile.user.id),
                        isRevealed: $isShowingUID
                    )
                }
            }

            Section("登录状态") {
                Button {
                    Task { await checkLogin() }
                } label: {
                    HStack {
                        Text("登录状态检查")
                        Spacer()
                        if isCheckingLogin {
                            ProgressView()
                        } else {
                            Text(isLoggedIn ? "已登录" : "未登录")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(isCheckingLogin)

                Button("退出登录", role: .destructive, action: onLogout)
            }
        }
        .task {
            await loadProfile()
        }
        .onChange(of: selectedPhoto) { _, newValue in
            guard let newValue else { return }
            Task { await updateAvatar(with: newValue) }
        }
        .sheet(isPresented: $showNicknameEditor) {
            SettingsTextEditSheet(
                title: "修改昵称",
                text: $nicknameText,
                onSubmit: {
                    Task { await updateProfile(nickname: nicknameText, motto: nil) }
                }
            )
        }
        .sheet(isPresented: $showMottoEditor) {
            SettingsTextEditSheet(
                title: "修改个性签名",
                text: $mottoText,
                axis: .vertical,
                onSubmit: {
                    Task { await updateProfile(nickname: nil, motto: mottoText) }
                }
            )
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    private func loadProfile() async {
        do {
            profile = try await service.fetchMyInfo()
            isLoggedIn = true
        } catch {
            alert = LoginAlert(title: "加载失败", message: error.localizedDescription)
        }
    }

    private func checkLogin() async {
        isCheckingLogin = true
        defer { isCheckingLogin = false }
        do {
            isLoggedIn = try await service.checkLogin()
        } catch {
            alert = LoginAlert(title: "检查失败", message: error.localizedDescription)
        }
    }

    private func updateProfile(nickname: String?, motto: String?) async {
        guard let profile else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            try await service.updateUser(
                nickname: nickname ?? profile.user.nickname,
                motto: motto ?? profile.user.motto,
                avatarMid: profile.user.avatar.mid
            )
            await loadProfile()
            showNicknameEditor = false
            showMottoEditor = false
        } catch {
            alert = LoginAlert(title: "更新失败", message: error.localizedDescription)
        }
    }

    private func updateAvatar(with item: PhotosPickerItem) async {
        guard let profile else { return }
        isUpdating = true
        defer { isUpdating = false }

        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw SettingsServiceError.uploadFailed
            }
            let image = try await service.uploadAvatar(data: data)
            try await service.updateUser(
                nickname: profile.user.nickname,
                motto: profile.user.motto,
                avatarMid: image.mid
            )
            await loadProfile()
        } catch {
            alert = LoginAlert(title: "头像更新失败", message: error.localizedDescription)
        }
    }
}

/// 设置页里用于按需显示学号、UID 这类敏感标识。
private struct SettingsSensitiveValueRow: View {
    let title: String
    let value: String
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            HStack(spacing: 10) {
                Text(title)
                Spacer()
                if isRevealed {
                    Text(value)
                        .foregroundStyle(.secondary)
                } else {
                    Text(value)
                        .foregroundStyle(.secondary)
                        .blur(radius: 7)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 页面设置页。
///
/// 负责底部 tab 的显示顺序、默认页和可见性配置。
private struct PagesSettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var pageOrder = AppTab.allCases
    @State private var homeTab: AppTab = .schedule
    @State private var hiddenTabs: Set<AppTab> = []
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                Text("按住右侧拖动可以调整顺序；勾选默认项表示启动时默认页面；隐藏会从底部导航栏移除，“我的”页面不能隐藏。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(pageOrder) { tab in
                    HStack {
                        Text(tab.title)
                        Spacer()
                        Toggle("显示", isOn: Binding(
                            get: { !hiddenTabs.contains(tab) || tab == .mine },
                            set: { visible in
                                if tab != .mine {
                                    if visible { hiddenTabs.remove(tab) } else { hiddenTabs.insert(tab) }
                                    if hiddenTabs.contains(homeTab) {
                                        homeTab = pageOrder.first(where: { !hiddenTabs.contains($0) || $0 == .mine }) ?? .schedule
                                    }
                                    persist()
                                }
                            }
                        ))
                        .labelsHidden()
                        Button {
                            homeTab = tab
                            persist()
                        } label: {
                            Image(systemName: homeTab == tab ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(homeTab == tab ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .onMove { from, to in
                    pageOrder.move(fromOffsets: from, toOffset: to)
                    persist()
                }
            } header: {
                Text("页面编辑")
            }
        }
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "完成" : "编辑") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        editMode = editMode.isEditing ? .inactive : .active
                    }
                }
            }
        }
        .task { syncFromStore() }
    }

    private func syncFromStore() {
        pageOrder = settings.pageOrder
        homeTab = settings.homeTab
        hiddenTabs = Set(settings.hiddenTabs)
    }

    private func persist() {
        settings.setPageOrder(pageOrder)
        settings.setHiddenTabs(Array(hiddenTabs))
        settings.setHomeTab(homeTab)
    }
}

/// 外观设置页。
private struct ThemeSettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared

    var body: some View {
        Form {
            Section {
                Picker("外观模式", selection: Binding(
                    get: { settings.themeMode },
                    set: settings.setThemeMode
                )) {
                    ForEach(AppThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }

                Toggle("自动旋转", isOn: Binding(
                    get: { settings.autoRotate },
                    set: settings.setAutoRotate
                ))
            }
        }
    }
}

/// 课程表设置页。
private struct CalendarSettingsPage: View {
    @StateObject private var viewModel = ScheduleViewModel()
    @State private var isShowingTimeTableEditor = false
    @State private var timeTableText = ""
    @State private var isShowingCustomSchedules = false
    @State private var isShowingLiveActivityLeadMinutesPicker = false

    private var normalizedLeadMinutes: Int {
        min(max(viewModel.cache.courseLiveActivityLeadMinutes, 1), 99)
    }

    var body: some View {
        List {
            Section("数据设置") {
                LabeledContent("当前学期", value: viewModel.cache.currentTerm.isEmpty ? "未设置" : viewModel.cache.currentTerm)
                LabeledContent("学期起始日期", value: viewModel.firstDayDescription)

                Button {
                    Task { await viewModel.syncCourses() }
                } label: {
                    HStack {
                        Text("重新同步课表与考试")
                        Spacer()
                        if viewModel.isSyncingCourses {
                            ProgressView()
                        }
                    }
                }
                .disabled(viewModel.isSyncingCourses)

                Button("时间表") {
                    timeTableText = viewModel.cache.timeTable.map { "\($0.start), \($0.end)" }.joined(separator: "\n")
                    isShowingTimeTableEditor = true
                }

                Button("自定义日程") {
                    isShowingCustomSchedules = true
                }
            }

            Section {
                Toggle("显示周六", isOn: Binding(get: { viewModel.cache.showSaturday }, set: viewModel.setShowSaturday))
                Toggle("显示周日", isOn: Binding(get: { viewModel.cache.showSunday }, set: viewModel.setShowSunday))
                Toggle("显示课程卡片边框", isOn: Binding(get: { viewModel.cache.showBorder }, set: viewModel.setShowBorder))
                Toggle("高亮今日", isOn: Binding(get: { viewModel.cache.showHighlightToday }, set: viewModel.setShowHighlightToday))
                Toggle("显示节次分割线", isOn: Binding(get: { viewModel.cache.showDivider }, set: viewModel.setShowDivider))
                Toggle("显示当前时间线", isOn: Binding(get: { viewModel.cache.showCurrentTime }, set: viewModel.setShowCurrentTime))
                Toggle("显示考试安排", isOn: Binding(get: { viewModel.cache.showExamInfo }, set: viewModel.setShowExamInfo))
                Toggle("显示灵动岛提醒", isOn: Binding(
                    get: { viewModel.cache.showCourseLiveActivityReminder },
                    set: viewModel.setShowCourseLiveActivityReminder
                ))
                Button {
                    isShowingLiveActivityLeadMinutesPicker = true
                } label: {
                    HStack {
                        Text("提前显示阈值")
                        Spacer()
                        Text("\(normalizedLeadMinutes) 分钟")
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!viewModel.cache.showCourseLiveActivityReminder)
            } header: {
                Text("显示设置")
            }
        }
        .task {
            await viewModel.loadIfNeeded()
            if viewModel.cache.courseLiveActivityLeadMinutes != normalizedLeadMinutes {
                viewModel.setCourseLiveActivityLeadMinutes(normalizedLeadMinutes)
            }
        }
        .sheet(isPresented: $isShowingTimeTableEditor) {
            TimeTableEditorSheet(
                text: $timeTableText,
                onSubmit: {
                    do {
                        try viewModel.setTimeTable(from: timeTableText)
                        isShowingTimeTableEditor = false
                    } catch {
                        viewModel.notice = ScheduleNotice(title: "设置失败", message: error.localizedDescription)
                    }
                }
            )
        }
        .sheet(isPresented: $isShowingCustomSchedules) {
            CustomScheduleListSheet(viewModel: viewModel)
        }
        .sheet(isPresented: $isShowingLiveActivityLeadMinutesPicker) {
            NavigationStack {
                CourseLiveActivityLeadMinutesPickerPage(
                    value: Binding(
                        get: { normalizedLeadMinutes },
                        set: viewModel.setCourseLiveActivityLeadMinutes
                    )
                )
            }
        }
        .alert(item: $viewModel.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }
}

/// 课程提醒提前显示阈值的滚轮选择页。
private struct CourseLiveActivityLeadMinutesPickerPage: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var value: Int

    /// 使用原生 wheel picker 提供 1...99 分钟的阈值选择。
    var body: some View {
        Picker("提前显示阈值", selection: $value) {
            ForEach(1 ... 99, id: \.self) { minute in
                Text("\(minute) 分钟")
                    .tag(minute)
            }
        }
        .pickerStyle(.wheel)
        .labelsHidden()
        .navigationTitle("提前显示阈值")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    dismiss()
                }
            }
        }
        .presentationDetents([.height(260)])
    }
}

/// DDL 设置页。
private struct DDLSettingsPage: View {
    @StateObject private var viewModel = ScheduleViewModel()

    var body: some View {
        Form {
            Section("数据设置") {
                Button("重新获取订阅链接") {
                    Task { await viewModel.refreshLexueCalendarURL() }
                }
                .disabled(viewModel.isSyncingDDL)

                Button("重新拉取乐学日程") {
                    Task { await viewModel.syncDDL() }
                }
                .disabled(viewModel.isSyncingDDL)
            }

            Section("显示设置") {
                Stepper("变色天数 \(viewModel.beforeDay)", value: Binding(get: { viewModel.beforeDay }, set: viewModel.setDDLBeforeDay), in: 0 ... 30)
                Stepper("滞留天数 \(viewModel.afterDay)", value: Binding(get: { viewModel.afterDay }, set: viewModel.setDDLAfterDay), in: 0 ... 30)
            }
        }
        .task { await viewModel.loadIfNeeded() }
    }
}

/// 画廊设置页。
///
/// 集中管理本地黑名单、隐藏帖子、社区规则状态以及相关联系信息。
private struct GallerySettingsPage: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var hiddenUsers: [MineUserInfo] = []
    @State private var isLoadingUsers = false
    @State private var alert: LoginAlert?

    private let service = SettingsNetworkService()

    var body: some View {
        List {
            Section {
                NavigationLink {
                    HiddenUsersPage(hiddenUsers: hiddenUsers, isLoading: isLoadingUsers) { index in
                        settings.removeHiddenUser(at: index + (settings.galleryHiddenUserIDs.first == -1 ? 1 : 0))
                        Task { await loadHiddenUsers() }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("隐藏用户")
                        Text("当前列表中\(settings.galleryHiddenUserIDs.filter { $0 != -1 }.count == 0 ? "没有用户" : "有 \(settings.galleryHiddenUserIDs.filter { $0 != -1 }.count) 名用户")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                NavigationLink {
                    HiddenPostersPage(hiddenPosters: settings.galleryHiddenPosters) { index in
                        settings.removeHiddenPoster(at: index)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("隐藏帖子")
                        Text("当前列表中\(settings.galleryHiddenPosters.isEmpty ? "没有帖子" : "有 \(settings.galleryHiddenPosters.count) 条帖子")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("隐藏匿名用户", isOn: Binding(
                    get: { settings.galleryHiddenUserIDs.first == -1 },
                    set: { _ in settings.toggleHideAnonymous() }
                ))

                Toggle("严格屏蔽模式", isOn: Binding(
                    get: { settings.galleryHideStrictMode },
                    set: { settings.updateGallerySettings(hideStrictMode: $0) }
                ))
            } header: {
                Text("屏蔽设置")
            } footer: {
                Text("开启后，如果一条评论是在回复已屏蔽用户，也会一并隐藏。")
            }

            Section("机器人") {
                Toggle("在搜索结果中隐藏机器人帖子", isOn: Binding(
                    get: { settings.galleryHideBotPosterInSearch },
                    set: { settings.updateGallerySettings(hideBotPosterInSearch: $0) }
                ))
            }

            Section("社区治理") {
                Text(settings.hasAcceptedCurrentCommunityRules ? "当前设备已同意最新社区规则。" : "当前设备尚未同意社区规则，首次进入话廊时会弹出提示。")
                    .foregroundStyle(.secondary)
                Text("联系邮箱：\(CommunitySupport.email)")
                    .textSelection(.enabled)

                if settings.hasAcceptedCurrentCommunityRules {
                    Button("撤销同意社区规则", role: .destructive) {
                        settings.revokeCommunityRulesAcceptance()
                    }
                }
            }
        }
        .task { await loadHiddenUsers() }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
    }

    private func loadHiddenUsers() async {
        isLoadingUsers = true
        defer { isLoadingUsers = false }
        do {
            hiddenUsers = try await withThrowingTaskGroup(of: MineUserInfo.self) { group in
                for uid in settings.galleryHiddenUserIDs where uid != -1 {
                    group.addTask { try await service.fetchUserInfo(id: uid) }
                }
                var result: [MineUserInfo] = []
                for try await item in group {
                    result.append(item)
                }
                return result.sorted { $0.user.id < $1.user.id }
            }
        } catch {
            alert = LoginAlert(title: "加载失败", message: error.localizedDescription)
        }
    }
}

/// 关于页。
private struct AboutSettingsPage: View {
    let onLogout: () -> Void

    @State private var alert: LoginAlert?
    @State private var isResettingLocalData = false
    @State private var isShowingResetConfirmation = false

    var body: some View {
        List {
            Section("版本信息") {
                LabeledContent("当前版本", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知")
            }

            Section("联系我们") {
                Link("项目仓库", destination: URL(string: "https://github.com/LHX369963/BIT101-iOS")!)
                Link("QQ交流群", destination: URL(string: "https://jq.qq.com/?_wv=1027&k=OTttwrzb")!)
                Link("邮箱", destination: URL(string: "mailto:systemd@linux.do")!)
            }

            Section("关于本 APP") {
                NavigationLink("开源声明") {
                    ScrollView {
                        Text(mitLicenseText)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                    .navigationTitle("开源声明")
                }

                NavigationLink("关于 BIT101") {
                    ScrollView {
                        Text("BIT101 当前已接入设置页、课表、DDL、空教室、地图、话廊、成绩、我的等基础能力，后续会继续完善体验与细节。")
                            .padding()
                    }
                    .navigationTitle("关于 BIT101")
                }
            }

            Section("调试") {
                Button(role: .destructive) {
                    isShowingResetConfirmation = true
                } label: {
                    HStack {
                        Text("删除所有文稿与数据")
                        Spacer()
                        if isResettingLocalData {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isResettingLocalData)

                Text("会清除本地登录信息、设置、课表/DDL缓存、Cookie 和网页数据，并退回登录页。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .alert(item: $alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
        }
        .alert("删除所有文稿与数据", isPresented: $isShowingResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await resetAllLocalData() }
            }
        } message: {
            Text("此操作不可撤销。应用将清空本地数据并返回登录页。")
        }
    }

    @MainActor
    private func resetAllLocalData() async {
        guard !isResettingLocalData else { return }
        isResettingLocalData = true
        defer { isResettingLocalData = false }

        LoginStorage.shared.clearAllLocalData()
        ScheduleCacheStore.clear()
        clearUserDefaults()
        clearFileSystemCaches()
        URLCache.shared.removeAllCachedResponses()
        await clearWebData()
        AppSettingsStore.shared.resetToDefaults()
        onLogout()
    }

    private func clearUserDefaults() {
        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
            UserDefaults.standard.synchronize()
        }
    }

    private func clearFileSystemCaches() {
        let manager = FileManager.default
        let directories: [FileManager.SearchPathDirectory] = [
            .documentDirectory,
            .applicationSupportDirectory,
            .cachesDirectory,
        ]

        for directory in directories {
            guard let url = manager.urls(for: directory, in: .userDomainMask).first else { continue }
            deleteContents(of: url, using: manager)
        }

        deleteContents(of: manager.temporaryDirectory, using: manager)
    }

    private func deleteContents(of directory: URL, using manager: FileManager) {
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for url in urls {
            try? manager.removeItem(at: url)
        }
    }

    private func clearWebData() async {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            WKWebsiteDataStore.default().removeData(
                ofTypes: dataTypes,
                modifiedSince: .distantPast
            ) {
                continuation.resume()
            }
        }
    }
}

/// 文本编辑弹层。
private struct SettingsTextEditSheet: View {
    let title: String
    @Binding var text: String
    var axis: Axis = .horizontal
    let onSubmit: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(title, text: $text, axis: axis)
                    .lineLimit(axis == .vertical ? 4 : 1, reservesSpace: axis == .vertical)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("确定") {
                        onSubmit()
                    }
                }
            }
        }
    }
}

/// 隐藏用户列表页。
private struct HiddenUsersPage: View {
    let hiddenUsers: [MineUserInfo]
    let isLoading: Bool
    let onReshow: (Int) -> Void

    var body: some View {
        List {
            if isLoading {
                ProgressView("正在加载")
            } else if hiddenUsers.isEmpty {
                ContentUnavailableView("隐藏用户列表为空", systemImage: "person.crop.circle.badge.minus")
            } else {
                ForEach(Array(hiddenUsers.enumerated()), id: \.element.user.id) { index, info in
                    HStack(spacing: 12) {
                        CachedRemoteImage(url: URL(string: info.user.avatar.lowUrl.isEmpty ? info.user.avatar.url : info.user.avatar.lowUrl)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Circle().fill(Color.blue.opacity(0.15))
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(Circle())

                        VStack(alignment: .leading, spacing: 4) {
                            Text(info.user.nickname)
                            Text(info.user.motto)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button("显示") { onReshow(index) }
                    }
                }
            }
        }
        .navigationTitle("隐藏用户列表")
    }
}

/// 隐藏帖子列表页。
private struct HiddenPostersPage: View {
    let hiddenPosters: [HiddenPosterRecord]
    let onReshow: (Int) -> Void

    var body: some View {
        List {
            if hiddenPosters.isEmpty {
                ContentUnavailableView("隐藏帖子列表为空", systemImage: "eye.slash")
            } else {
                ForEach(Array(hiddenPosters.enumerated()), id: \.element.id) { index, poster in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(poster.title.isEmpty ? "未命名帖子" : poster.title)
                            .font(.headline)
                        Text("作者：\(poster.userNickname)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("恢复显示") {
                            onReshow(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .navigationTitle("隐藏帖子列表")
    }
}
