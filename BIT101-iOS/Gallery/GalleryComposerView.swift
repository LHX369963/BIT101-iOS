import SwiftUI

/// 一条尚未提交的自定义标签输入行。
///
/// 发帖页允许用户临时追加多条输入框，因此需要一个稳定 `id` 区分每一行。
private struct GalleryCustomTagDraft: Identifiable, Equatable {
    let id = UUID()
    var text = ""
}

/// 原生发帖页。
///
/// 负责标题、正文、标签、声明和可见性设置，并在提交前执行本地敏感词检查。
struct GalleryComposerView: View {
    /// 发帖成功后的回调。
    ///
    /// 调用方通常会在这里刷新当前 feed，并在必要时切回用户刚发帖的分栏。
    let onCreated: @Sendable () async -> Void

    @Environment(\.dismiss) private var dismiss
    /// 帖子标题。
    @State private var title = ""
    /// 帖子正文。
    @State private var text = ""
    /// 已选中的预置标签。
    @State private var selectedTags: [String] = []
    /// 用户手动新增的自定义标签输入行。
    @State private var customTagDrafts: [GalleryCustomTagDraft] = []
    /// 是否匿名发布。
    @State private var anonymous = false
    /// 是否公开出现在信息流中。
    @State private var isPublic = true
    /// 服务端返回的声明列表。
    @State private var claims: [GalleryClaim] = [GalleryClaim(id: 0, text: "无声明")]
    /// 当前选中的声明 ID。
    @State private var selectedClaimID = 0
    /// 是否正在加载声明列表。
    @State private var isLoadingClaims = false
    /// 是否正在提交帖子。
    @State private var isSubmitting = false
    /// 页面级错误提示。
    @State private var alert: LoginAlert?

    /// 发帖接口服务。
    private let service = GalleryService()

    /// 内置的推荐标签。
    ///
    /// 这里沿用 Android/Web 的高频场景标签，目的是让首次发帖时不必完全依赖用户自己输入。
    private static let suggestedTags = [
        "水",
        "活动",
        "表白",
        "树洞",
        "求助",
        "聊天",
        "抽象"
    ]

