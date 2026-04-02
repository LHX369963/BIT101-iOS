//
//  CourseViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Combine
import Foundation

/// 判断课程请求是否只是被任务取消，避免把切页或重复触发刷新误报成失败。
private func isCourseRequestCancellation(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }

    if let urlError = error as? URLError, urlError.code == .cancelled {
        return true
    }

    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

private func courseShouldLoadMore(currentID: Int, state: CoursePagedState) -> Bool {
    guard
        state.status == .loaded,
        !state.isLoadingMore,
        state.canLoadMore,
        state.items.suffix(4).contains(where: { $0.id == currentID })
    else {
        return false
    }

    return true
}

private extension CoursePagedState {
    /// 进入首屏刷新时重置分页游标。
    mutating func prepareForRefresh() {
        status = .loading
        items = []
        nextPage = 0
        canLoadMore = true
        isLoadingMore = false
    }

    /// 首屏页加载完成后统一落状态。
    mutating func applyFirstPage(_ items: [CourseSummary]) {
        self.items = items
        status = .loaded
        nextPage = 1
        canLoadMore = !items.isEmpty
        isLoadingMore = false
    }

    /// 追加后续分页结果，并推进下一页游标。
    mutating func appendPage(_ items: [CourseSummary]) {
        self.items.append(contentsOf: items)
        nextPage += 1
        isLoadingMore = false
        canLoadMore = !items.isEmpty
    }
}

@MainActor
/// 课程列表状态机。
final class CourseListViewModel: ObservableObject {
    @Published private(set) var state = CoursePagedState()
    @Published var searchText = ""
    @Published var alert: LoginAlert?

    private let service: CourseService
    private var hasBootstrapped = false

    init(service: CourseService) {
        self.service = service
    }

    convenience init() {
        self.init(service: CourseService())
    }

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasActiveSearch: Bool {
        !normalizedSearchText.isEmpty
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        await refresh()
    }

    func refresh() async {
        let hadCourses = !state.items.isEmpty || state.status == .loaded
        if !hadCourses {
            state.prepareForRefresh()
        } else {
            state.isLoadingMore = false
        }

        do {
            let items = try await service.fetchCourses(
                search: normalizedSearchText,
                page: 0
            )
            state.applyFirstPage(items)
        } catch {
            if isCourseRequestCancellation(error) {
                if !hadCourses {
                    state.status = .idle
                }
                return
            }

            state.isLoadingMore = false

            if hadCourses {
                state.status = .loaded
                alert = LoginAlert(title: "刷新课程失败", message: error.localizedDescription)
                return
            }

            state.status = .failed(error.localizedDescription)
            state.canLoadMore = false
            alert = LoginAlert(title: "加载课程失败", message: error.localizedDescription)
        }
    }

    func loadMoreIfNeeded(currentCourse: CourseSummary?) async {
        guard let currentCourse else { return }
        guard courseShouldLoadMore(currentID: currentCourse.id, state: state) else { return }

        state.isLoadingMore = true

        do {
            let items = try await service.fetchCourses(
                search: normalizedSearchText,
                page: state.nextPage
            )
            state.appendPage(items)
        } catch {
            if isCourseRequestCancellation(error) {
                state.isLoadingMore = false
                return
            }

            state.isLoadingMore = false
            alert = LoginAlert(title: "加载更多失败", message: error.localizedDescription)
        }
    }

    func submitSearch() async {
        await refresh()
    }

    func clearSearchIfNeeded(from oldValue: String, to newValue: String) {
        let oldKeyword = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKeyword = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oldKeyword.isEmpty, newKeyword.isEmpty else { return }

        Task {
            await refresh()
        }
    }
}
