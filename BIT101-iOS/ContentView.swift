//
//  ContentView.swift
//  BIT101-iOS
//
//  Created by Harry Bit on 2026-03-24.
//

import SwiftUI

/// 根容器视图。
///
/// 目前整个应用都从登录态入口开始，后续如果增加启动广告、全局路由，
/// 也会优先从这里接入。
struct ContentView: View {
    /// 应用根节点当前只承载登录模块。
    ///
    /// 登录成功后，后续导航全部交给 `LoginRootView` 内部的壳层处理。
    var body: some View {
        LoginRootView()
    }
}
