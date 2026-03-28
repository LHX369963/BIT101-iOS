//
//  CampusMapScreen.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// 地图页用到的本地偏好键。
private enum MapPreferenceKey {
    static let selectedCampus = "map.selectedCampus"
}

/// 地图页支持的校区预设。
private enum CampusPreset: String, CaseIterable, Identifiable {
    case liangxiang
    case zhongguancun

    /// 供切换按钮绑定的稳定标识。
    var id: String { rawValue }

    /// 右下角校区切换按钮上的短标签。
    var shortLabel: String {
        switch self {
        case .liangxiang:
            return "乡"
        case .zhongguancun:
            return "村"
        }
    }

    /// 当前校区在地图上的中心点。
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case .liangxiang:
            // 预先校准到当前系统地图坐标系，避免每次进入地图都再做转换。
            return CLLocationCoordinate2D(latitude: 39.73027614839699, longitude: 116.17276949062236)
        case .zhongguancun:
            return CLLocationCoordinate2D(latitude: 39.95966806175981, longitude: 116.31597988552478)
        }
    }

    /// 当前校区默认聚焦半径。
    var distance: CLLocationDistance {
        switch self {
        case .liangxiang:
            return 4500
        case .zhongguancun:
            return 3200
        }
    }
}

/// SwiftUI 发给 `MKMapView` 的“聚焦请求”。
///
/// 额外带一个随机 `id`，用于强制区分两次落点相同但需要重新动画聚焦的操作。
private enum MapFocusDestination: Equatable {
    case preset(CampusPreset)

    /// 目标落点坐标。
    var coordinate: CLLocationCoordinate2D {
        switch self {
        case let .preset(preset):
            return preset.coordinate
        }
    }

    /// 目标落点聚焦半径。
    var distance: CLLocationDistance {
        switch self {
        case let .preset(preset):
            return preset.distance
        }
    }
}

/// 一次地图聚焦请求的包装结构。
private struct MapFocusRequest: Equatable {
    let id = UUID()
    let destination: MapFocusDestination
    let animated: Bool
}

/// 地图页提示弹窗模型。
private struct MapNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 地图页定位控制器。
///
/// 统一封装定位授权状态、请求当前位置和错误提示，避免视图层直接跟 `CLLocationManager` 打交道。
@MainActor
private final class CampusLocationController: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published var notice: MapNotice?

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// 当前定位权限是否足够直接请求位置。
    var isAuthorized: Bool {
        authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse
    }

    /// 根据当前授权状态发起定位或引导用户授权。
    func locateUser() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.requestLocation()
        case .denied, .restricted:
            notice = MapNotice(
                title: "定位不可用",
                message: "请在系统设置中允许 BIT101 使用定位后，再尝试回到我的位置。"
            )
        @unknown default:
            notice = MapNotice(
                title: "定位不可用",
                message: "当前定位状态无法识别。"
            )
        }
    }

    /// 当定位权限变化时，必要时自动继续完成一次挂起的定位请求。
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            locateUser()
        }
    }

    /// 位置回调当前只作为契约保留，聚焦动作交给地图桥接层自己读取系统位置。
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // `requestLocation()` 依赖这个 delegate 回调存在；这里不再向外发布坐标，只保留契约。
    }

    /// 过滤掉常见的瞬时错误，只把真正需要用户感知的问题弹出来。
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        if nsError.domain == kCLErrorDomain,
           let code = CLError.Code(rawValue: nsError.code),
           code == .locationUnknown {
            return
        }

        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            return
        }

        notice = MapNotice(
            title: "定位失败",
            message: error.localizedDescription
        )
    }
}

/// 校园地图主页面。
///
/// 使用 MapKit 承载自定义瓦片图层，并提供与 Android 版本一致的校区跳转入口。
struct CampusMapScreen: View {
    @AppStorage(MapPreferenceKey.selectedCampus) private var selectedCampusID = CampusPreset.liangxiang.rawValue
    @StateObject private var locationController = CampusLocationController()
    @State private var focusRequest = MapFocusRequest(destination: .preset(.liangxiang), animated: false)
    @State private var centerOnUserRequestID: UUID?
    @State private var pendingCenterOnUserAfterAuthorization = false
    @State private var hasRestoredStoredCampus = false

