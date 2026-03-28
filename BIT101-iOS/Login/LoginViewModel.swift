//
//  LoginViewModel.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import Combine
import Foundation

/// 登录页当前展示的顶层状态。
enum LoginScreenState: Equatable {
    case signedOut
    case signedIn(studentID: String)
}

/// 登录页统一使用的警告模型。
struct LoginAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 登录流程状态机。
///
/// 负责：
/// 1. 启动时恢复本地登录态
/// 2. 驱动登录按钮的提交状态
/// 3. 管理退出登录后的界面回退
final class LoginViewModel: ObservableObject {
    @Published var studentID: String
    @Published var password = ""
    @Published var isPasswordVisible = false
    @Published private(set) var screenState: LoginScreenState
    @Published private(set) var isSubmitting = false
    @Published var alert: LoginAlert?

    private let service: LoginService
    private var hasBootstrapped = false

    init(service: LoginService = LoginService()) {
        self.service = service
        let savedStudentID = service.savedStudentID
        studentID = savedStudentID
        password = service.savedPassword
        screenState = service.hasCachedSession ? .signedIn(studentID: savedStudentID) : .signedOut
    }

    /// 当前输入是否满足提交条件。
    var canSubmit: Bool {
        !studentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !password.isEmpty &&
            !isSubmitting
    }

    /// 只在首次进入时检查一次登录态，避免视图重建时重复发请求。
    ///
    /// 启动时不再阻塞首屏；如果本地有会话，就先展示主界面，再在后台校验。
    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        guard service.hasCachedSession else {
            screenState = .signedOut
            return
        }

        do {
            if let studentID = try await service.checkLogin() {
                self.studentID = studentID
                password = ""
                screenState = .signedIn(studentID: studentID)
            } else {
                self.studentID = service.savedStudentID
                password = service.savedPassword
                screenState = .signedOut
            }
        } catch {
            studentID = service.savedStudentID
            password = service.savedPassword

            // 体验优先：启动校验失败时不阻塞、不弹框，保留当前界面，后续由真实业务请求决定是否提示用户。
            if case .signedIn = screenState {
                return
            }

            screenState = .signedOut
        }
    }

    func login() async {
        let trimmedStudentID = studentID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedStudentID.isEmpty else {
            alert = LoginAlert(title: "学号不能为空", message: "请输入学校统一身份认证使用的学号。")
            return
        }

        guard !password.isEmpty else {
            alert = LoginAlert(title: "密码不能为空", message: "请输入学校统一身份认证使用的密码。")
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            let studentID = try await service.login(studentID: trimmedStudentID, password: password)
            self.studentID = studentID
            self.password = ""
            screenState = .signedIn(studentID: studentID)
        } catch {
            alert = LoginAlert(
                title: "登录失败",
                message: error.localizedDescription
            )
            screenState = .signedOut
        }
    }

    /// 退出当前账号，并回退到登录页。
    func logout() {
        service.logout()
        studentID = service.savedStudentID
        password = service.savedPassword
        screenState = .signedOut
    }
}