    /// 发帖表单主体。
    ///
    /// 结构尽量贴近网页端，但改成更适合 iOS 的原生 `Form` 交互。
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("标题", text: $title)
                    TextField("正文", text: $text, axis: .vertical)
                        .lineLimit(6, reservesSpace: true)
                }

                Section("标签") {
                    // 标签入口保留“两排按钮 + 自定义单独追加输入框”的结构，
                    // 这样既能快速选常用标签，也不会把自定义输入塞进同一行里挤压布局。
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(Self.suggestedTags, id: \.self) { tag in
                            Button {
                                toggleTag(tag)
                            } label: {
                                Text(tag)
                                    .font(.footnote.weight(.medium))
                                    .foregroundStyle(selectedTags.contains(tag) ? Color.white : Color.accentColor)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity)
                                    .background(
                                        selectedTags.contains(tag) ? Color.accentColor : Color.accentColor.opacity(0.12),
                                        in: Capsule()
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        Button {
                            addCustomTagDraft()
                        } label: {
                            Text("自定义")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity)
                                .background(
                                    Color.accentColor.opacity(0.12),
                                    in: Capsule()
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    if !customTagDrafts.isEmpty {
                        // 每条自定义标签都用单独输入行，避免旧版“统一输入框 + 行内删除”
                        // 在移动端上编辑体验混乱。
                        ForEach($customTagDrafts) { $draft in
                            HStack {
                                TextField("自定义标签", text: $draft.text)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()

                                Button {
                                    removeCustomTagDraft(id: draft.id)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.secondary)
                                        .font(.title3)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                Section("发布设置") {
                    // 声明列表由服务端控制，便于后续和网页端保持一致。
                    Picker("声明", selection: $selectedClaimID) {
                        ForEach(claims) { claim in
                            Text(claim.text).tag(claim.id)
                        }
                    }

                    Toggle("匿名发布", isOn: $anonymous)
                    Toggle("公开显示", isOn: $isPublic)
                }
            }
            .navigationTitle("发布帖子")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isSubmitting ? "发布中" : "发布") {
                        Task { await submit() }
                    }
                    .disabled(isSubmitting)
                }
            }
            .task { await loadClaimsIfNeeded() }
            .alert(item: $alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("知道了")))
            }
        }
    }

    /// 首次进入时拉取可选 claim 列表。
    ///
    /// 这里故意吞掉接口失败：声明列表加载失败不应该阻止用户发帖，
    /// 页面会继续使用默认的“无声明”占位。
    private func loadClaimsIfNeeded() async {
        guard !isLoadingClaims else { return }
        isLoadingClaims = true
        defer { isLoadingClaims = false }

        do {
            let fetchedClaims = try await service.fetchClaims()
            if !fetchedClaims.isEmpty {
                claims = fetchedClaims.sorted { $0.id < $1.id }
                if !claims.contains(where: { $0.id == selectedClaimID }) {
                    selectedClaimID = claims.first?.id ?? 0
                }
            }
        } catch {
            if selectedClaimID == 0 {
                selectedClaimID = claims.first?.id ?? 0
            }
        }
    }

    /// 在本地校验通过后提交帖子。
    ///
    /// 提交顺序刻意设计为：
    /// 1. 先做纯本地校验，尽量在发请求前拦掉明显错误。
    /// 2. 再进入提交态，防止重复点击。
    /// 3. 服务端成功后先通知调用方刷新，再关闭当前页面。
    private func submit() async {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = combinedTags()

        guard !trimmedTitle.isEmpty else {
            alert = LoginAlert(title: "发布失败", message: "标题不能为空。")
            return
        }
        guard !trimmedText.isEmpty else {
            alert = LoginAlert(title: "发布失败", message: "正文不能为空。")
            return
        }
        guard tags.count >= 2 else {
            alert = LoginAlert(title: "发布失败", message: "请至少添加 2 个标签。")
            return
        }
        if let message = CommunityModeration.validateDraft(title: trimmedTitle, text: trimmedText, tags: tags) {
            alert = LoginAlert(title: "内容不合规", message: message)
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            _ = try await service.createPoster(
                title: trimmedTitle,
                text: trimmedText,
                anonymous: anonymous,
                tags: tags,
                claimID: selectedClaimID,
                isPublic: isPublic
            )
            await onCreated()
            dismiss()
        } catch {
            alert = LoginAlert(title: "发布失败", message: error.localizedDescription)
        }
    }

    /// 切换预置标签的选中状态。
    ///
    /// 预置标签和自定义标签是两套来源，因此这里只处理预置集合本身，不直接碰自定义输入行。
    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            addTag(tag)
        }
    }

    /// 添加一个新的预置标签，同时负责去重和数量上限。
    ///
    /// 数量上限与最终提交限制保持一致，这样用户在编辑阶段就能感知规则，
    /// 不必等到点击“发布”时才发现标签超限。
    private func addTag(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !selectedTags.contains(normalized) else { return }
        guard selectedTags.count < 10 else { return }
        selectedTags.append(normalized)
    }

    /// 追加一条新的自定义标签输入行。
    ///
    /// 这里用“预置标签数 + 输入行数”共同限制上限，是为了避免用户先连点十几次
    /// “自定义”，最后再发现无法提交。
    private func addCustomTagDraft() {
        guard selectedTags.count + customTagDrafts.count < 10 else { return }
        customTagDrafts.append(GalleryCustomTagDraft())
    }

    /// 删除指定的自定义标签输入行。
    private func removeCustomTagDraft(id: GalleryCustomTagDraft.ID) {
        customTagDrafts.removeAll { $0.id == id }
    }

    /// 把预置标签和自定义标签合并成最终提交数组。
    ///
    /// 这里会统一裁剪空白、去重并限制最多 10 个标签。
    private func combinedTags() -> [String] {
        let customTags = customTagDrafts
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var result: [String] = []

        for tag in selectedTags + customTags {
            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            result.append(tag)
        }

        return Array(result.prefix(10))
    }
}
