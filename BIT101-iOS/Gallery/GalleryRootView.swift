//
//  GalleryRootView.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI
import UIKit

// MARK: - Gallery Root

/// 话廊页根视图。
///
/// 顶部负责 feed 切换，下方负责承载当前选中的帖子流，并支持左右轻扫切换分区。
struct GalleryRootView: View {
    @StateObject private var viewModel = GalleryViewModel()
    @StateObject private var messageViewModel = GalleryMessageViewModel()
    @ObservedObject private var settings = AppSettingsStore.shared
    @State private var isShowingComposer = false
    @State private var isShowingMessages = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color(.systemGroupedBackground)
                .ignoresSafeArea(edges: .bottom)

            GalleryFeedView(
                feedState: filteredState(for: viewModel.selectedFeed),
                feedIdentity: viewModel.selectedFeed.rawValue,
                prefetchTriggerThreshold: viewModel.selectedFeed == .recommend ? 10 : 0,
                onRefresh: {
                    await viewModel.refresh(feed: viewModel.selectedFeed)
                },
                onPrefetch: { poster in
                    await viewModel.prefetchIfNeeded(for: viewModel.selectedFeed, currentPoster: poster)
                },
                onLoadMore: { poster in
                    await viewModel.loadMoreIfNeeded(for: viewModel.selectedFeed, currentPoster: poster)
                }
            )
            .simultaneousGesture(feedSwitchGesture)

