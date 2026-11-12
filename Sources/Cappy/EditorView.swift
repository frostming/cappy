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

/// A horizontal stroke drawn at its real thickness.
struct LineSample: View {
    let width: CGFloat

    var body: some View {
        Capsule().fill(Color.primary.opacity(0.85)).frame(height: width)
    }
}

/// Drop-down for the stroke width (which also drives the text size); every
/// option shows the line at its actual thickness.
struct LineWidthPicker: View {
    @ObservedObject var state: EditorState
    @State private var hovering = false

    static let widths: [CGFloat] = [1, 2, 3, 4, 6, 8, 10, 14]

    var body: some View {
        Button { state.widthPickerOpen.toggle() } label: {
            HStack(spacing: 7) {
                LineSample(width: state.lineWidth).frame(width: 30, height: 16)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering || state.widthPickerOpen ? 0.14 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("线宽 / 字号")
        .popover(isPresented: $state.widthPickerOpen, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(Self.widths, id: \.self) { width in
                    LineWidthRow(width: width, selected: state.lineWidth == width) {
                        state.applyLineWidth(width)
                        state.widthPickerOpen = false
                    }
                }
            }
            .padding(6)
        }
    }
}

private struct LineWidthRow: View {
    let width: CGFloat
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                LineSample(width: width).frame(width: 96, height: 22)
                Text("\(Int(width)) pt")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The pill-shaped drop-down button shared by the toolbar pickers.
struct PickerButton<Label: View>: View {
    let open: Bool
    let help: String
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                label()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(hovering || open ? 0.14 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// One row of a picker popover.
struct PickerRow<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(selected ? 1 : 0)
                    .frame(width: 12)
                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.1 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

enum FontCatalog {
    /// Shown first when installed.
    private static let preferred = [
        "PingFang SC", "Songti SC", "Kaiti SC", "Yuanti SC", "Hiragino Sans GB", "Helvetica Neue", "Arial",
        "Georgia", "Times New Roman", "Menlo", "Courier New", "Marker Felt",
    ]

    static let all: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }
    static let common: [String] = preferred.filter { all.contains($0) }

    static func displayName(_ family: String?) -> String {
        guard let family else { return "系统字体" }
        return NSFontManager.shared.localizedName(forFamily: family, face: nil)
    }
}

/// Font family drop-down; each family is shown in its own typeface.
struct FontPicker: View {
    @ObservedObject var state: EditorState

    var body: some View {
        PickerButton(open: state.fontPickerOpen, help: "字体") { state.fontPickerOpen.toggle() } label: {
            Text(FontCatalog.displayName(state.fontName))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 66, alignment: .leading)
        }
        .popover(isPresented: $state.fontPickerOpen, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(spacing: 2) {
                    row(nil)
                    if !FontCatalog.common.isEmpty {
                        header("常用")
                        ForEach(FontCatalog.common, id: \.self) { row($0) }
                    }
                    header("全部字体")
                    ForEach(FontCatalog.all, id: \.self) { row($0) }
                }
                .padding(6)
            }
            .frame(width: 240, height: 360)
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ family: String?) -> some View {
        PickerRow(selected: state.fontName == family) {
            state.applyFontName(family)
            state.fontPickerOpen = false
        } content: {
            Text(FontCatalog.displayName(family))
                .font(family.map { Font.custom($0, size: 14) } ?? .system(size: 14, weight: .semibold))
                .lineLimit(1)
        }
    }
}

/// Text size drop-down.
struct FontSizePicker: View {
    @ObservedObject var state: EditorState

    static let sizes: [CGFloat] = [12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64, 96]

    var body: some View {
        PickerButton(open: state.fontSizePickerOpen, help: "字号") { state.fontSizePickerOpen.toggle() } label: {
            Text(Self.label(state.fontSize))
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 22, alignment: .leading)
        }
        .popover(isPresented: $state.fontSizePickerOpen, arrowEdge: .bottom) {
            VStack(spacing: 2) {
                ForEach(Self.sizes, id: \.self) { size in
                    PickerRow(selected: state.fontSize == size) {
                        state.applyFontSize(size)
                        state.fontSizePickerOpen = false
                    } content: {
                        Text(Self.label(size)).font(.system(size: 13).monospacedDigit())
                    }
                }
            }
            .padding(6)
            .frame(width: 96)
        }
    }

    static func label(_ size: CGFloat) -> String {
        size == size.rounded() ? "\(Int(size))" : String(format: "%.1f", size)
    }
}

/// The two output actions share one shape, height and type size; only the
/// fill tells the primary action (copy) from the secondary one (save).
struct ActionButton: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 15, height: 15)
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.85))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? Color.accentColor.opacity(hovering ? 0.88 : 1)
                                    : Color.primary.opacity(hovering ? 0.14 : 0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Empty toolbar space behaves like a title bar: dragging moves the window,
/// and a double-click zooms or minimizes it according to the system
/// "double-click a window's title bar" setting. Controls in front of it take
/// their own clicks, so they never move or zoom the window.
struct ToolbarDragArea: View {
    let window: () -> NSWindow?
    /// Start point of the gesture that already handed the drag to the window server.
    @State private var handedOff: CGPoint?

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard handedOff != value.startLocation, let window = window(),
                              let event = (window as? EditorWindow)?.lastMouseDown ?? NSApp.currentEvent else { return }
                        handedOff = value.startLocation
                        window.performDrag(with: event)
                    }
                    .onEnded { _ in handedOff = nil }
            )
            .onTapGesture(count: 2) {
                guard let window = window() else { return }
                switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
                case "None": break
                case "Minimize": window.performMiniaturize(nil)
                default: window.performZoom(nil)
                }
            }
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
                .frame(width: 44)
                .help("自定义颜色")
            }

            if state.editsText {
                FontPicker(state: state)
                FontSizePicker(state: state)
            } else {
                LineWidthPicker(state: state)
            }

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
                .help("智能马赛克")
                }
                IconButton(symbol: "photo.artframe", active: state.showInspector, help: "截图装饰") {
                    state.toggleInspector()
                }
            }

            separator

            IconButton(symbol: "pin", help: "悬浮到屏幕 (⌘F)；点击悬浮图后按 Esc 取消，双击回到编辑") {
                state.pinToScreen()
            }

            HStack(spacing: 6) {
                ActionButton(title: "保存", symbol: "square.and.arrow.down", prominent: false, help: "保存… (⌘S)") {
                    state.save(from: state.canvas?.window)
                }
                ActionButton(title: "复制", symbol: "doc.on.doc", prominent: true, help: "复制到剪贴板 (⌘C)") {
                    state.copyToClipboard()
                }
            }
        }
        .padding(.trailing, 12)
        .frame(height: 52)
        .background(ToolbarDragArea { state.canvas?.window })
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
