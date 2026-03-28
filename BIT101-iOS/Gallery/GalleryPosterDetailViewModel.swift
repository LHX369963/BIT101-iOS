import Combine
import Foundation

/// 帖子详情评论列表的分页状态。
struct GalleryCommentState {
    /// 当前已加载的顶层评论列表。
    var items: [GalleryComment] = []
    /// 评论区当前的整体加载状态。
    var status: GalleryFeedStatus = .idle
    /// 是否正在请求下一页评论。
    var isLoadingMore = false
    /// 下一页评论页码。
    var nextPage = 0
    /// 服务端是否还有更多评论。
    var canLoadMore = true
}

/// 评论输入的目标。
enum GalleryCommentComposerTarget: Identifiable, Equatable {
    case poster(posterID: Int)
    case comment(mainComment: GalleryComment, targetComment: GalleryComment)

    /// 供 sheet 和焦点状态使用的稳定标识。
    var id: String {
        switch self {
        case let .poster(posterID):
            return "poster-\(posterID)"
        case let .comment(mainComment, targetComment):
            return "comment-\(mainComment.id)-\(targetComment.id)"
        }
    }

    /// 当前输入行为的可读标题。
    var title: String {
        switch self {
        case .poster:
            return "发表评论"
        case let .comment(_, targetComment):
            return "回复 @\(targetComment.user.nickname)"
        }
    }

    /// 评论输入框占位文案。
    var placeholder: String {
        switch self {
        case .poster:
            return "写点什么吧"
        case let .comment(_, targetComment):
            return "回复 @\(targetComment.user.nickname)"
        }
    }

    /// 发评论接口里的目标对象 ID。
    var objectID: String {
        switch self {
        case let .poster(posterID):
            return "poster\(posterID)"
        case let .comment(mainComment, _):
            return "comment\(mainComment.id)"
        }
    }

    /// 回复评论时需要带上的次级目标对象 ID。
    var replyObjectID: String? {
        switch self {
        case .poster:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return "comment\(targetComment.id)"
        }
    }

    /// 回复评论时用于 @ 提示的用户 ID。
    var replyUID: Int? {
        switch self {
        case .poster:
            return nil
        case let .comment(mainComment, targetComment):
            guard mainComment.id != targetComment.id else { return nil }
            return targetComment.user.id
        }
    }
}

@MainActor
/// 帖子详情状态机。
///
/// 负责重新拉取帖子详情、评论分页、排序切换、点赞和评论发送。
final class GalleryPosterDetailViewModel: ObservableObject {
    @Published private(set) var poster: GalleryPosterDetail
    @Published private(set) var posterStatus: GalleryFeedStatus = .idle
    @Published private(set) var commentState = GalleryCommentState()
    @Published var commentOrder: GalleryCommentOrder = .newest
    @Published private(set) var isLikingPoster = false
    @Published private(set) var likingCommentIDs: Set<Int> = []
    @Published private(set) var isSubmittingComment = false
    @Published private(set) var isDeletingPoster = false
    @Published var alert: LoginAlert?

    private let posterID: Int
    private let service: GalleryService

    init(initialPoster: GalleryPoster, service: GalleryService) {
        posterID = initialPoster.id
        poster = GalleryPosterDetail(poster: initialPoster)
        self.service = service
    }

    convenience init(initialPoster: GalleryPoster) {
        self.init(initialPoster: initialPoster, service: GalleryService())
    }

    /// 首次进入详情页时同时拉取帖子详情和第一页评论。
    func bootstrapIfNeeded() async {
        guard posterStatus == .idle, commentState.status == .idle else { return }
        await refreshAll()
    }

    /// 同步刷新帖子详情和评论列表。
    func refreshAll() async {
        posterStatus = .loading
        commentState.status = .loading
        commentState.isLoadingMore = false
        commentState.nextPage = 0
        commentState.canLoadMore = true

        async let posterResult = loadResult { [self] in
            try await self.service.fetchPoster(id: self.posterID)
        }
        async let commentResult = loadResult { [self, commentOrder] in
            try await self.service.fetchComments(objectID: "poster\(self.posterID)", order: commentOrder, page: nil)
        }

        let resolvedPosterResult = await posterResult
        let resolvedCommentResult = await commentResult

        handlePosterResult(resolvedPosterResult)
        handleCommentRefreshResult(resolvedCommentResult)
    }

    /// 仅刷新评论区，不重新请求帖子正文。
    func refreshComments() async {
        commentState.status = .loading
        commentState.items = []
        commentState.isLoadingMore = false
        commentState.nextPage = 0
        commentState.canLoadMore = true

        let result = await loadResult { [self] in
            try await self.service.fetchComments(objectID: "poster\(self.posterID)", order: self.commentOrder, page: nil)
        }
        handleCommentRefreshResult(result)
    }

