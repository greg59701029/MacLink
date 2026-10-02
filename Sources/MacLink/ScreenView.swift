import SwiftUI
import UIKit

struct ScreenView: View {
    let pairingSessionID: UUID
    let isSelected: Bool
    private var isCurrentPairing: Bool { model.pairingSessionID == pairingSessionID }
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var screenshot: UIImage?
    @State private var isLoading = false
    @State private var isFetching = false
    @State private var keyboardText = ""
    @State private var statusText: String?
    @State private var screenErrorText: String?
    @State private var pointerMode: PointerMode = .click
    @State private var zoom: CGFloat = 1
    @State private var isLive = true
    @FocusState private var keyboardFocused: Bool

    private enum PointerMode: String, CaseIterable, Identifiable {
        case click, doubleClick, rightClick, drag
        var id: Self { self }
        var title: String {
            switch self {
            case .click: "點擊"
            case .doubleClick: "雙擊"
            case .rightClick: "右鍵"
            case .drag: "拖曳"
            }
        }
        var action: String {
            switch self {
            case .click: "click"
            case .doubleClick: "double_click"
            case .rightClick: "right_click"
            case .drag: "drag"
            }
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("遠端桌面")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(model.hostStatus.map { "\($0.name) · \($0.screenWidth) × \($0.screenHeight)" } ?? "連線到你的 Mac 螢幕")
                        .font(.system(size: 12))
                        .foregroundStyle(MacLinkTheme.muted)
                }
                Spacer()
                Button {
                    Task { await refreshScreen() }
                } label: {
                    Image(systemName: isLoading ? "hourglass" : "arrow.clockwise")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MacLinkTheme.lime)
                        .frame(width: 42, height: 42)
                        .background(MacLinkTheme.panel, in: Circle())
                }
                .disabled(isFetching)
                .accessibilityLabel("更新畫面")
            }
            .padding(.horizontal, 18)

            GeometryReader { geometry in
                ZStack {
                    Color.black
                    if let screenshot {
                        remoteImage(screenshot, canvas: geometry.size)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                                .font(.system(size: 30))
                                .foregroundStyle(MacLinkTheme.lime.opacity(0.8))
                            Text(model.isPaired ? "正在讀取 Mac 螢幕" : "先配對你的 Mac")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                            Text("首次使用時，macOS 會要求螢幕錄製、輔助使用和 System Events 自動化權限。")
                                .font(.system(size: 11))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(MacLinkTheme.muted)
                                .padding(.horizontal, 30)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(MacLinkTheme.line, lineWidth: 1))
            }
            .frame(minHeight: 260)
            .padding(.horizontal, 14)

            if let errorText = statusText ?? screenErrorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .lineLimit(2)
                    .padding(.horizontal, 18)
            }

            controlPanel

            HStack(spacing: 10) {
                Image(systemName: "keyboard")
                    .foregroundStyle(MacLinkTheme.lime)
                TextField("輸入文字到 Mac", text: $keyboardText, axis: .vertical)
                    .lineLimit(1...3)
                    .focused($keyboardFocused)
                    .submitLabel(.send)
                    .onSubmit { sendText() }
                    .foregroundStyle(.white)
                Button(action: sendText) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(MacLinkTheme.lime)
                }
                .disabled(keyboardText.isEmpty)
                .accessibilityLabel("傳送到 Mac")
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(MacLinkTheme.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 16)

            Text("最高 30 fps、Mac 原生解析度；實際速度會隨網路狀況變化。文字與按鍵會送到 Mac 前景 app。")
                .font(.system(size: 10))
                .foregroundStyle(MacLinkTheme.muted)
                .padding(.bottom, 4)
        }
        .background(MacLinkTheme.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if keyboardFocused {
                    Button("收起鍵盤") { keyboardFocused = false }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起鍵盤") { keyboardFocused = false }
            }
        }
        .task(id: "\(model.isPaired)-\(isLive)-\(scenePhase)-\(isSelected)") {
            if !model.isPaired { screenshot = nil; statusText = nil; screenErrorText = nil; return }
            guard isSelected, scenePhase == .active else { return }
            let clock = ContinuousClock()
            var lastFrameStart = clock.now
            await refreshScreen()
            guard isSelected && isLive && scenePhase == .active else { return }
            while !Task.isCancelled && isSelected && model.isPaired && isLive && scenePhase == .active {
                do {
                    if screenErrorText != nil {
                        try await Task.sleep(for: .seconds(2))
                        lastFrameStart = clock.now
                    } else {
                        let nextFrame = lastFrameStart.advanced(by: .milliseconds(33))
                        if nextFrame > clock.now {
                            try await Task.sleep(until: nextFrame, clock: clock)
                            lastFrameStart = nextFrame
                        } else {
                            lastFrameStart = clock.now
                        }
                    }
                } catch { break }
                if Task.isCancelled { break }
                await refreshScreen()
            }
        }
    }

    private func remoteImage(_ image: UIImage, canvas: CGSize) -> some View {
        let scale = min(canvas.width / image.size.width, canvas.height / image.size.height)
        let width = image.size.width * scale * zoom
        let height = image.size.height * scale * zoom
        return ScrollView([.horizontal, .vertical]) {
            Image(uiImage: image)
                .resizable()
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    guard pointerMode != .drag else { return }
                    let x = min(max(value.location.x / width, 0), 1)
                    let y = min(max(value.location.y / height, 0), 1)
                    sendPointer(pointerMode.action, x: x, y: y)
                })
                .simultaneousGesture(pointerMode == .drag ? DragGesture(minimumDistance: 12).onEnded { value in
                    let x = min(max(value.startLocation.x / width, 0), 1)
                    let y = min(max(value.startLocation.y / height, 0), 1)
                    let endX = min(max(value.location.x / width, 0), 1)
                    let endY = min(max(value.location.y / height, 0), 1)
                    sendPointer("drag", x: x, y: y, endX: endX, endY: endY)
                } : nil)
                .frame(width: max(width, canvas.width), height: max(height, canvas.height))
        }
        .scrollDisabled(pointerMode == .drag)
    }

    private var controlPanel: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                ForEach(PointerMode.allCases) { mode in
                    Button { pointerMode = mode } label: {
                        Text(mode.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(pointerMode == mode ? MacLinkTheme.background : .white)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(pointerMode == mode ? MacLinkTheme.lime : MacLinkTheme.panelRaised,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .accessibilityAddTraits(pointerMode == mode ? .isSelected : [])
                }
            }
            HStack(spacing: 8) {
                Button { zoom = max(1, zoom - 0.5) } label: { keyButton("−") }
                    .disabled(zoom <= 1)
                    .accessibilityLabel("縮小桌面")
                Text("\(Int(zoom * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(MacLinkTheme.muted)
                    .frame(width: 44)
                Button { zoom = min(3, zoom + 0.5) } label: { keyButton("＋") }
                    .disabled(zoom >= 3)
                    .accessibilityLabel("放大桌面")
                Spacer(minLength: 2)
                Button { isLive.toggle() } label: { keyButton(isLive ? "暫停畫面" : "繼續畫面") }
                Menu {
                    ForEach(["escape", "tab", "return", "delete", "space", "up", "down", "left", "right", "command+a", "command+c", "command+v", "command+z"], id: \.self) { key in
                        Button(key) { sendKey(key) }
                    }
                } label: { keyButton("鍵盤") }
            }
            HStack(spacing: 8) {
                Button { sendAction("scroll_up") } label: { keyButton("上捲") }
                Button { sendAction("scroll_down") } label: { keyButton("下捲") }
                Spacer()
                Text(pointerMode == .drag ? "在畫面拖曳 Mac 視窗" : "可在放大畫面上滑動平移")
                    .font(.system(size: 10))
                    .foregroundStyle(MacLinkTheme.muted)
            }
        }
        .padding(.horizontal, 18)
    }

    private func sendPointer(_ action: String, x: Double, y: Double, endX: Double? = nil, endY: Double? = nil) {
        Task {
            guard isSelected, scenePhase == .active, isCurrentPairing, !Task.isCancelled else { return }
            do {
                try await model.input(action: action, x: x, y: y, endX: endX, endY: endY)
                statusText = nil
                if !isLive { await refreshScreen() }
            } catch { statusText = error.localizedDescription }
        }
    }

    private func refreshScreen() async {
        guard isSelected, scenePhase == .active, isCurrentPairing, !Task.isCancelled else { return }
        guard model.isPaired else { screenshot = nil; return }
        guard !isFetching else { return }
        isFetching = true
        isLoading = screenshot == nil
        defer { isFetching = false; isLoading = false }
        do {
            let data = try await model.screen()
            try Task.checkCancellation()
            guard isCurrentPairing else { return }
            guard let image = UIImage(data: data) else { throw ClientError.invalidResponse }
            screenshot = image
            screenErrorText = nil
        } catch is CancellationError {
            return
        } catch {
            guard isSelected, scenePhase == .active, isCurrentPairing, !Task.isCancelled else { return }
            screenshot = nil
            screenErrorText = error.localizedDescription
        }
    }

    private func sendKey(_ key: String) {
        Task {
            guard isSelected, scenePhase == .active, isCurrentPairing, !Task.isCancelled else { return }
            do { try await model.input(action: "key", key: key); statusText = nil }
            catch { statusText = error.localizedDescription }
        }
    }

    private func sendAction(_ action: String) {
        Task {
            guard isSelected, scenePhase == .active, isCurrentPairing, !Task.isCancelled else { return }
            do { try await model.input(action: action); statusText = nil }
            catch { statusText = error.localizedDescription }
        }
    }

    private func sendText() {
        let text = keyboardText
        guard !text.isEmpty else { return }
        keyboardText = ""
        keyboardFocused = false
        Task {
            guard isSelected, scenePhase == .active, isCurrentPairing, !Task.isCancelled else { return }
            do { try await model.input(action: "type", text: text); statusText = nil }
            catch { statusText = error.localizedDescription }
        }
    }

    private func keyButton(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: 42, minHeight: 34)
            .background(MacLinkTheme.panelRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
