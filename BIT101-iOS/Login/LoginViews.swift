//
//  LoginViews.swift
//  BIT101-iOS
//
//  Created by Codex on 2026-03-24.
//

import SwiftUI

// MARK: - Login Root

/// 登录模块根视图。
///
/// 根据 `LoginViewModel` 的状态，在登录表单和主应用壳层之间切换。
/// 启动时不会再用“检查中”页面阻塞首屏，登录态校验会在后台完成。
struct LoginRootView: View {
    @StateObject private var viewModel = LoginViewModel()

    /// 登录模块根视图主体。
    var body: some View {
        Group {
            switch viewModel.screenState {
            case .signedOut:
                NavigationStack {
                    LoginFormView(viewModel: viewModel)
                }
            case let .signedIn(studentID):
                AppShellView(studentID: studentID, onLogout: viewModel.logout)
            }
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
}

/// 统一身份认证登录表单。
///
/// 内容结构尽量向 Android 版本对齐，但仍然只使用 SwiftUI 原生组件。
private struct LoginFormView: View {
    @ObservedObject var viewModel: LoginViewModel
    @FocusState private var focusedField: LoginField?

    /// 登录表单主体。
    var body: some View {
        Form {
            Section {
                TextField("学号", text: $viewModel.studentID)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .studentID)
                    .onSubmit {
                        focusedField = .password
                    }

                Group {
                    SecureField("密码", text: $viewModel.password)
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit {
                    Task { await viewModel.login() }
                }
            }

            Section {
                Button {
                    focusedField = nil
                    Task { await viewModel.login() }
                } label: {
                    HStack {
                        Spacer()
                        if viewModel.isSubmitting {
                            ProgressView()
                        } else {
                            Text("登录")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(!viewModel.canSubmit)
            } footer: {
                VStack(alignment: .leading, spacing: 10) {
                    Text("使用学校统一身份认证账号密码登录。若未注册过 BIT101 账号，将自动完成注册；密码仅会经不可逆加密后传输。")
                    Text("本 App 尚处在开发中，不保证所有功能始终可用；如遇到问题，请联系 systemd@linux.do。开发者不对使用过程中造成的损失负责。")
                    Text("本 App 为了完成 Apple 的合规性审查，加入了一些风味元素，功能与安卓版有所差异。")
                }
            }
        }
        .navigationTitle("登录")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// 登录表单里的焦点路由枚举。
private enum LoginField: Hashable {
    case studentID
    case password
}