            VStack(spacing: 10) {
                GalleryFloatingActionButton(systemImage: "square.and.pencil") {
                    isShowingComposer = true
                }

                GalleryFloatingActionButton(systemImage: "magnifyingglass") {
                    viewModel.isShowingSearch = true
                }

                GalleryFloatingActionButton(
                    systemImage: "bell.badge",
                    badgeText: messageBadgeText
                ) {
                    isShowingMessages = true
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .safeAreaInset(edge: .top) {
            Picker("话廊分区", selection: $viewModel.selectedFeed) {
                ForEach(GalleryFeedKind.allCases) { feed in
                    Text(feed.title).tag(feed)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            async let feedTask: Void = viewModel.bootstrapIfNeeded()
            async let messageTask: Void = messageViewModel.refreshUnreadCounts()
            _ = await (feedTask, messageTask)
        }
        .onChange(of: viewModel.selectedFeed) { _, newFeed in
            if viewModel.state(for: newFeed).status == .idle {
                Task {
                    await viewModel.refresh(feed: newFeed)
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingSearch) {
            NavigationStack {
                GallerySearchView(viewModel: viewModel)
            }
        }
        .sheet(isPresented: $isShowingMessages) {
            NavigationStack {
                GalleryMessagesView(viewModel: messageViewModel)
            }
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $isShowingComposer) {
            GalleryComposerView {
                await MainActor.run {
                    viewModel.selectedFeed = .newest
                }
                await viewModel.refresh(feed: .newest)
            }
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private func filteredState(for feed: GalleryFeedKind) -> GalleryFeedState {
        var state = viewModel.state(for: feed)
        state.posters = filterPosters(state.posters)
        return state
    }

    private var messageBadgeText: String? {
        let count = messageViewModel.totalUnreadCount
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    private var feedSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                guard abs(horizontal) > abs(vertical), abs(horizontal) >= 56 else { return }

                if horizontal < 0 {
                    switchFeed(step: 1)
                } else {
                    switchFeed(step: -1)
                }
            }
    }

    private func switchFeed(step: Int) {
        let allFeeds = GalleryFeedKind.allCases
        guard let currentIndex = allFeeds.firstIndex(of: viewModel.selectedFeed) else { return }

        let nextIndex = currentIndex + step
        guard allFeeds.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.selectedFeed = allFeeds[nextIndex]
        }
    }

    /// 过滤逻辑与 Android 一致：支持隐藏匿名用户，以及按 UID 黑名单过滤。
    private func filterPosters(_ posters: [GalleryPoster]) -> [GalleryPoster] {
        CommunityModeration.filterVisiblePosters(posters, snapshot: settings.snapshot)
    }
}

private struct GalleryFloatingActionButton: View {
    let systemImage: String
    let badgeText: String?
    let action: () -> Void

    init(systemImage: String, badgeText: String? = nil, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.badgeText = badgeText
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background(.ultraThinMaterial, in: Circle())

                if let badgeText {
                    Text(badgeText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, badgeText.count > 2 ? 5 : 4)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Color.red, in: Capsule())
                        .offset(x: 5, y: -5)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// 单个 feed 的列表页。
private struct GalleryFeedView: View {
    let feedState: GalleryFeedState
    let feedIdentity: String
    let prefetchTriggerThreshold: Int
    let onRefresh: @Sendable () async -> Void
    let onPrefetch: @Sendable (GalleryPoster?) async -> Void
    let onLoadMore: @Sendable (GalleryPoster?) async -> Void
    @ObservedObject private var settings = AppSettingsStore.shared
    private let reportService = CommunityReportService()
    @State private var selectedPoster: GalleryPoster?
    @State private var imageViewer: GalleryImageViewerState?
    @State private var reportContext: GalleryReportContext?
    @State private var deletedPosterIDs: Set<Int> = []

    var body: some View {
        Group {
            if isInitialLoading {
                    ProgressView("正在加载话廊")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if case let .failed(message) = feedState.status, feedState.posters.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                }
            } else {
                List {
                    ForEach(Array(visiblePosters.enumerated()), id: \.element.id) { index, poster in
                        VStack(spacing: 0) {
                            GalleryPosterCard(
                                poster: poster,
                                onOpenPoster: { selectedPoster = poster },
                                onOpenImage: { index, images in
                                    imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                                },
                                onReport: { action in
                                    reportContext = GalleryReportContext(poster: poster, action: action)
                                },
                                onDelete: nil
                            )

                            if index != visiblePosters.count - 1 {
                                Divider()
                                    .padding(.leading, 14)
                            }
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .onAppear {
                            if prefetchTriggerPosterIDs.contains(poster.id) {
                                Task {
                                    await onPrefetch(poster)
                                }
                            }
                            guard poster.id == visiblePosters.last?.id else { return }
                            Task {
                                await onLoadMore(poster)
                            }
                        }
                    }

                    if feedState.isLoadingMore {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color(.systemGroupedBackground))
                .id(feedIdentity)
                .refreshable {
                    await onRefresh()
                }
            }
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                GalleryPosterDetailView(
                    poster: poster,
                    onReport: { _ in },
                    onDeleted: {
                        deletedPosterIDs.insert(poster.id)
                        await onRefresh()
                    }
                )
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .fullScreenCover(item: $imageViewer) { viewer in
            GalleryImageViewer(viewer: viewer)
        }
        .sheet(item: $reportContext) { context in
            CommunityReportSheet(context: context) { type, note in
                applyReport(context, type: type, note: note)
            }
        }
    }

    private var isInitialLoading: Bool {
        switch feedState.status {
        case .idle, .loading:
            return visiblePosters.isEmpty
        default:
            return false
        }
    }

    private var visiblePosters: [GalleryPoster] {
        feedState.posters.filter { !deletedPosterIDs.contains($0.id) }
    }

    private var prefetchTriggerPosterIDs: Set<Int> {
        guard prefetchTriggerThreshold > 0 else { return [] }
        return Set(visiblePosters.suffix(prefetchTriggerThreshold).map(\.id))
    }

    private func applyReport(_ context: GalleryReportContext, type: CommunityReportType, note: String) {
        switch context.action {
        case .hidePoster:
            settings.hidePoster(
                id: context.poster.id,
                title: context.poster.title,
                userID: context.poster.user.id,
                userNickname: context.poster.user.nickname,
                createdTime: context.poster.createTime
            )
        case .blockUser:
            if context.poster.anonymous || context.poster.user.id == -1 {
                if settings.galleryHiddenUserIDs.first != -1 {
                    settings.toggleHideAnonymous()
                }
            } else {
                var hiddenUserIDs = settings.galleryHiddenUserIDs
                if !hiddenUserIDs.contains(context.poster.user.id) {
                    hiddenUserIDs.append(context.poster.user.id)
                    settings.updateGallerySettings(hiddenUserIDs: hiddenUserIDs)
                }
            }
        }

        reportService.submitReport(for: context.poster, type: type, note: note, action: context.action)
    }
}

/// 单个帖子卡片。
///
/// 帖子点击进入详情，图片点击进入全屏看图，二者需要显式拆开避免手势冲突。
struct GalleryPosterCard: View {
    let poster: GalleryPoster
    let onOpenPoster: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onReport: ((CommunityReportAction) -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(poster.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 10) {
                GalleryAvatarView(imageURL: URL(string: poster.user.avatar.lowUrl.isEmpty ? poster.user.avatar.url : poster.user.avatar.lowUrl))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(poster.user.nickname)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !poster.user.identity.text.isEmpty {
                            Text(poster.user.identity.text)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(identityColor.opacity(0.15), in: Capsule())
                                .foregroundStyle(identityColor)
                        }
                    }

                    if !poster.user.motto.isEmpty {
                        Text(poster.user.motto)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if onReport != nil || onDelete != nil {
                    GalleryPosterActionMenu(
                        onSelectAction: onReport,
                        onDelete: onDelete
                    )
                }
            }

            Text(poster.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .lineLimit(poster.images.count <= 2 ? 4 : 3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !poster.images.isEmpty {
                GalleryPosterImagesView(images: poster.images, onOpenImage: onOpenImage)
            }

            HStack(spacing: 10) {
                Label("\(poster.likeNum)", systemImage: "hand.thumbsup")
                Label("\(poster.commentNum)", systemImage: "bubble.right")

                if !poster.public {
                    Label("仅自己可见", systemImage: "eye.slash")
                }

                Spacer()

                Text(relativeTimeText(poster.editTime))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !poster.tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(poster.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenPoster)
    }

    private var identityColor: Color {
        Color(hex: poster.user.identity.color) ?? .orange
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知")
    }
}

/// 帖子作者头像。
private struct GalleryAvatarView: View {
    let imageURL: URL?

    var body: some View {
        CachedRemoteImage(url: imageURL) { image in
            image
                .resizable()
                .scaledToFill()
        } placeholder: {
            ZStack {
                Circle().fill(Color.orange.opacity(0.15))
                Image(systemName: "person.fill")
                    .foregroundStyle(.orange)
                    .font(.caption.weight(.bold))
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
    }
}

/// 帖子图片网格。
private struct GalleryPosterImagesView: View {
    let images: [GalleryImage]
    let onOpenImage: (Int, [GalleryImage]) -> Void

    var body: some View {
        let displayedImages = images.count <= 2 ? images : Array(images.prefix(images.count == 3 ? 3 : 4))

        if displayedImages.count == 1 {
            thumbnailButton(image: displayedImages[0], index: 0, width: 180, maxHeight: 220, aspectRatio: 1)
        } else if displayedImages.count == 2 {
            HStack(spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 150, aspectRatio: 1)
                }
            }
        } else {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(displayedImages.count, 4)), spacing: 8) {
                ForEach(Array(displayedImages.enumerated()), id: \.element.id) { index, image in
                    thumbnailButton(image: image, index: index, width: nil, maxHeight: 78, aspectRatio: 1)
                }
            }
        }
    }

    private func thumbnailButton(image: GalleryImage, index: Int, width: CGFloat?, maxHeight: CGFloat?, aspectRatio: CGFloat) -> some View {
        Button {
            onOpenImage(index, images)
        } label: {
            GalleryPosterThumbnail(
                image: image,
                width: width,
                maxHeight: maxHeight,
                aspectRatio: aspectRatio
            )
        }
        .buttonStyle(.plain)
    }
}

/// 单张帖子图片缩略图。
private struct GalleryPosterThumbnail: View {
    let image: GalleryImage
    let width: CGFloat?
    let maxHeight: CGFloat?
    let aspectRatio: CGFloat

    var body: some View {
        AsyncImage(url: URL(string: image.lowUrl.isEmpty ? image.url : image.lowUrl)) { phase in
            switch phase {
            case let .success(renderedImage):
                renderedImage
                    .resizable()
                    .scaledToFit()
            default:
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.orange)
                    }
            }
        }
        .frame(maxWidth: width == nil ? .infinity : width)
        .aspectRatio(aspectRatio, contentMode: .fit)
        .frame(width: width)
        .frame(maxHeight: maxHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// 帖子详情页。
struct GalleryPosterDetailView: View {
    private struct UserRoute: Identifiable, Hashable {
        let userID: Int
        var id: Int { userID }
    }

    @ObservedObject private var settings = AppSettingsStore.shared
    private let reportService = CommunityReportService()
    @StateObject private var viewModel: GalleryPosterDetailViewModel
    @State private var imageViewer: GalleryImageViewerState?
    @State private var reportContext: GalleryReportContext?
    @State private var composerTarget: GalleryCommentComposerTarget?
    @State private var userRoute: UserRoute?
    @State private var isShowingDeleteConfirmation = false
    let onReport: ((CommunityReportAction) -> Void)?
    let onDeleted: (@Sendable () async -> Void)?

    init(
        poster: GalleryPoster,
        onReport: ((CommunityReportAction) -> Void)? = nil,
        onDeleted: (@Sendable () async -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: GalleryPosterDetailViewModel(initialPoster: poster))
        self.onReport = onReport
        self.onDeleted = onDeleted
    }

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(viewModel.poster.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 12) {
                        Group {
                            if canOpenPosterUserProfile {
                                Button {
                                    userRoute = UserRoute(userID: viewModel.poster.user.id)
                                } label: {
                                    authorSummary
                                }
                                .buttonStyle(.plain)
                            } else {
                                authorSummary
                            }
                        }

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                composerTarget = .poster(posterID: viewModel.poster.id)
                            } label: {
                                Image(systemName: "bubble.right")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                    .frame(width: 34, height: 34)
                                    .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)

                            Button {
                                Task {
                                    await viewModel.likePoster()
                                }
                            } label: {
                                Group {
                                    if viewModel.isLikingPoster {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Image(systemName: viewModel.poster.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                                            .font(.headline)
                                    }
                                }
                                .foregroundStyle(viewModel.poster.like ? Color.orange : Color.primary)
                                .frame(width: 34, height: 34)
                                .background(Color.orange.opacity(0.12), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLikingPoster)
                        }
                    }
                }

                if viewModel.poster.claim.id != 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal")
                        Text(viewModel.poster.claim.text)
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.orange)
                }

                Text(viewModel.poster.text)
                    .font(.body)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !viewModel.poster.images.isEmpty {
                    VStack(spacing: 10) {
                        ForEach(Array(viewModel.poster.images.enumerated()), id: \.element.id) { index, image in
                            Button {
                                imageViewer = GalleryImageViewerState(images: viewModel.poster.images, initialIndex: index)
                            } label: {
                                GalleryPosterThumbnail(
                                    image: image,
                                    width: nil,
                                    maxHeight: 320,
                                    aspectRatio: 1.6
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !viewModel.poster.tags.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(viewModel.poster.tags, id: \.self) { tag in
                            Text(tag)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                }

                HStack(spacing: 18) {
                    Text("\(viewModel.poster.likeNum)赞")
                    Text("\(viewModel.poster.commentNum)评论")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)

                Divider()

                GalleryPosterCommentsSection(
                    comments: filteredComments,
                    totalCommentCount: viewModel.poster.commentNum,
                    status: viewModel.commentState.status,
                    isLoadingMore: viewModel.commentState.isLoadingMore,
                    selectedOrder: viewModel.commentOrder,
                    likingCommentIDs: viewModel.likingCommentIDs,
                    onSelectOrder: { order in
                        Task {
                            await viewModel.setCommentOrder(order)
                        }
                    },
                    onReply: { target in
                        composerTarget = .comment(mainComment: target.mainComment, targetComment: target.targetComment)
                    },
                    onLikeComment: { comment in
                        Task {
                            await viewModel.likeComment(comment)
                        }
                    },
                    onOpenImage: { index, images in
                        imageViewer = GalleryImageViewerState(images: images, initialIndex: index)
                    },
                    onOpenUser: { user in
                        guard user.id > 0 else { return }
                        userRoute = UserRoute(userID: user.id)
                    },
                    onLoadMore: { comment in
                        await viewModel.loadMoreCommentsIfNeeded(currentComment: comment)
                    }
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
        }
        .refreshable {
            await viewModel.refreshAll()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("帖子详情")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $userRoute) { route in
            UserProfileRootView(userID: route.userID)
        }
        .toolbar {
            if onReport != nil || viewModel.poster.own {
                ToolbarItem(placement: .topBarTrailing) {
                    GalleryPosterActionMenu(
                        onSelectAction: onReport == nil ? nil : { action in
                            reportContext = GalleryReportContext(poster: viewModel.poster.asPoster, action: action)
                        },
                        onDelete: viewModel.poster.own ? {
                            isShowingDeleteConfirmation = true
                        } : nil
                    )
                }
            }
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .fullScreenCover(item: $imageViewer) { viewer in
            GalleryImageViewer(viewer: viewer)
        }
        .sheet(item: $reportContext) { context in
            CommunityReportSheet(context: context) { type, note in
                applyReport(context, type: type, note: note)
            }
        }
        .sheet(item: $composerTarget) { target in
            GalleryCommentComposerSheet(
                target: target,
                isSubmitting: viewModel.isSubmittingComment
            ) { text, anonymous in
                await viewModel.submitComment(text: text, anonymous: anonymous, target: target)
            }
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .confirmationDialog("删除帖子", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task {
                    if await viewModel.deletePoster() {
                        await onDeleted?()
                        dismiss()
                    }
                }
            }
        } message: {
            Text("删除后无法恢复。")
        }
    }

    private var authorSummary: some View {
        HStack(spacing: 12) {
            GalleryAvatarView(imageURL: URL(string: viewModel.poster.user.avatar.lowUrl.isEmpty ? viewModel.poster.user.avatar.url : viewModel.poster.user.avatar.lowUrl))

            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.poster.user.nickname)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(relativeTimeText(viewModel.poster.editTime))
                    if !viewModel.poster.public {
                        Label("仅自己可见", systemImage: "eye.slash")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var canOpenPosterUserProfile: Bool {
        !viewModel.poster.anonymous && viewModel.poster.user.id > 0
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
    }

    private var filteredComments: [GalleryComment] {
        CommunityModeration.filterVisibleComments(viewModel.commentState.items, snapshot: settings.snapshot)
    }

    private func applyReport(_ context: GalleryReportContext, type: CommunityReportType, note: String) {
        switch context.action {
        case .hidePoster:
            settings.hidePoster(
                id: context.poster.id,
                title: context.poster.title,
                userID: context.poster.user.id,
                userNickname: context.poster.user.nickname,
                createdTime: context.poster.createTime
            )
        case .blockUser:
            if context.poster.anonymous || context.poster.user.id == -1 {
                if settings.galleryHiddenUserIDs.first != -1 {
                    settings.toggleHideAnonymous()
                }
            } else {
                var hiddenUserIDs = settings.galleryHiddenUserIDs
                if !hiddenUserIDs.contains(context.poster.user.id) {
                    hiddenUserIDs.append(context.poster.user.id)
                    settings.updateGallerySettings(hiddenUserIDs: hiddenUserIDs)
                }
            }
        }

        reportService.submitReport(for: context.poster, type: type, note: note, action: context.action)
    }
}

/// 评论区主体。
private struct GalleryPosterCommentsSection: View {
    let comments: [GalleryComment]
    let totalCommentCount: Int
    let status: GalleryFeedStatus
    let isLoadingMore: Bool
    let selectedOrder: GalleryCommentOrder
    let likingCommentIDs: Set<Int>
    let onSelectOrder: (GalleryCommentOrder) -> Void
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void
    let onLoadMore: @Sendable (GalleryComment?) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("评论")
                    .font(.headline)

                Text("\(totalCommentCount)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("排序", selection: Binding(get: { selectedOrder }, set: onSelectOrder)) {
                    ForEach(GalleryCommentOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
                .pickerStyle(.menu)
            }

            switch status {
            case .idle where comments.isEmpty, .loading where comments.isEmpty:
                ProgressView("正在加载评论")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            case let .failed(message) where comments.isEmpty:
                ContentUnavailableView {
                    Label("加载评论失败", systemImage: "bubble.right.fill")
                } description: {
                    Text(message)
                }
            default:
                if comments.isEmpty {
                    Text(totalCommentCount == 0 ? "还没有评论" : "评论已根据社区规范隐藏")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(comments.enumerated()), id: \.element.id) { index, comment in
                            VStack(spacing: 0) {
                                GalleryCommentRow(
                                    comment: comment,
                                    likingCommentIDs: likingCommentIDs,
                                    onReply: onReply,
                                    onLikeComment: onLikeComment,
                                    onOpenImage: onOpenImage,
                                    onOpenUser: onOpenUser
                                )

                                if index != comments.count - 1 {
                                    Divider()
                                        .padding(.leading, 46)
                                }
                            }
                            .onAppear {
                                Task {
                                    await onLoadMore(comment)
                                }
                            }
                        }

                        if isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                    }
                }
            }
        }
    }
}

/// 评论回复目标。
private struct GalleryCommentReplyTarget {
    let mainComment: GalleryComment
    let targetComment: GalleryComment
}

/// 单条评论及其子评论预览。
private struct GalleryCommentRow: View {
    let comment: GalleryComment
    let likingCommentIDs: Set<Int>
    let onReply: (GalleryCommentReplyTarget) -> Void
    let onLikeComment: (GalleryComment) -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: (GalleryUser) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GalleryCommentBubble(
                comment: comment,
                isSubComment: false,
                isLiking: likingCommentIDs.contains(comment.id),
                onReply: {
                    onReply(GalleryCommentReplyTarget(mainComment: comment, targetComment: comment))
                },
                onLike: {
                    onLikeComment(comment)
                },
                onOpenImage: onOpenImage,
                onOpenUser: {
                    onOpenUser(comment.user)
                }
            )

            if !comment.sub.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(comment.sub.enumerated()), id: \.element.id) { index, subComment in
                        VStack(spacing: 0) {
                            GalleryCommentBubble(
                                comment: subComment,
                                isSubComment: true,
                                isLiking: likingCommentIDs.contains(subComment.id),
                                onReply: {
                                    onReply(GalleryCommentReplyTarget(mainComment: comment, targetComment: subComment))
                                },
                                onLike: {
                                    onLikeComment(subComment)
                                },
                                onOpenImage: onOpenImage,
                                onOpenUser: {
                                    onOpenUser(subComment.user)
                                }
                            )

                            if index != comment.sub.count - 1 {
                                Divider()
                                    .padding(.leading, 42)
                            }
                        }
                    }
                }
                .padding(.leading, 42)
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// 评论内容气泡。
private struct GalleryCommentBubble: View {
    let comment: GalleryComment
    let isSubComment: Bool
    let isLiking: Bool
    let onReply: () -> Void
    let onLike: () -> Void
    let onOpenImage: (Int, [GalleryImage]) -> Void
    let onOpenUser: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if canOpenUserProfile {
                    Button(action: onOpenUser) {
                        GalleryAvatarView(imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl))
                            .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                    }
                    .buttonStyle(.plain)
                } else {
                    GalleryAvatarView(imageURL: URL(string: comment.user.avatar.lowUrl.isEmpty ? comment.user.avatar.url : comment.user.avatar.lowUrl))
                        .frame(width: isSubComment ? 28 : 34, height: isSubComment ? 28 : 34)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Group {
                        if canOpenUserProfile {
                            Button(action: onOpenUser) {
                                Text(comment.user.nickname)
                                    .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Text(comment.user.nickname)
                                .font(isSubComment ? .subheadline.weight(.semibold) : .headline)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)

                    Text(relativeTimeText(comment.createTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                commentText

                if !comment.images.isEmpty {
                    GalleryPosterImagesView(images: comment.images, onOpenImage: onOpenImage)
                }

                HStack(spacing: 10) {
                    Button(action: onLike) {
                        HStack(spacing: 4) {
                            if isLiking {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: comment.like ? "hand.thumbsup.fill" : "hand.thumbsup")
                            }

                            Text("\(comment.likeNum)")
                                .font(.caption)
                        }
                        .foregroundStyle(comment.like ? Color.orange : Color.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onReply)
    }

    private var canOpenUserProfile: Bool {
        !comment.anonymous && comment.user.id > 0
    }

    @ViewBuilder
    private var commentText: some View {
        if comment.replyUser.id != 0, !comment.replyUser.nickname.isEmpty {
            (
                Text("回复 @\(comment.replyUser.nickname)：")
                    .foregroundStyle(.secondary) +
                    Text(comment.text)
                    .foregroundStyle(.primary)
            )
            .font(.subheadline)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(comment.text)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
    }
}

/// 评论发送弹层。
private struct GalleryCommentComposerSheet: View {
    let target: GalleryCommentComposerTarget
    let isSubmitting: Bool
    let onSubmit: @Sendable (String, Bool) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var anonymous = false

    var body: some View {
        NavigationStack {
            Form {
                Section("内容") {
                    TextField(target.placeholder, text: $text, axis: .vertical)
                        .lineLimit(5, reservesSpace: true)

                    Toggle("匿名评论", isOn: $anonymous)
                }
            }
            .navigationTitle(target.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "发送中" : "发送") {
                        Task {
                            let success = await onSubmit(text, anonymous)
                            if success {
                                dismiss()
                            }
                        }
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }
}

/// 搜索页。
private struct GallerySearchView: View {
    @ObservedObject var viewModel: GalleryViewModel
    @ObservedObject private var settings = AppSettingsStore.shared

    var body: some View {
        GalleryFeedView(
            feedState: filteredSearchState,
            feedIdentity: "search",
            prefetchTriggerThreshold: 0,
            onRefresh: {
                await viewModel.performSearch()
            },
            onPrefetch: { _ in },
            onLoadMore: { poster in
                await viewModel.loadMoreSearchResultsIfNeeded(currentPoster: poster)
            }
        )
        .safeAreaInset(edge: .top) {
            GallerySearchBar(
                query: $viewModel.searchQuery,
                onSubmit: {
                    Task {
                        await viewModel.performSearch()
                    }
                },
                onClear: {
                    viewModel.searchQuery.text = ""
                    Task {
                        await viewModel.performSearch()
                    }
                }
            )
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.thinMaterial)
        }
        .task {
            await viewModel.bootstrapSearchIfNeeded()
        }
    }

    private var filteredSearchState: GalleryFeedState {
        var state = viewModel.searchState
        state.posters = CommunityModeration.filterVisiblePosters(state.posters, snapshot: settings.snapshot)
        return state
    }
}

/// 原生消息页。
///
/// Android 虽然最终落到网页，但后端已经提供独立消息接口，因此 iOS 直接走 native list。
private struct GalleryMessagesView: View {
    @ObservedObject var viewModel: GalleryMessageViewModel
    @State private var selectedPoster: GalleryPoster?
    @State private var localAlert: LoginAlert?
    private let service = GalleryService()

    var body: some View {
        ZStack {
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            Group {
                if isInitialLoading {
                    ProgressView("正在加载消息")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if case let .failed(message) = currentState.status, currentState.items.isEmpty {
                    ContentUnavailableView {
                        Label("加载消息失败", systemImage: "bell.badge")
                    } description: {
                        Text(message)
                    }
                } else {
                    List {
                        ForEach(Array(currentState.items.enumerated()), id: \.element.id) { index, message in
                        VStack(spacing: 0) {
                            GalleryMessageRow(
                                type: viewModel.selectedType,
                                message: message,
                                isUnread: viewModel.isUnread(message, in: viewModel.selectedType),
                                onOpenPoster: {
                                    Task {
                                        await openMessage(message)
                                    }
                                }
                            )

                                if index != currentState.items.count - 1 {
                                    Divider()
                                        .padding(.leading, 52)
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onAppear {
                                Task {
                                    await viewModel.loadMoreIfNeeded(for: viewModel.selectedType, currentMessage: message)
                                }
                            }
                        }

                        if currentState.isLoadingMore {
                            HStack {
                                Spacer()
                                ProgressView()
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color(.systemGroupedBackground))
                    .refreshable {
                        await viewModel.refreshSelectedType()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(messageSwitchGesture)
        .navigationTitle("消息")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("全部已读") {
                    viewModel.markCurrentTypeAsRead()
                }
                .disabled(!viewModel.hasUnreadInCurrentType)
            }
        }
        .safeAreaInset(edge: .top) {
            Picker("消息分类", selection: $viewModel.selectedType) {
                ForEach(GalleryMessageType.allCases) { type in
                    Text(title(for: type)).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .background(Color(.systemGroupedBackground))
        }
        .task {
            await viewModel.bootstrapIfNeeded()
        }
        .onChange(of: viewModel.selectedType) { _, newType in
            if viewModel.state(for: newType).status == .idle {
                Task {
                    await viewModel.refresh(type: newType)
                }
            }
        }
        .sheet(item: $selectedPoster) { poster in
            NavigationStack {
                GalleryPosterDetailView(poster: poster)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
        .alert(item: $localAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var currentState: GalleryMessageListState {
        viewModel.state(for: viewModel.selectedType)
    }

    private var isInitialLoading: Bool {
        switch currentState.status {
        case .idle, .loading:
            return currentState.items.isEmpty
        default:
            return false
        }
    }

    private var messageSwitchGesture: some Gesture {
        DragGesture(minimumDistance: 24, coordinateSpace: .local)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                guard abs(horizontal) > abs(vertical), abs(horizontal) >= 56 else { return }

                if horizontal < 0 {
                    switchType(step: 1)
                } else {
                    switchType(step: -1)
                }
            }
    }

    private func title(for type: GalleryMessageType) -> String {
        let unread = viewModel.unreadCount(for: type)
        guard unread > 0 else { return type.title }
        return unread > 99 ? "\(type.title) 99+" : "\(type.title) \(unread)"
    }

    private func switchType(step: Int) {
        let allTypes = GalleryMessageType.allCases
        guard let currentIndex = allTypes.firstIndex(of: viewModel.selectedType) else { return }

        let nextIndex = currentIndex + step
        guard allTypes.indices.contains(nextIndex) else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.selectedType = allTypes[nextIndex]
        }
    }

    private func openMessage(_ message: GalleryMessage) async {
        viewModel.markMessageAsRead(message, in: viewModel.selectedType)

        guard let posterID = message.linkedPosterID else { return }

        do {
            let poster = try await service.fetchPoster(id: posterID)
            selectedPoster = poster.asPoster
        } catch {
            if error is CancellationError {
                return
            }
            localAlert = LoginAlert(title: "无法打开", message: "相关帖子不存在或已删除。")
        }
    }
}

/// 单条消息行。
private struct GalleryMessageRow: View {
    let type: GalleryMessageType
    let message: GalleryMessage
    let isUnread: Bool
    let onOpenPoster: () -> Void

    private var canOpenPoster: Bool {
        message.linkedPosterID != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            GalleryMessageAvatarView(user: message.fromUser, type: type)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isUnread {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                    }

                    Text(message.fromUser.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(relativeTimeText(message.updateTime))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(type.actionText(for: message))
                    .font(.subheadline)
                    .foregroundStyle(.primary)

                if !message.text.isEmpty {
                    Text(message.text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if canOpenPoster {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isUnread ? Color.orange.opacity(0.06) : Color(.systemBackground))
        .contentShape(Rectangle())
        .onTapGesture {
            guard canOpenPoster else { return }
            onOpenPoster()
        }
    }

    private func relativeTimeText(_ string: String) -> String {
        GalleryDateDecoder.relativeText(from: string, fallback: "未知时间")
    }
}

/// 消息头像。
private struct GalleryMessageAvatarView: View {
    let user: GalleryMessageUser
    let type: GalleryMessageType

    var body: some View {
        if user.id == 0 {
            ZStack {
                Circle().fill(Color.orange.opacity(0.12))
                Image(systemName: type == .system ? "bell.fill" : "person.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
            .frame(width: 34, height: 34)
        } else {
            GalleryAvatarView(imageURL: user.avatar.preferredURL)
        }
    }
}

/// 举报动作的上下文。
private struct GalleryReportContext: Identifiable {
    let poster: GalleryPoster
    let action: CommunityReportAction

    var id: String {
        "\(action.rawValue)-\(poster.id)"
    }
}

/// 帖子卡片右上角的更多操作菜单。
private struct GalleryPosterActionMenu: View {
    let onSelectAction: ((CommunityReportAction) -> Void)?
    let onDelete: (() -> Void)?

    var body: some View {
        Menu {
            if let onSelectAction {
                Button(CommunityReportAction.hidePoster.title, systemImage: "eye.slash") {
                    onSelectAction(.hidePoster)
                }

                Button(CommunityReportAction.blockUser.title, systemImage: "person.crop.circle.badge.xmark") {
                    onSelectAction(.blockUser)
                }
            }

            if let onDelete {
                Button("删除帖子", systemImage: "trash", role: .destructive) {
                    onDelete()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}

/// 举报弹层。
///
/// 负责收集举报类型和补充说明，提交后再交给上层执行本地隐藏与异步上报。
private struct CommunityReportSheet: View {
    let context: GalleryReportContext
    let onSubmit: (CommunityReportType, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedType = CommunityModeration.reportTypes.last ?? CommunityReportType(id: 7, title: "其他")
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("处理对象") {
                    Text(context.poster.title.isEmpty ? "未命名帖子" : context.poster.title)
                    Text(context.poster.user.nickname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("举报类型") {
                    Picker("类型", selection: $selectedType) {
                        ForEach(CommunityModeration.reportTypes) { type in
                            Text(type.title).tag(type)
                        }
                    }
                }

                Section("补充说明") {
                    TextField("可选，补充你看到的问题", text: $note, axis: .vertical)
                        .lineLimit(4, reservesSpace: true)
                }

                Section("联系开发者") {
                    Text(CommunitySupport.email)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(context.action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("提交") {
                        onSubmit(selectedType, note.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                }
            }
        }
    }
}

/// 搜索输入框。
///
/// 输入框本体、自定义排序按钮和清空按钮都集中在这里，避免搜索页本身承载过多细节。
private struct GallerySearchBar: View {
    @Binding var query: GallerySearchQuery
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker(
                selection: Binding(
                    get: { query.order },
                    set: { newValue in
                        query.order = newValue
                        onSubmit()
                    }
                )
            ) {
                ForEach(GallerySearchOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            } label: {
                Label(query.order.title, systemImage: "arrow.up.arrow.down.circle")
            }
            .pickerStyle(.menu)

            TextField("在这里搜索哦", text: $query.text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit(onSubmit)

            Button {
                query.text = ""
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(query.text.isEmpty ? Color.secondary.opacity(0.35) : Color.orange)
            }
            .buttonStyle(.plain)
            .disabled(query.text.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// 图片查看器当前状态。
struct GalleryImageViewerState: Identifiable {
    let id = UUID()
    let images: [GalleryImage]
    let initialIndex: Int
}

/// 全屏图片查看器。
///
/// 负责多图左右切换、沉浸式背景和关闭按钮。
struct GalleryImageViewer: View {
    let viewer: GalleryImageViewerState
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedIndex) {
                ForEach(Array(viewer.images.enumerated()), id: \.element.id) { index, image in
                    GalleryZoomableRemoteImage(url: URL(string: image.url.isEmpty ? image.lowUrl : image.url))
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.45), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 4)
                    .padding(20)
            }
            .buttonStyle(.plain)
        }
        .onAppear {
            selectedIndex = min(max(viewer.initialIndex, 0), max(viewer.images.count - 1, 0))
        }
    }
}

/// 基于 `UIScrollView` 的可缩放远程图片。
///
/// SwiftUI 原生 `AsyncImage` 不适合处理缩放和内容居中，这里用 UIKit 桥一层。
private struct GalleryZoomableRemoteImage: UIViewRepresentable {
    let url: URL?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.clipsToBounds = true
        context.coordinator.install(on: scrollView)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.update(url: url, in: scrollView)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        private let imageView = UIImageView()
        private let spinner = UIActivityIndicatorView(style: .large)
        private var currentURL: URL?
        private var task: URLSessionDataTask?

        func install(on scrollView: UIScrollView) {
            imageView.contentMode = .scaleAspectFit
            imageView.backgroundColor = .clear
            scrollView.addSubview(imageView)

            spinner.color = .white
            spinner.hidesWhenStopped = true
            scrollView.addSubview(spinner)
        }

        func update(url: URL?, in scrollView: UIScrollView) {
            spinner.center = CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY)

            if currentURL != url {
                currentURL = url
                imageView.image = nil
                task?.cancel()
                loadImage(from: url, in: scrollView)
            } else if imageView.image != nil {
                layoutImage(in: scrollView)
            }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerImage(in: scrollView)
        }

        private func loadImage(from url: URL?, in scrollView: UIScrollView) {
            guard let url else { return }
            spinner.startAnimating()

            task = URLSession.shared.dataTask(with: url) { [weak self, weak scrollView] data, _, _ in
                guard let self, let scrollView else { return }
                let image = data.flatMap(UIImage.init(data:))
                DispatchQueue.main.async {
                    self.spinner.stopAnimating()
                    self.imageView.image = image
                    self.layoutImage(in: scrollView)
                }
            }
            task?.resume()
        }

        private func layoutImage(in scrollView: UIScrollView) {
            scrollView.zoomScale = 1

            guard let image = imageView.image else {
                imageView.frame = scrollView.bounds
                scrollView.contentSize = scrollView.bounds.size
                return
            }

            let boundsSize = scrollView.bounds.size
            let fitSize = aspectFitSize(for: image.size, in: boundsSize)
            imageView.frame = CGRect(origin: .zero, size: fitSize)
            scrollView.contentSize = fitSize
            centerImage(in: scrollView)
        }

        private func centerImage(in scrollView: UIScrollView) {
            let boundsSize = scrollView.bounds.size
            var frame = imageView.frame

            frame.origin.x = frame.size.width < boundsSize.width ? (boundsSize.width - frame.size.width) / 2 : 0
            frame.origin.y = frame.size.height < boundsSize.height ? (boundsSize.height - frame.size.height) / 2 : 0

            imageView.frame = frame
        }

        private func aspectFitSize(for imageSize: CGSize, in boundsSize: CGSize) -> CGSize {
            guard imageSize.width > 0, imageSize.height > 0, boundsSize.width > 0, boundsSize.height > 0 else {
                return boundsSize
            }

            let widthRatio = boundsSize.width / imageSize.width
            let heightRatio = boundsSize.height / imageSize.height
            let scale = min(widthRatio, heightRatio)

            return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        }
    }
}

/// 帖子时间文本格式化工具。
private enum GalleryDateDecoder {
    private static let formatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ"),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ"),
    ]

    private static let iso8601Formatter = ISO8601DateFormatter()
    private static let relativeFormatter = RelativeDateTimeFormatter()

    static func date(from string: String) -> Date? {
        for formatter in formatters {
            if let date = formatter.date(from: string) {
                return date
            }
        }

        return iso8601Formatter.date(from: string)
    }

    static func relativeText(from string: String, fallback: String) -> String {
        guard let date = date(from: string) else {
            return fallback
        }

        return relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
        formatter.dateFormat = format
        return formatter
    }
}

/// 兼容服务端返回的十六进制颜色字符串。
private extension Color {
    init?(hex: String) {
        let sanitized = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard sanitized.count == 6, let value = Int(sanitized, radix: 16) else {
            return nil
        }

        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}
