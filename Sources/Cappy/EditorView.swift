import SwiftUI

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

struct CanvasContainer: NSViewRepresentable {
    let state: EditorState

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CanvasScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        let canvas = CanvasView(state: state)
        scroll.documentView = canvas
        state.canvas = canvas
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

struct IconButton: View {
    let symbol: String
    var active = false
    var disabled = false
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 28)
                .foregroundStyle(active ? Color.white : Color.primary.opacity(disabled ? 0.3 : 0.85))
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(active ? Color.accentColor : Color.primary.opacity(hovering && !disabled ? 0.09 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct ToolbarView: View {
    @ObservedObject var state: EditorState

    private var showsFill: Bool {
        if let kind = state.selected?.kind { return kind == .rect || kind == .ellipse }
        return state.tool == .rect || state.tool == .ellipse
    }

    var body: some View {
        HStack(spacing: 10) {
            Spacer().frame(width: 70) // traffic lights

            HStack(spacing: 2) {
                ForEach(Tool.allCases) { tool in
                    IconButton(symbol: tool.symbol, active: state.tool == tool,
                               help: "\(tool.title) (\(tool.key.uppercased()))") {
                        state.tool = tool
                    }
                }
            }

            separator

            HStack(spacing: 6) {
                ForEach(RGBA.palette, id: \.self) { c in
                    Button { state.applyColor(c) } label: {
                        Circle()
                            .fill(c.color)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                            .padding(2.5)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: state.color == c ? 2 : 0))
                    }
                    .buttonStyle(.plain)
                }
                ColorPicker("", selection: Binding(
                    get: { state.color.color },
                    set: { state.applyColor(RGBA(NSColor($0))) }
                ), supportsOpacity: true)
                .labelsHidden()
                .frame(width: 28)
                .help("自定义颜色")
            }

            HStack(spacing: 4) {
                Image(systemName: "lineweight").font(.system(size: 12)).foregroundStyle(.secondary)
                Slider(value: Binding(get: { state.lineWidth }, set: { state.applyLineWidth($0.rounded()) }), in: 1...14)
                    .controlSize(.small)
                    .frame(width: 84)
            }
            .help("线宽 / 字号")

            if showsFill {
                IconButton(symbol: state.filled ? "square.fill" : "square", active: state.filled, help: "填充形状") {
                    state.applyFilled(!state.filled)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                IconButton(symbol: "arrow.uturn.backward", disabled: !state.canUndo, help: "撤销 (⌘Z)") { state.undo() }
                IconButton(symbol: "arrow.uturn.forward", disabled: !state.canRedo, help: "重做 (⇧⌘Z)") { state.redo() }
            }

            separator

            HStack(spacing: 2) {
                if state.busy {
                    ProgressView().controlSize(.small).frame(width: 30, height: 28)
                } else {
                    IconButton(symbol: "text.viewfinder", help: "OCR 文字识别") { state.runOCR() }
                }
                Menu {
                    Button("自动（敏感信息 + 人脸）") { state.smartMosaic(.auto) }
                    Divider()
                    Button("仅敏感文字（邮箱 / 电话 / 证件号 / 密钥）") { state.smartMosaic(.sensitiveText) }
                    Button("仅人脸") { state.smartMosaic(.faces) }
                    Button("全部文字") { state.smartMosaic(.allText) }
                } label: {
                    Image(systemName: "wand.and.stars").font(.system(size: 14, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 28)
                .disabled(state.busy)
                .help("智能马赛克")
                IconButton(symbol: "photo.artframe", active: state.showInspector, help: "截图装饰") {
                    state.toggleInspector()
                }
            }

            separator

            IconButton(symbol: "square.and.arrow.down", help: "保存… (⌘S)") {
                state.save(from: state.canvas?.window)
            }
            Button {
                state.copyToClipboard()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "doc.on.doc")
                    Text("复制")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("复制到剪贴板 (⌘C)")
        }
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(.bar)
    }

    private var separator: some View {
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 20)
    }
}

struct InspectorView: View {
    @ObservedObject var state: EditorState

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 8), count: 5)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Toggle(isOn: $state.decoration.enabled) {
                    Text("截图装饰").font(.headline)
                }
                .toggleStyle(.switch)

                Group {
                    section("背景") {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                            swatch(selected: state.decoration.background == .none) {
                                state.decoration.background = .none
                            } content: {
                                ZStack {
                                    Color(nsColor: .controlBackgroundColor)
                                    Image(systemName: "nosign").font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                            }
                            .help("透明背景")
                            ForEach(GradientPreset.all.indices, id: \.self) { i in
                                swatch(selected: state.decoration.background == .gradient(i)) {
                                    state.decoration.background = .gradient(i)
                                } content: {
                                    LinearGradient(colors: GradientPreset.all[i].colors.map(\.color),
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            ForEach(Decoration.solidPresets, id: \.self) { c in
                                swatch(selected: state.decoration.background == .solid(c)) {
                                    state.decoration.background = .solid(c)
                                } content: { c.color }
                            }
                        }
                        ColorPicker("自定义纯色", selection: Binding(
                            get: {
                                if case .solid(let c) = state.decoration.background { return c.color }
                                return .white
                            },
                            set: { state.decoration.background = .solid(RGBA(NSColor($0))) }
                        ), supportsOpacity: false)
                        .font(.callout)
                    }

                    section("噪点") {
                        HStack {
                            Slider(value: $state.decoration.noise, in: 0...1).controlSize(.small)
                            Text("\(Int(state.decoration.noise * 100))")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 30, alignment: .trailing)
                        }
                    }
                    slider("留白", $state.decoration.padding, 0...200)
                    slider("圆角", $state.decoration.cornerRadius, 0...48)
                    slider("阴影", $state.decoration.shadow, 0...80)

                    section("边框") {
                        HStack {
                            Slider(value: $state.decoration.borderWidth, in: 0...16).controlSize(.small)
                            Text("\(Int(state.decoration.borderWidth))")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .trailing)
                            ColorPicker("", selection: Binding(
                                get: { state.decoration.borderColor.color },
                                set: { state.decoration.borderColor = RGBA(NSColor($0)) }
                            ), supportsOpacity: true)
                            .labelsHidden()
                        }
                    }
                }
                .disabled(!state.decoration.enabled)
                .opacity(state.decoration.enabled ? 1 : 0.45)
            }
            .padding(16)
        }
        .background(.regularMaterial)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, _ value: Binding<CGFloat>, _ range: ClosedRange<CGFloat>) -> some View {
        section(title) {
            HStack {
                Slider(value: value, in: range).controlSize(.small)
                Text("\(Int(value.wrappedValue))")
                    .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private func swatch<Content: View>(selected: Bool, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .frame(width: 34, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: selected ? 2 : 0)
                    .padding(-3))
        }
        .buttonStyle(.plain)
    }
}

