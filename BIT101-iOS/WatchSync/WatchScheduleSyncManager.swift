#if canImport(WatchConnectivity)

import Foundation
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// iPhone 与 Apple Watch 之间的课表快照同步器。
///
/// 当前策略非常明确：
/// - iPhone 仍然是真相源，负责产生 `ScheduleExternalSnapshot`
/// - 通过 `WatchConnectivity` 把最新快照推到 watch
/// - watch 收到后写入本地 App Group，再由 watch widget 读取
@MainActor
final class WatchScheduleSyncManager: NSObject, WCSessionDelegate {
    static let shared = WatchScheduleSyncManager()

    private enum PayloadKey {
        nonisolated static let snapshotData = "schedule_external_snapshot_data"
        nonisolated static let requestLatestSnapshot = "request_latest_schedule_snapshot"
    }

    nonisolated private static let requestData = Data("request_latest_schedule_snapshot".utf8)

    nonisolated private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private override init() {
        super.init()
    }

    /// 激活当前设备上的 `WCSession`。
    func activateIfNeeded() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        if session.delegate !== self {
            session.delegate = self
        }
        if session.activationState == .notActivated {
            session.activate()
        }
    }

    #if os(iOS)
    /// 把一份最新课表快照推送给已配对的 watch。
    func push(snapshot: ScheduleExternalSnapshot) {
        activateIfNeeded()

        let session = WCSession.default
        guard session.isPaired else { return }

        guard let data = try? Self.encoder.encode(snapshot) else { return }
        do {
            try session.updateApplicationContext([
                PayloadKey.snapshotData: data,
            ])
        } catch {}
    }

    /// 从当前共享快照重新推送一次。
    func pushCurrentSnapshotIfAvailable() {
        guard let snapshot = ScheduleExternalSnapshotStore.load() else { return }
        push(snapshot: snapshot)
    }
    #endif

    #if os(watchOS)
    /// 在 watch 端主动请求 iPhone 重新推送最新课表快照。
    ///
    /// 优先走 `sendMessage` 做前台即时往返；如果当前不可达，再退回 `applicationContext` 的 best-effort 同步。
    func requestLatestSnapshotFromPhone() {
        activateIfNeeded()

        let session = WCSession.default
        if session.isReachable {
            session.sendMessageData(
                Self.requestData,
                replyHandler: { data in
                    Task { @MainActor in
                        self.persistSnapshotDataIfPossible(data)
                    }
                },
                errorHandler: { _ in
                    try? session.updateApplicationContext([
                        PayloadKey.requestLatestSnapshot: true,
                    ])
                }
            )
            return
        }

        try? session.updateApplicationContext([
            PayloadKey.requestLatestSnapshot: true,
        ])
    }
    #endif

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        #if os(watchOS)
        if activationState == .activated {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                self.requestLatestSnapshotFromPhone()
            }
        }
        #endif
        _ = error
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        Task { @MainActor in
            session.activate()
        }
    }
    #endif

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        #if os(iOS)
        if messageData == Self.requestData {
            Task { @MainActor in
                if let snapshot = ScheduleExternalSnapshotStore.load(), let data = try? Self.encoder.encode(snapshot) {
                    do {
                        try session.updateApplicationContext([
                            PayloadKey.snapshotData: data,
                        ])
                    } catch {}
                    replyHandler(data)
                    return
                }

                replyHandler(Data())
            }
            return
        }
        #endif

        replyHandler(Data())
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(iOS)
        if let shouldPush = message[PayloadKey.requestLatestSnapshot] as? Bool, shouldPush {
            Task { @MainActor in
                let payload: [String: Any]
                if let snapshot = ScheduleExternalSnapshotStore.load(), let data = try? Self.encoder.encode(snapshot) {
                    do {
                        try session.updateApplicationContext([
                            PayloadKey.snapshotData: data,
                        ])
                    } catch {}
                    payload = [PayloadKey.snapshotData: data]
                } else {
                    payload = [:]
                }
                replyHandler(payload)
            }
            return
        }
        #endif

        replyHandler([:])
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        #if os(iOS)
        if let shouldPush = applicationContext[PayloadKey.requestLatestSnapshot] as? Bool, shouldPush {
            Task { @MainActor in
                self.pushCurrentSnapshotIfAvailable()
            }
            return
        }
        #endif

        guard let data = applicationContext[PayloadKey.snapshotData] as? Data else { return }
        Task { @MainActor in
            self.persistSnapshotDataIfPossible(data)
        }
    }

    @MainActor
    private func persistSnapshotDataIfPossible(_ data: Data) {
        guard let snapshot = try? Self.decoder.decode(ScheduleExternalSnapshot.self, from: data) else { return }
        ScheduleExternalSnapshotStore.save(snapshot)
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

#endif