    /// 当滚动到尾部附近时触发评论分页。
    func loadMoreCommentsIfNeeded(currentComment: GalleryComment?) async {
        guard let currentComment else { return }
        guard
            commentState.status == .loaded,
            !commentState.isLoadingMore,
            commentState.canLoadMore,
            commentState.items.suffix(4).contains(where: { $0.id == currentComment.id })
        else {
            return
        }

        commentState.isLoadingMore = true
        let nextPage = commentState.nextPage
        let result = await loadResult { [self] in
            try await self.service.fetchComments(objectID: "poster\(self.posterID)", order: self.commentOrder, page: nextPage)
        }

        switch result {
        case let .success(comments):
            commentState.items.append(contentsOf: comments)
            commentState.nextPage += 1
            commentState.isLoadingMore = false
            commentState.canLoadMore = !comments.isEmpty
        case let .failure(error):
            if isCancellation(error) {
                commentState.isLoadingMore = false
                return
            }
            commentState.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    /// 切换评论排序后立刻重新请求第一页。
    func setCommentOrder(_ order: GalleryCommentOrder) async {
        guard commentOrder != order else { return }
        commentOrder = order
        await refreshComments()
    }

    /// 点赞或取消点赞当前帖子。
    func likePoster() async {
        guard !isLikingPoster else { return }
        isLikingPoster = true
        defer { isLikingPoster = false }

        do {
            let result = try await service.like(objectID: "poster\(posterID)")
            poster = poster.updatingLike(result.like, likeNum: result.likeNum)
        } catch {
            if isCancellation(error) { return }
            alert = LoginAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    /// 点赞或取消点赞某条评论。
    func likeComment(_ comment: GalleryComment) async {
        guard !likingCommentIDs.contains(comment.id) else { return }
        likingCommentIDs.insert(comment.id)
        defer { likingCommentIDs.remove(comment.id) }

        do {
            let result = try await service.like(objectID: "comment\(comment.id)")
            commentState.items = commentState.items.updatingLike(for: comment.id, like: result.like, likeNum: result.likeNum)
        } catch {
            if isCancellation(error) { return }
            alert = LoginAlert(title: "点赞失败", message: error.localizedDescription)
        }
    }

    /// 发送评论或回复。
    ///
    /// 发送成功后直接整页刷新，确保帖子计数和评论树保持一致。
    func submitComment(text: String, anonymous: Bool, target: GalleryCommentComposerTarget) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alert = LoginAlert(title: "发送失败", message: "评论不能为空。")
            return false
        }
        if let message = CommunityModeration.validateCommentDraft(text: trimmed) {
            alert = LoginAlert(title: "内容不合规", message: message)
            return false
        }
        guard !isSubmittingComment else { return false }

        isSubmittingComment = true
        defer { isSubmittingComment = false }

        do {
            _ = try await service.createComment(
                objectID: target.objectID,
                text: trimmed,
                replyObjectID: target.replyObjectID,
                replyUID: target.replyUID,
                anonymous: anonymous
            )
            await refreshAll()
            return true
        } catch {
            if isCancellation(error) { return false }
            alert = LoginAlert(title: "发送失败", message: error.localizedDescription)
            return false
        }
    }

    /// 删除当前帖子。
    func deletePoster() async -> Bool {
        guard poster.own else { return false }
        guard !isDeletingPoster else { return false }

        isDeletingPoster = true
        defer { isDeletingPoster = false }

        do {
            try await service.deletePoster(id: posterID)
            return true
        } catch {
            if isCancellation(error) { return false }
            alert = LoginAlert(title: "删除失败", message: error.localizedDescription)
            return false
        }
    }

    /// 统一处理帖子详情请求结果。
    private func handlePosterResult(_ result: Result<GalleryPosterDetail, Error>) {
        switch result {
        case let .success(poster):
            self.poster = poster
            posterStatus = .loaded
        case let .failure(error):
            if isCancellation(error) {
                posterStatus = .loaded
                return
            }
            posterStatus = .failed(error.localizedDescription)
            alert = LoginAlert(title: "加载帖子失败", message: error.localizedDescription)
        }
    }

    private func handleCommentRefreshResult(_ result: Result<[GalleryComment], Error>) {
        switch result {
        case let .success(comments):
            commentState.items = comments
            commentState.status = .loaded
            commentState.nextPage = 1
            commentState.canLoadMore = !comments.isEmpty
            commentState.isLoadingMore = false
        case let .failure(error):
            if isCancellation(error) {
                commentState.status = .idle
                commentState.isLoadingMore = false
                return
            }
            commentState.status = .failed(error.localizedDescription)
            commentState.canLoadMore = false
            commentState.isLoadingMore = false
            alert = LoginAlert(title: "加载评论失败", message: error.localizedDescription)
        }
    }

    private func loadResult<T>(_ operation: @escaping () async throws -> T) async -> Result<T, Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    /// 同时兼容 Swift Concurrency 的 `CancellationError` 和 URLSession 的 `-999 cancelled`。
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private extension Array where Element == GalleryComment {
    func updatingLike(for commentID: Int, like: Bool, likeNum: Int) -> [GalleryComment] {
        map { comment in
            let updatedSub = comment.sub.updatingLike(for: commentID, like: like, likeNum: likeNum)
            let updated = comment.replacingSubComments(updatedSub)
            if updated.id == commentID {
                return updated.updatingLike(like, likeNum: likeNum)
            }
            return updated
        }
    }
}