struct OCRSheet: View {
    @ObservedObject var state: EditorState
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("识别结果").font(.headline)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(minWidth: 460, minHeight: 280)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Text("\(text.count) 个字符").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { state.ocrText = nil }.keyboardShortcut(.cancelAction)
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    state.ocrText = nil
                    state.showToast("文字已复制")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear { text = state.ocrText ?? "" }
    }
}

struct EditorView: View {
    @ObservedObject var state: EditorState

    var body: some View {
        VStack(spacing: 0) {
            ToolbarView(state: state)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    Color(nsColor: .underPageBackgroundColor)
                    CanvasContainer(state: state)
                    VStack {
                        if let toast = state.toast {
                            Text(toast)
                                .font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(.thinMaterial, in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        Spacer()
                        HStack {
                            Spacer()
                            zoomControl
                        }
                    }
                    .padding(12)
                    .animation(.easeOut(duration: 0.18), value: state.toast)
                }
                if state.showInspector {
                    Divider()
                    InspectorView(state: state).frame(width: 248)
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: Binding(get: { state.ocrText != nil }, set: { if !$0 { state.ocrText = nil } })) {
            OCRSheet(state: state)
        }
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus", help: "缩小 (⌘-)") { state.canvas?.setZoom(state.zoom / 1.25) }
            Button { state.canvas?.zoomToFit() } label: {
                Text("\(Int((state.zoom * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .frame(width: 44, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("适应窗口 (⌘0)")
            IconButton(symbol: "plus", help: "放大 (⌘+)") { state.canvas?.setZoom(state.zoom * 1.25) }
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
    }
}
