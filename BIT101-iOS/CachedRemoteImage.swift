//
//  CachedRemoteImage.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-29.
//

import Combine
import CryptoKit
import SwiftUI
import UIKit

/// 主 app 内统一复用的远程图片缓存视图。
///
/// SwiftUI 的 `AsyncImage` 很依赖系统和服务端的缓存策略。头像资源如果服务端没有正确下发
/// `Cache-Control`，每次冷启动都可能重新下载。这里显式补一层“内存 + 磁盘”缓存，保证头像
/// 在应用重启后也能命中本地缓存，而不必每次重新走网络。
struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @StateObject private var loader = CachedRemoteImageLoader()

    init(
        url: URL?,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = loader.image {
                content(Image(uiImage: image))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await loader.load(url: url)
        }
    }
}

@MainActor
private final class CachedRemoteImageLoader: ObservableObject {
    @Published private(set) var image: UIImage?

    private var currentURL: URL?

    /// 加载指定 URL 的图片。
    ///
    /// 先读本地缓存，再回退到网络下载。URL 切换时会主动清掉旧图，避免列表复用时闪旧头像。
    func load(url: URL?) async {
        if currentURL == url, image != nil {
            return
        }

        currentURL = url
        image = nil

        guard let url else { return }

        if let cachedData = await CachedRemoteImageStore.shared.data(for: url),
           let cachedImage = UIImage(data: cachedData) {
            image = cachedImage
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled, currentURL == url else { return }
            guard let downloadedImage = UIImage(data: data) else { return }

            await CachedRemoteImageStore.shared.store(data, for: url)
            image = downloadedImage
        } catch {
            // 头像加载失败时直接停留在占位图，不额外打断 UI。
        }
    }
}

/// 头像图片的轻量本地缓存。
///
/// 这里不走复杂的 LRU 或 HTTP 协商，目标只是把频繁重复使用的头像稳定落到本地缓存目录。
private actor CachedRemoteImageStore {
    static let shared = CachedRemoteImageStore()

    private let memoryCache = NSCache<NSString, NSData>()
    private let fileManager = FileManager.default
    private let directoryURL: URL

    init() {
        let cachesDirectory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let directoryURL = cachesDirectory.appendingPathComponent("BIT101ImageCache", isDirectory: true)
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        self.directoryURL = directoryURL
    }

    func data(for url: URL) -> Data? {
        let key = cacheKey(for: url)

        if let cached = memoryCache.object(forKey: key as NSString) {
            return Data(referencing: cached)
        }

        let fileURL = directoryURL.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    func store(_ data: Data, for url: URL) {
        let key = cacheKey(for: url)
        memoryCache.setObject(data as NSData, forKey: key as NSString)
        let fileURL = directoryURL.appendingPathComponent(key)
        try? data.write(to: fileURL, options: .atomic)
    }

    private func cacheKey(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
