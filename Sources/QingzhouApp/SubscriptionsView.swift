import SwiftUI
import QingzhouCore

public struct SubscriptionsView: View {
    @Bindable var state: AppState
    /// 跟随 App 语言设置的 locale（根视图注入），日期格式化用
    @Environment(\.locale) private var locale
    @State private var newName: String = ""
    @State private var newURL: String = ""
    @State private var addError: String?
    @State private var refreshingId: UUID?
    @State private var isRefreshingAll = false
    @State private var qrShareSub: Subscription?
    #if os(iOS)
    @State private var showScanner: Bool = false
    #endif

    public init(state: AppState) { self.state = state }

    public var body: some View {
        List {
            Section("添加订阅") {
                TextField("名称（可选）", text: $newName)
                TextField("URL", text: $newURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.body.monospaced())
                HStack {
                    Button {
                        Task { await addAndRefresh() }
                    } label: {
                        if refreshingId != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("添加并刷新", systemImage: "plus.circle")
                        }
                    }
                    .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)

                    #if os(iOS)
                    Spacer()
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫码", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.borderless)
                    #endif
                }
                if let err = addError {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }

            if state.subscriptions.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("暂无订阅", systemImage: "tray").foregroundStyle(.secondary)
                        Text("粘贴一个订阅 URL，添加并刷新后会自动解析里面的节点。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("已有订阅") {
                ForEach(state.subscriptions) { sub in
                    subscriptionRow(sub)
                }
            }
        }
        .navigationTitle("订阅")
        // iOS 下拉刷新；macOS List 没有下拉手势，靠工具栏「全部刷新」按钮
        .refreshable { await refreshAll() }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshAll() }
                } label: {
                    if isRefreshingAll {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("全部刷新", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshingAll || refreshingId != nil || state.subscriptions.isEmpty)
                .help("依次刷新所有订阅")
            }
        }
        .sheet(item: $qrShareSub) { sub in qrShareSheet(sub) }
        #if os(iOS)
        .sheet(isPresented: $showScanner) { scannerSheet }
        #endif
    }

    #if os(iOS)
    private var scannerSheet: some View {
        ZStack(alignment: .bottom) {
            QRCodeScannerView { value in
                // 扫到的内容直接填到 URL 输入框 —— 让用户先看一眼 / 改个名字再 tap"添加并刷新"，
                // 避免乱码 / 误扫导致直接落库。
                newURL = value
                showScanner = false
            }
            .ignoresSafeArea()
            HStack {
                Button("取消") { showScanner = false }
                    .padding().background(.regularMaterial).clipShape(Capsule())
                Spacer()
            }
            .padding()
        }
    }
    #endif

    private func subscriptionRow(_ sub: Subscription) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sub.name).font(.headline)
                Spacer()
                if refreshingId == sub.id {
                    ProgressView().controlSize(.small)
                }
            }
            Text(sub.url.absoluteString)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 12) {
                Text("节点 \(sub.nodeCount)")
                if let upd = sub.lastUpdatedAt {
                    Text("· \(upd.formatted(.relative(presentation: .named).locale(locale)))")
                }
                Spacer()
            }
            .font(.caption2).foregroundStyle(.secondary)
            if let u = sub.usedBytes, let t = sub.totalBytes {
                ProgressView(value: Double(u), total: Double(max(t, 1)))
                Text("\(ByteFormatter.format(u)) / \(ByteFormatter.format(t))")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            if let exp = sub.expiresAt {
                Text("到期：\(exp.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let err = state.subscriptionErrors[sub.id] {
                Text("⚠️ \(err)")
                    .font(.caption2).foregroundStyle(.red).lineLimit(2)
            }
            HStack(spacing: 14) {
                Button {
                    Task {
                        refreshingId = sub.id
                        await state.refreshSubscription(sub)
                        refreshingId = nil
                    }
                } label: {
                    compactLabel("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(refreshingId != nil)

                Button {
                    qrShareSub = sub
                } label: {
                    compactLabel("分享", systemImage: "qrcode")
                }
                .buttonStyle(.borderless)

                #if os(macOS)
                Button {
                    copyToPasteboard(sub.url.absoluteString)
                } label: {
                    compactLabel("复制 URL", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                #endif

                Spacer()

                Button(role: .destructive) {
                    state.removeSubscription(sub)
                } label: {
                    compactLabel("删除", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    private func qrShareSheet(_ sub: Subscription) -> some View {
        VStack(spacing: 14) {
            Text(sub.name).font(.headline)
            QRCodeView(text: sub.url.absoluteString, size: 240)
            Text(sub.url.absoluteString)
                .font(.caption2.monospaced()).lineLimit(2).truncationMode(.middle)
                .textSelection(.enabled).foregroundStyle(.secondary).padding(.horizontal)
            HStack {
                Button("复制 URL") { copyToPasteboard(sub.url.absoluteString) }
                Button("完成") { qrShareSub = nil }
            }
        }
        .padding()
        .frame(minWidth: 320, minHeight: 360)
    }

    /// 逐个刷新全部订阅（串行，避免并发打爆网络/机场限频）。
    /// 逐条设置 refreshingId，让正在刷的那行显示转圈；结束后 toast 汇报结果。
    private func refreshAll() async {
        guard !isRefreshingAll, refreshingId == nil, !state.subscriptions.isEmpty else { return }
        isRefreshingAll = true
        defer {
            refreshingId = nil
            isRefreshingAll = false
        }
        let subs = state.subscriptions
        for sub in subs {
            refreshingId = sub.id
            await state.refreshSubscription(sub)
        }
        let failed = subs.filter { state.subscriptionErrors[$0.id] != nil }.count
        if failed == 0 {
            state.showToast(L("已刷新 \(subs.count) 个订阅"))
        } else {
            state.showToast(L("刷新完成：\(subs.count - failed) 成功，\(failed) 失败"))
        }
    }

    private func addAndRefresh() async {
        let trimmedURL = newURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmedURL), url.scheme?.hasPrefix("http") == true else {
            addError = L("URL 无效（需要以 http:// 或 https:// 开头）"); return
        }
        addError = nil
        let displayName = newName.isEmpty ? (url.host ?? "Subscription") : newName
        refreshingId = UUID()   // 占位让按钮转圈
        await state.addSubscription(name: displayName, url: url)
        newName = ""
        newURL = ""
        refreshingId = nil
    }

    private func copyToPasteboard(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    /// 比 `Label` 紧凑：图标和文字间距固定 4 pt，避免 borderless Button 里默认布局把它俩拉得很开。
    private func compactLabel(_ text: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text)
        }
    }
}

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
