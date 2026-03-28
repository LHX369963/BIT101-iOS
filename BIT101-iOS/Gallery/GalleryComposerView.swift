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
    let onCreated: @Sendable () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    @State private var selectedTags: [String] = []
    @State private var customTagDrafts: [GalleryCustomTagDraft] = []
    @State private var anonymous = false
    @State private var isPublic = true
    @State private var claims: [GalleryClaim] = [GalleryClaim(id: 0, text: "无声明")]
    @State private var selectedClaimID = 0
    @State private var isLoadingClaims = false
    @State private var isSubmitting = false
    @State private var alert: LoginAlert?

    private let service = GalleryService()

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
    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            removeTag(tag)
        } else {
            addTag(tag)
        }
    }

    /// 删除一个已选中的预置标签。
    private func removeTag(_ tag: String) {
        selectedTags.removeAll { $0 == tag }
    }

    /// 添加一个新的预置标签，同时负责去重和数量上限。
    private func addTag(_ tag: String) {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !selectedTags.contains(normalized) else { return }
        guard selectedTags.count < 10 else { return }
        selectedTags.append(normalized)
    }

    /// 追加一条新的自定义标签输入行。
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
