import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct FilesView: View {
    let pairingSessionID: UUID
    var returnHome: () -> Void = {}
    private var isCurrentPairing: Bool { model.pairingSessionID == pairingSessionID }
    @EnvironmentObject private var model: AppModel
    @State private var currentPath = ""
    @State private var entries: [RemoteFile] = []
    @State private var isLoading = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var operationMessage: String?
    @State private var fileToDelete: RemoteFile?
    @State private var showingDeleteConfirmation = false
    @State private var showingImporter = false
    @State private var showingFolderPrompt = false
    @State private var folderName = ""
    @State private var downloadedFile: URL?
    @State private var showingShareSheet = false

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            if let errorMessage {
                errorBanner(errorMessage)
            }
            if let operationMessage {
                Text(operationMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(MacLinkTheme.lime)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            if isLoading && entries.isEmpty {
                Spacer()
                ProgressView("讀取 Mac 檔案…").tint(MacLinkTheme.lime).foregroundStyle(MacLinkTheme.muted)
                Spacer()
            } else if entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(entries) { entry in
                        FileRow(entry: entry) {
                            if entry.isDirectory { changePath(entry.path) }
                            else { Task { await download(entry) } }
                        } onDelete: {
                            fileToDelete = entry
                            showingDeleteConfirmation = true
                        }
                        .listRowBackground(MacLinkTheme.panel)
                        .listRowSeparatorTint(MacLinkTheme.line)
                    }
                }
                .scrollContentBackground(.hidden)
                .listStyle(.plain)
                .refreshable { await loadFiles() }
            }
        }
        .background(MacLinkTheme.background.ignoresSafeArea())
        .navigationTitle("我的檔案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if currentPath.isEmpty { returnHome() } else { goUp() }
                } label: {
                    Label(currentPath.isEmpty ? "回首頁" : "上一層", systemImage: "chevron.left")
                }
                .accessibilityLabel(currentPath.isEmpty ? "返回首頁" : "返回上一層資料夾")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { showingFolderPrompt = true } label: { Label("新增資料夾", systemImage: "folder.badge.plus") }
                    Button { showingImporter = true } label: { Label("從 iPhone 上傳", systemImage: "square.and.arrow.up") }
                    if !currentPath.isEmpty {
                        Button { goUp() } label: { Label("上一層", systemImage: "arrow.up") }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill").foregroundStyle(MacLinkTheme.lime)
                }
                .disabled(!model.isPaired || isWorking)
            }
        }
        .task(id: "\(model.isPaired)-\(currentPath)") { await loadFiles() }
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url): Task { await upload(url) }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("新增資料夾", isPresented: $showingFolderPrompt) {
            TextField("資料夾名稱", text: $folderName)
            Button("建立") { Task { await createFolder() } }
            Button("取消", role: .cancel) { folderName = "" }
        } message: {
            Text(currentPath.isEmpty ? "會建立在你的使用者資料夾中。" : "會建立在目前資料夾中。")
        }
        .confirmationDialog("將這個項目移到 Mac 垃圾桶？", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("移到垃圾桶：\(fileToDelete?.name ?? "項目")", role: .destructive) { Task { await deleteSelected() } }
            Button("取消", role: .cancel) { fileToDelete = nil }
        } message: {
            Text("可在 Mac 垃圾桶中還原。這個確認只適用於所顯示的項目。")
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: cleanupDownloadedFile) {
            if let downloadedFile { ShareSheet(activityItems: [downloadedFile]) }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Image(systemName: "house.fill").foregroundStyle(MacLinkTheme.lime)
            Text(currentPath.isEmpty ? "使用者資料夾" : currentPath)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text("\(entries.count) 項")
                .font(.system(size: 11))
                .foregroundStyle(MacLinkTheme.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(MacLinkTheme.panel)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder").font(.system(size: 38)).foregroundStyle(MacLinkTheme.lime)
            Text(model.isPaired ? (errorMessage == nil ? "這個資料夾目前是空的" : "無法讀取這個資料夾") : "先配對你的 Mac")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            Text(errorMessage == nil ? "瀏覽和傳檔只會在你點選時進行。" : "下拉重新讀取，或返回上一層。")
                .font(.system(size: 12)).foregroundStyle(MacLinkTheme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 12))
            .foregroundStyle(Color.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.1))
    }

    private func loadFiles() async {
        guard isCurrentPairing, !Task.isCancelled else { return }
        guard model.isPaired else { entries = []; return }
        let requestedPath = currentPath
        isLoading = true
        defer { isLoading = false }
        do {
            let listing = try await model.listFiles(path: requestedPath)
            guard isCurrentPairing && !Task.isCancelled && currentPath == requestedPath else { return }
            entries = listing.entries
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            if isCurrentPairing && !Task.isCancelled && currentPath == requestedPath { errorMessage = error.localizedDescription; entries = [] }
        }
    }

    private func goUp() {
        changePath((currentPath as NSString).deletingLastPathComponent)
    }

    private func changePath(_ path: String) {
        entries = []
        errorMessage = nil
        operationMessage = nil
        currentPath = path
    }

    private func upload(_ url: URL) async {
        guard isCurrentPairing, !Task.isCancelled else { return }
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        isWorking = true
        defer { isWorking = false }
        do {
            if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               size > 40 * 1024 * 1024 {
                throw ClientError.server("檔案超過 40 MB，請在 Mac 上直接操作。")
            }
            let data = try Data(contentsOf: url)
            let destination = join(currentPath, url.lastPathComponent)
            _ = try await model.upload(data: data, path: destination)
            guard isCurrentPairing, !Task.isCancelled else { return }
            operationMessage = "已上傳 \(url.lastPathComponent)"
            await loadFiles()
        } catch {
            guard isCurrentPairing, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func download(_ file: RemoteFile) async {
        guard isCurrentPairing, !Task.isCancelled else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await model.download(path: file.path)
            guard isCurrentPairing, !Task.isCancelled else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacLink-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let target = folder.appendingPathComponent(file.name)
            try data.write(to: target, options: .atomic)
            downloadedFile = target
            showingShareSheet = true
        } catch {
            guard isCurrentPairing, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func createFolder() async {
        guard isCurrentPairing, !Task.isCancelled else { return }
        let trimmed = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard trimmed != ".", trimmed != "..", !trimmed.contains("/"), !trimmed.contains("\\") else {
            errorMessage = "資料夾名稱不能包含路徑符號。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.createFolder(path: join(currentPath, trimmed))
            guard isCurrentPairing, !Task.isCancelled else { return }
            folderName = ""
            operationMessage = "資料夾已建立"
            await loadFiles()
        } catch {
            guard isCurrentPairing, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelected() async {
        guard isCurrentPairing, !Task.isCancelled else { return }
        guard let fileToDelete else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await model.delete(path: fileToDelete.path)
            guard isCurrentPairing, !Task.isCancelled else { return }
            self.fileToDelete = nil
            operationMessage = "已移到 Mac 垃圾桶"
            await loadFiles()
        } catch {
            guard isCurrentPairing, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func join(_ parent: String, _ child: String) -> String {
        parent.isEmpty ? child : "\(parent)/\(child)"
    }

    private func cleanupDownloadedFile() {
        guard let downloadedFile else { return }
        try? FileManager.default.removeItem(at: downloadedFile.deletingLastPathComponent())
        self.downloadedFile = nil
    }
}

private struct FileRow: View {
    let entry: RemoteFile
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(entry.isDirectory ? MacLinkTheme.lime : Color(red: 0.56, green: 0.77, blue: 1))
                .frame(width: 30)
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                    Text(entry.isDirectory ? "資料夾" : ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(MacLinkTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(MacLinkTheme.muted)
                    .frame(width: 34, height: 34)
                    .background(MacLinkTheme.panelRaised, in: Circle())
            }
            .accessibilityLabel("刪除 \(entry.name)")
        }
        .padding(.vertical, 5)
    }

    private var iconName: String {
        switch URL(fileURLWithPath: entry.name).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic": "photo"
        case "pdf": "doc.richtext"
        case "zip", "gz", "dmg": "archivebox"
        case "txt", "md", "rtf": "doc.text"
        default: "doc"
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