    /// 地图主页主体。
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            CampusTileMapView(
                focusRequest: focusRequest,
                centerOnUserRequestID: centerOnUserRequestID,
                scale: 1
            )
            .ignoresSafeArea(edges: [.top, .bottom])

            VStack(alignment: .trailing, spacing: 10) {
                FloatingMapButton(systemImage: locationController.isAuthorized ? "location.fill" : "location") {
                    centerOnUser()
                }

                ForEach(CampusPreset.allCases) { preset in
                    FloatingMapLabelButton(
                        label: preset.shortLabel,
                        isSelected: preset == selectedCampus
                    ) {
                        jump(to: preset, animated: false)
                    }
                }
            }
            .padding(.trailing, 10)
            .padding(.bottom, 20)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            guard !hasRestoredStoredCampus else { return }
            hasRestoredStoredCampus = true
            focusRequest = MapFocusRequest(destination: .preset(selectedCampus), animated: false)
        }
        .onReceive(locationController.$authorizationStatus.dropFirst()) { status in
            guard pendingCenterOnUserAfterAuthorization else { return }

            if status == .authorizedAlways || status == .authorizedWhenInUse {
                pendingCenterOnUserAfterAuthorization = false
                centerOnUserRequestID = UUID()
            } else if status != .notDetermined {
                pendingCenterOnUserAfterAuthorization = false
            }
        }
        .alert(item: $locationController.notice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    /// 切换到指定校区并更新本地持久化。
    private func jump(to preset: CampusPreset, animated: Bool) {
        selectedCampusID = preset.rawValue
        focusRequest = MapFocusRequest(destination: .preset(preset), animated: animated)
    }

    /// 聚焦到当前位置，必要时先触发授权流程。
    private func centerOnUser() {
        if locationController.isAuthorized {
            pendingCenterOnUserAfterAuthorization = false
            locationController.locateUser()
            centerOnUserRequestID = UUID()
        } else {
            pendingCenterOnUserAfterAuthorization = true
            locationController.locateUser()
        }
    }

    /// 当前持久化选中的校区。
    private var selectedCampus: CampusPreset {
        CampusPreset(rawValue: selectedCampusID) ?? .liangxiang
    }
}

/// 圆形悬浮按钮的统一样式。
private struct FloatingMapButton: View {
    let systemImage: String
    let action: () -> Void

    /// 通用圆形按钮主体。
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 42, height: 42)
        }
        .buttonStyle(.plain)
        .background(.ultraThinMaterial, in: Circle())
    }
}

/// 校区快捷切换按钮。
private struct FloatingMapLabelButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    /// 校区切换按钮主体。
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .frame(width: 42, height: 42)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor : Color.clear,
            in: Circle()
        )
        .background(.ultraThinMaterial, in: Circle())
    }
}

/// MapKit 与 SwiftUI 之间的桥接层。
///
/// 瓦片地图、相机定位和 overlay renderer 都在这里落地。
private struct CampusTileMapView: UIViewRepresentable {
    let focusRequest: MapFocusRequest
    let centerOnUserRequestID: UUID?
    let scale: Double

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.mapType = .standard
        mapView.showsCompass = true
        mapView.showsScale = true
        mapView.showsUserLocation = true
        mapView.pointOfInterestFilter = .excludingAll
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = true

        applyFocus(to: mapView, animated: false, scale: scale)
        context.coordinator.lastFocusID = focusRequest.id
        context.coordinator.lastScale = scale
        suppressSystemAttribution(in: mapView)
        DispatchQueue.main.async {
            suppressSystemAttribution(in: mapView)
        }

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if context.coordinator.lastCenterOnUserRequestID != centerOnUserRequestID,
           let centerOnUserRequestID {
            context.coordinator.centerOnUser(in: mapView, requestID: centerOnUserRequestID)
        }

