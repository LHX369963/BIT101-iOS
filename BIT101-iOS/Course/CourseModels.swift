//
//  CourseModels.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-04-02.
//

import Foundation

/// 课程评分展示工具。
///
/// 后端课程与课程评论评分当前仍按 10 分制返回，iOS 端统一折算成 5 分制展示。
enum CourseRatingText {
    nonisolated static func value(from raw: Double) -> Double {
        max(0, raw) / 2
    }

    nonisolated static func value(from raw: Int) -> Double {
        value(from: Double(raw))
    }

    nonisolated static func text(from raw: Double, empty: String = "暂无") -> String {
        guard raw > 0 else { return empty }
        return String(format: "%.1f/5", value(from: raw))
    }

    nonisolated static func text(from raw: Int, empty: String = "未评分") -> String {
        guard raw > 0 else { return empty }
        return String(format: "%.1f/5", value(from: raw))
    }
}

/// 课程列表单项。
///
/// 当前底部课程页先承接课程浏览与详情能力，因此模型只保留列表展示所需字段。
struct CourseSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    let number: String
    let likeNum: Int
    let commentNum: Int
    let rate: Double
    let teachersName: String
    let teachersNumber: String
}

/// 课程详情。
///
/// 详情接口在课程基础信息外，还会返回当前用户的点赞状态。
struct CourseDetail: Decodable, Equatable {
    let id: Int
    let name: String
    let number: String
    let likeNum: Int
    let commentNum: Int
    let rate: Double
    let teachersName: String
    let teachersNumber: String
    let like: Bool

    /// 返回替换点赞状态后的新课程详情。
    func updatingLike(_ like: Bool, likeNum: Int) -> CourseDetail {
        CourseDetail(
            id: id,
            name: name,
            number: number,
            likeNum: likeNum,
            commentNum: commentNum,
            rate: rate,
            teachersName: teachersName,
            teachersNumber: teachersNumber,
            like: like
        )
    }
}

/// 课程页整体加载状态。
///
/// 列表页只需要区分“首屏加载中 / 已有内容 / 首屏失败”这几类状态，
/// 细粒度的分页加载单独放在 `CoursePagedState` 里维护。
enum CourseLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}

/// 课程列表分页状态。
///
/// 这里把首屏状态和分页游标放在一起，避免视图层分别维护多组彼此耦合的布尔值。
struct CoursePagedState {
    var items: [CourseSummary] = []
    var status: CourseLoadStatus = .idle
    var nextPage = 0
    var isLoadingMore = false
    var canLoadMore = true
}

/// 课程详情加载状态。
///
/// 课程详情页与评论列表是两条并行的数据流，因此详情本体单独维护自己的加载状态。
enum CourseDetailLoadStatus: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
}
