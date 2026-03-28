//
//  MineRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

/// “我的”页内部导航。
private enum MineRoute: Hashable, Identifiable {
    case followers
    case followings
    case posters

    /// 供导航绑定使用的稳定标识。
    var id: Self { self }
}

/// “我的”页根视图。
///
/// 顶部结构尽量向 Android 对齐，但交互仍然走 iOS 的导航和列表风格。
struct MineRootView: View {
    let fallbackStudentID: String
    let onLogout: () -> Void

    @StateObject private var viewModel = MineViewModel()
    @State private var route: MineRoute?
    @State private var settingsRoute: SettingsRoute?

    /// “我的”主页主体。
    var body: some View {
        List {
            Section {
                profileSection
            }

            Section {
                settingsSection
            }
        }
        .listStyle(.insetGrouped)
        .refreshable {
            await viewModel.refreshProfile()
            await viewModel.refreshPosters()
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $route) { destination in
            switch destination {
            case .followers:
                MineUserListView(
                    title: "我的粉丝",
                    users: viewModel.followerState.items,
                    status: viewModel.followerState.status,
                    isLoadingMore: viewModel.followerState.isLoadingMore,
                    onRefresh: { await viewModel.refreshFollowers() },
                    onLoadMore: { user in await viewModel.loadMoreFollowersIfNeeded(currentUser: user) }
                )
            case .followings:
                MineUserListView(
                    title: "我的关注",
                    users: viewModel.followingState.items,
                    status: viewModel.followingState.status,
                    isLoadingMore: viewModel.followingState.isLoadingMore,
                    onRefresh: { await viewModel.refreshFollowings() },
                    onLoadMore: { user in await viewModel.loadMoreFollowingsIfNeeded(currentUser: user) }
                )
            case .posters:
                MinePosterListView(
                    posters: viewModel.posterState.items,
                    status: viewModel.posterState.status,
                    isLoadingMore: viewModel.posterState.isLoadingMore,
                    onRefresh: { await viewModel.refreshPosters() },
                    onLoadMore: { poster in await viewModel.loadMorePostersIfNeeded(currentPoster: poster) }
                )
            }
        }
        .navigationDestination(item: $settingsRoute) { destination in
            SettingsRootView(initialRoute: destination, studentID: fallbackStudentID, onLogout: onLogout)
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    /// 资料卡区域，根据加载状态展示骨架、错误页或真实内容。
    @ViewBuilder
    private var profileSection: some View {
        switch viewModel.profileStatus {
        case .idle, .loading:
            ProgressView("正在加载个人信息")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 48)
        case let .failed(message):
            ContentUnavailableView {
                Label("加载失败", systemImage: "person.crop.circle.badge.exclamationmark")
            } description: {
                Text(message)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        case .loaded:
            if let info = viewModel.userInfo {
                MineProfileCard(
                    info: info,
                    posterCountText: viewModel.posterCountText,
                    onOpenFollowers: { route = .followers },
                    onOpenFollowings: { route = .followings },
                    onOpenPosters: { route = .posters }
                )
            }
        }
    }

    /// 设置入口列表。
    private var settingsSection: some View {
        ForEach(SettingsRoute.allCases) { route in
            Button {
                settingsRoute = route
            } label: {
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

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 个人信息卡片。
private struct MineProfileCard: View {
    let info: MineUserInfo
    let posterCountText: String
    let onOpenFollowers: () -> Void
    let onOpenFollowings: () -> Void
    let onOpenPosters: () -> Void
    @State private var isShowingUID = false
    @State private var isShowingJoinDate = false

    /// 资料卡主体。
    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: URL(string: info.user.avatar.url)) { phase in
                switch phase {
                case let .success(image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Circle()
                        .fill(Color.blue.opacity(0.14))
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.blue)
                                .font(.title2)
                        }
                }
            }
            .frame(width: 78, height: 78)
            .clipShape(Circle())

            Spacer().frame(height: 8)

            HStack(spacing: 8) {
                Text(info.user.nickname)
                    .font(.title3.weight(.bold))

                if !info.user.identity.text.isEmpty {
                    Text(info.user.identity.text)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(identityColor)
                }
            }

            Spacer().frame(height: 6)

            HStack(spacing: 12) {
                MineSensitiveBadge(
                    title: "UID",
                    systemImage: "number",
                    value: String(info.user.id),
                    isRevealed: $isShowingUID
                )

                if let joinedText = joinedDateText {
                    MineSensitiveBadge(
                        title: nil,
                        systemImage: "calendar",
                        value: joinedText,
                        isRevealed: $isShowingJoinDate
                    )
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Spacer().frame(height: 10)

            Text(info.user.motto.isEmpty ? "空简介" : info.user.motto)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer().frame(height: 10)

            HStack(spacing: 18) {
                MineStatButton(number: "\(info.followerNum)", title: "粉丝", action: onOpenFollowers)
                MineStatButton(number: "\(info.followingNum)", title: "关注", action: onOpenFollowings)
                MineStatButton(number: posterCountText, title: "帖子", action: onOpenPosters)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    private var identityColor: Color {
        MineColorDecoder.color(from: info.user.identity.color) ?? .secondary
    }

    private var joinedDateText: String? {
        MineDateDecoder.joinDateText(from: info.user.createTime)
    }
}

/// “我的”页里用于默认模糊展示敏感信息的胶囊标签。
private struct MineSensitiveBadge: View {
    let title: String?
    let systemImage: String
    let value: String
    @Binding var isRevealed: Bool

    var body: some View {
        Button {
            isRevealed.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                if let title, !title.isEmpty {
                    Text("\(title)：")
                }
                MineSensitiveValueText(value: value, isRevealed: isRevealed)
            }
            .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.plain)
    }
}

/// 敏感内容默认显示为毛玻璃遮罩，点击后再展示真实值。
private struct MineSensitiveValueText: View {
    let value: String
    let isRevealed: Bool

    var body: some View {
        Group {
            if isRevealed {
                Text(value)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            } else {
                Text(value)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .blur(radius: 7)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

/// 粉丝 / 关注 列表页。
private struct MineUserListView: View {
    let title: String
    let users: [GalleryUser]
    let status: MineLoadStatus
    let isLoadingMore: Bool
    let onRefresh: @Sendable () async -> Void
    let onLoadMore: @Sendable (GalleryUser?) async -> Void

    var body: some View {
        Group {
            if isInitialLoading {
                ProgressView("正在加载")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = status, users.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "person.2.slash")
                } description: {
                    Text(message)
                }
            } else {
                List {
                    ForEach(users) { user in
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: user.avatar.lowUrl.isEmpty ? user.avatar.url : user.avatar.lowUrl)) { phase in
                                switch phase {
                                case let .success(image):
                                    image
                                        .resizable()
                                        .scaledToFill()
                                default:
                                    Circle()
                                        .fill(Color.blue.opacity(0.14))
                                        .overlay {
                                            Image(systemName: "person.fill")
                                                .foregroundStyle(.blue)
                                        }
                                }
                            }
                            .frame(width: 46, height: 46)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(user.nickname)
                                        .font(.headline)

                                    if !user.identity.text.isEmpty {
                                        Text(user.identity.text)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(MineColorDecoder.color(from: user.identity.color) ?? .blue)
                                    }
                                }

                                Text("UID：\(user.id)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .task {
                            await onLoadMore(user)
                        }
                    }

                    if isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                }
                .refreshable {
                    await onRefresh()
                }
            }
        }
        .task {
            if case .idle = status {
                await onRefresh()
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isInitialLoading: Bool {
        if case .idle = status { return true }
        if case .loading = status { return users.isEmpty }
        return false
    }
}

/// 我的帖子列表页。
///
/// 直接复用话题卡片与详情实现，避免“我的帖子”和“话题详情”之间出现两套视觉和交互逻辑。
private struct MinePosterListView: View {
    @ObservedObject private var settings = AppSettingsStore.shared
    let posters: [GalleryPoster]
    let status: MineLoadStatus
    let isLoadingMore: Bool
    let onRefresh: @Sendable () async -> Void
    let onLoadMore: @Sendable (GalleryPoster?) async -> Void
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var deletingPoster: GalleryPoster?
    @State private var alert: LoginAlert?
    @State private var deletedPosterIDs: Set<Int> = []
    private let service = GalleryService()

    var body: some View {
        let visiblePosters = CommunityModeration
            .filterVisiblePosters(posters, snapshot: settings.snapshot)
            .filter { !deletedPosterIDs.contains($0.id) }
        Group {
            if isInitialLoading {
                ProgressView("正在加载帖子")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = status, visiblePosters.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "text.bubble")
                } description: {
                    Text(message)
                }
            } else if visiblePosters.isEmpty {
                ContentUnavailableView("暂无可显示的帖子", systemImage: "text.bubble")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                            GalleryPosterCard(
                                poster: poster,
                                onOpenPoster: { selectedPoster = poster },
                                onOpenImage: { index, images in
                                    imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                },
                                onReport: nil,
                                onDelete: { deletingPoster = poster }
                            )
                            .task {
                                await onLoadMore(poster)
                            }

                            if index != visiblePosters.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }

                        if isLoadingMore {
                            ProgressView()
                                .padding(.vertical, 20)
                        }
                    }
                }
                .refreshable {
                    await onRefresh()
                }
            }
        }
        .task {
            if case .idle = status {
                await onRefresh()
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("我的帖子")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                GalleryPosterDetailView(
                    poster: poster,
                    onReport: nil,
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        await onRefresh()
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $imageViewer) { viewer in
            GalleryImageViewer(viewer: viewer)
        }
        .confirmationDialog("删除帖子", isPresented: Binding(
            get: { deletingPoster != nil },
            set: { if !$0 { deletingPoster = nil } }
        ), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let poster = deletingPoster else { return }
                Task {
                    await deletePoster(poster)
                    deletingPoster = nil
                }
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert(item: $alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var isInitialLoading: Bool {
        if case .idle = status { return true }
        if case .loading = status {
            return CommunityModeration.filterVisiblePosters(posters, snapshot: settings.snapshot).isEmpty
        }
        return false
    }

    private func deletePoster(_ poster: GalleryPoster) async {
        do {
            try await service.deletePoster(id: poster.id)
            deletedPosterIDs.insert(poster.id)
            if selectedPoster?.id == poster.id {
                selectedPoster = nil
            }
            await onRefresh()
        } catch {
            alert = LoginAlert(title: "删除失败", message: error.localizedDescription)
        }
    }
}

/// 我的页资料卡上的统计按钮。
private struct MineStatButton: View {
    let number: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(number)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 我的页使用的日期格式化工具。
private enum MineDateDecoder {
    private static let sourceFormatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()
    private static let joinDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func relativeText(from string: String) -> String {
        guard let date = date(from: string) else {
            return "未知时间"
        }
        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func joinDateText(from string: String) -> String? {
        guard let date = date(from: string) else {
            return nil
        }
        return "\(joinDateFormatter.string(from: date)) 加入"
    }

    private static func date(from string: String) -> Date? {
        for formatter in sourceFormatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return iso8601Formatter.date(from: string)
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}

/// 我的页使用的颜色解码工具。
private enum MineColorDecoder {
    static func color(from hex: String) -> Color? {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
            return nil
        }

        return Color(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