        if context.coordinator.lastFocusID != focusRequest.id {
            applyFocus(to: mapView, animated: focusRequest.animated, scale: scale)
            context.coordinator.lastFocusID = focusRequest.id
            context.coordinator.lastScale = scale
            return
        }

        guard context.coordinator.lastScale != scale else {
            DispatchQueue.main.async {
                suppressSystemAttribution(in: mapView)
            }
            return
        }

        applyScale(to: mapView, from: context.coordinator.lastScale ?? scale, to: scale)
        context.coordinator.lastScale = scale
        DispatchQueue.main.async {
            suppressSystemAttribution(in: mapView)
        }
    }

    private func applyFocus(to mapView: MKMapView, animated: Bool, scale: Double) {
        mapView.setUserTrackingMode(.none, animated: false)
        let camera = MKMapCamera(
            lookingAtCenter: focusRequest.destination.coordinate,
            fromDistance: focusRequest.destination.distance / scale,
            pitch: 0,
            heading: 0
        )
        mapView.setCamera(camera, animated: animated)
    }

    private func applyScale(to mapView: MKMapView, from oldScale: Double, to newScale: Double) {
        let currentDistance = max(mapView.camera.centerCoordinateDistance, 1)
        let newDistance = currentDistance * oldScale / newScale
        let camera = MKMapCamera(
            lookingAtCenter: mapView.centerCoordinate,
            fromDistance: newDistance,
            pitch: mapView.camera.pitch,
            heading: mapView.camera.heading
        )
        mapView.setCamera(camera, animated: false)
    }

    /// 压掉 MapKit 左下角默认的英文 attribution / legal label。
    ///
    /// 当前页面已经有明确的地图来源标识，这里只做最小隐藏，不影响地图本身交互。
    private func suppressSystemAttribution(in mapView: MKMapView) {
        hideAttributionViews(in: mapView)
    }

    private func hideAttributionViews(in root: UIView) {
        for subview in root.subviews {
            let className = NSStringFromClass(type(of: subview))
            let shouldHideByClass = className.contains("Attribution") || className.contains("Legal")
            let shouldHideByText = (subview as? UILabel).map { label in
                let text = label.text ?? ""
                return text.localizedCaseInsensitiveContains("map data")
                    || text.localizedCaseInsensitiveContains("legal")
                    || text.localizedCaseInsensitiveContains("autonavi")
            } ?? false

            if shouldHideByClass || shouldHideByText {
                subview.isHidden = true
                subview.alpha = 0
                subview.isUserInteractionEnabled = false
            }

            hideAttributionViews(in: subview)
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var lastFocusID: UUID?
        var lastScale: Double?
        var lastCenterOnUserRequestID: UUID?
        private var pendingCenterOnUserRequestID: UUID?

        func centerOnUser(in mapView: MKMapView, requestID: UUID) {
            if let coordinate = validUserCoordinate(from: mapView) {
                mapView.setUserTrackingMode(.none, animated: false)
                mapView.setCenter(coordinate, animated: false)
                lastCenterOnUserRequestID = requestID
                pendingCenterOnUserRequestID = nil
                return
            }

            pendingCenterOnUserRequestID = requestID
            mapView.setUserTrackingMode(.follow, animated: false)
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard let requestID = pendingCenterOnUserRequestID,
                  let coordinate = userLocation.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else {
                return
            }

            mapView.setCenter(coordinate, animated: false)
            mapView.setUserTrackingMode(.none, animated: false)
            lastCenterOnUserRequestID = requestID
            pendingCenterOnUserRequestID = nil
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let tileOverlay = overlay as? MKTileOverlay else {
                return MKOverlayRenderer(overlay: overlay)
            }

            return MKTileOverlayRenderer(tileOverlay: tileOverlay)
        }

        private func validUserCoordinate(from mapView: MKMapView) -> CLLocationCoordinate2D? {
            guard let location = mapView.userLocation.location else {
                return nil
            }

            let coordinate = location.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else {
                return nil
            }

            return coordinate
        }
    }
}
