import SwiftUI

/// 统一间距、圆角与容器尺寸令牌。
enum BBDesign {
    static let heroRadius: CGFloat = 22
    static let cornerRadius: CGFloat = 18
    static let cornerRadiusSmall: CGFloat = 12
    static let heroPadding: CGFloat = 22
    static let cardPadding: CGFloat = 18
    static let wellPadding: CGFloat = 12
    static let pagePadding: CGFloat = 24
    static let sectionSpacing: CGFloat = 16
    static let itemSpacing: CGFloat = 12
    static let sidebarWidth: CGFloat = 204
    static let formMaxWidth: CGFloat = 740
    static let contentMaxWidth: CGFloat = 1_100
}

/// 统一排版刻度，消除散落的零星字号。
enum BBType {
    static func heroNumber(compact: Bool = false) -> Font {
        .system(size: compact ? 36 : 46, weight: .semibold, design: .rounded)
    }
    static let metricLarge = Font.system(size: 28, weight: .semibold, design: .rounded)
    static let metricSmall = Font.system(size: 19, weight: .semibold, design: .rounded)
    static let pageTitle = Font.system(size: 24, weight: .bold, design: .rounded)
    static let sectionTitle = Font.system(size: 14, weight: .semibold)
    static let cardTitle = Font.system(size: 13.5, weight: .semibold)
    static let body = Font.system(size: 12.5, weight: .regular)
    static let bodyMedium = Font.system(size: 12.5, weight: .medium)
    static let caption = Font.system(size: 11, weight: .regular)
    static let captionMedium = Font.system(size: 11, weight: .medium)
    static let micro = Font.system(size: 10, weight: .medium)
}

/// 统一交互动效曲线：全部为事件驱动或一次性入场，零常驻循环动画，并严格遵循系统减少动态效果。
enum ProductMotion {
    /// 侧栏液态玻璃滑块、分段控制器滑块与 7 日选柱指示器的可打断跟手弹簧
    static let pillGlide = Animation.spring(duration: 0.34, bounce: 0.14)
    /// 图标替换、色态高亮、展开箭头旋转与焦点切换的干脆弹簧
    static let selection = Animation.spring(duration: 0.28, bounce: 0.10)
    /// 页面/子页切换的零过冲临界阻尼过渡（搭配预挂载纯 GPU 图层位移动效，120fps 零卡顿）
    static let page = Animation.spring(duration: 0.26, bounce: 0.0)
    /// 展开面板、表单区块、折叠诊断与告警横幅的柔和展开
    static let reveal = Animation.spring(duration: 0.30, bounce: 0.04)
    /// 实时读数、电量进度条与时间范围切换的平滑数值过渡
    static let reading = Animation.easeOut(duration: 0.28)
    /// 指针悬停微反馈与悬停底囊跟随
    static let hover = Animation.easeOut(duration: 0.14)
    /// 按钮按压反馈与清脆回弹
    static let press = Animation.spring(duration: 0.18, bounce: 0.22)
    /// 健康圆环 / 轨道图的一次性入场描绘
    static let orbit = Animation.easeOut(duration: 0.65)
}

/// 内容与交互表面层级（严格遵循 Apple macOS 26 HIG 分层原则）：
/// - 导航层（主窗口侧栏当前选中的导航按钮）单独使用原生交互式 Liquid Glass，并通过 `glassEffectID` 在切换时平滑滑移；
/// - 侧栏底面与内容层（`hero` / `card` / `well`）统一采用纯净中性表面与细分隔边框，零大面积玻璃、零彩色铺底；
/// - `interactive` 用于独立浮层交互态，不与原生玻璃容器叠加（杜绝 Glass-on-Glass）。
enum BBSurfaceTier {
    case hero
    case card
    case well
    case interactive
}

extension Color {
    /// 克制的原生 macOS 语义色板：中性画布与卡片保持纯正灰白/石墨底，
    /// 仅在图标、进度条、图表数据系列与关键状态点使用自然耐看的强调色。
    private static func dynamicBrandColor(
        light: (Double, Double, Double), dark: (Double, Double, Double)
    ) -> Color {
        let nsColor = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        }
        return Color(nsColor: nsColor)
    }

    /// 主强调蓝（克制对齐 macOS 系统蓝，浅深色均满足 WCAG AA）
    static let bbBlue = dynamicBrandColor(light: (0.00, 0.44, 0.92), dark: (0.25, 0.62, 1.00))
    /// 辅冷青（少量数据对比用）
    static let bbIce = dynamicBrandColor(light: (0.04, 0.50, 0.72), dark: (0.24, 0.76, 0.92))
    /// 柔和天青（仅用于 About 面板品牌轨道点缀）
    static let bbHaloCyan = dynamicBrandColor(light: (0.16, 0.62, 0.92), dark: (0.28, 0.74, 0.96))
    /// 正文主墨色（自然中性黑/白，无冷蓝偏色）
    static let bbInk = dynamicBrandColor(light: (0.11, 0.12, 0.14), dark: (0.94, 0.95, 0.96))
    /// 电池与健康自然绿（贴近 Apple 电池绿，视觉柔和）
    static let bbMint = dynamicBrandColor(light: (0.11, 0.56, 0.34), dark: (0.22, 0.78, 0.48))
    /// 辅助青绿（上限与保留期指标）
    static let bbTeal = dynamicBrandColor(light: (0.08, 0.48, 0.57), dark: (0.24, 0.72, 0.80))
    /// 用电与充电琥珀橙（暖而不脏，浅色下清晰）
    static let bbAmber = dynamicBrandColor(light: (0.76, 0.43, 0.04), dark: (0.97, 0.68, 0.24))
    /// 睡眠柔和靛紫
    static let bbPurple = dynamicBrandColor(light: (0.42, 0.34, 0.76), dark: (0.62, 0.56, 0.94))
    /// 息屏中性灰蓝
    static let bbSlateBlue = dynamicBrandColor(light: (0.48, 0.53, 0.60), dark: (0.54, 0.59, 0.67))
    /// 中性 macOS 窗口底色（纯正浅灰白 / 深石墨，彻底消除蓝偏光晕）
    static let bbCanvas = dynamicBrandColor(light: (0.957, 0.961, 0.969), dark: (0.102, 0.106, 0.118))
}

/// 纯净中性 macOS 窗口画布：零彩色光晕污染、零多层渐变过绘。
struct AppBackdrop: View {
    var body: some View {
        Color.bbCanvas
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

private struct ProductGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme

    let tier: BBSurfaceTier
    let tint: Color
    let cornerRadius: CGFloat
    let interactive: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    private var effectiveTint: Color {
        tint == .clear ? .bbBlue : tint
    }

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                borderOverlay
            }
            .shadow(
                color: shadowColor,
                radius: tier == .hero ? 6 : (tier == .card ? 3 : 0),
                x: 0,
                y: tier == .hero ? 2 : (tier == .card ? 1 : 0)
            )
    }

    private var shadowColor: Color {
        guard !reduceTransparency else { return .clear }
        switch tier {
        case .hero:
            return Color.black.opacity(scheme == .dark ? 0.24 : 0.05)
        case .card:
            return Color.black.opacity(scheme == .dark ? 0.16 : 0.032)
        case .well, .interactive:
            return .clear
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        let hairlineColor: Color = switch tier {
        case .hero:
            scheme == .dark ? Color.white.opacity(0.11) : Color.black.opacity(0.08)
        case .card:
            scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.07)
        case .well:
            scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.055)
        case .interactive:
            effectiveTint.opacity(scheme == .dark ? 0.30 : 0.20)
        }
        shape.strokeBorder(hairlineColor, lineWidth: contrast == .increased ? 1.0 : 0.75)
        if contrast == .increased {
            shape.strokeBorder(Color.primary.opacity(0.42), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        // 内容层（hero / card / well）全部采用纯净中性标准表面，严禁 Liquid Glass 或彩色底染。
        switch tier {
        case .hero:
            let fill = scheme == .dark
                ? Color(red: 0.145, green: 0.150, blue: 0.165)
                : Color.white
            content.background(fill, in: shape)
        case .card:
            let fill = scheme == .dark
                ? Color(red: 0.138, green: 0.143, blue: 0.158)
                : Color.white
            content.background(fill, in: shape)
        case .well:
            let fill = scheme == .dark
                ? Color.white.opacity(0.045)
                : Color.black.opacity(0.028)
            content.background(fill, in: shape)
        case .interactive:
            let fill = effectiveTint.opacity(scheme == .dark ? 0.18 : 0.10)
            content.background(fill, in: shape)
        }
    }
}

/// 克制的平面语义图标徽章：去除仿玻璃高光描边与重渐变，大尺寸保留轻柔底托，小尺寸干净利落。
struct BrandSymbol: View {
    let systemImage: String
    var tint: Color = .bbBlue
    var size: CGFloat = 32
    var hasPlate: Bool = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let usePlate = hasPlate && size >= 24
        let icon = Image(systemName: systemImage)
            .font(.system(size: size * (usePlate ? 0.48 : 0.62), weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: size, height: size)

        if usePlate {
            let radius = max(6.5, size * 0.26)
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            icon
                .background(
                    tint.opacity(scheme == .dark ? 0.16 : 0.10),
                    in: shape
                )
                .accessibilityHidden(true)
        } else {
            icon.accessibilityHidden(true)
        }
    }
}

/// 致敬 AppIcon 的斜椭圆光环（主环 + 亮青高光弧段 + 细斜射线）。仅在出现时绘制一次。
struct BrandOrbit: View {
    var tint: Color = .bbBlue
    var accent: Color = .bbHaloCyan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var revealed = false

    var body: some View {
        let isShown = revealed || reduceMotion
        ZStack {
            Ellipse()
                .trim(from: 0.06, to: isShown ? 0.94 : 0.06)
                .stroke(
                    LinearGradient(
                        colors: [
                            tint.opacity(scheme == .dark ? 0.28 : 0.19),
                            Color.bbInk.opacity(scheme == .dark ? 0.14 : 0.07),
                            tint.opacity(0.03),
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )
            Ellipse()
                .trim(from: 0.56, to: isShown ? 0.72 : 0.56)
                .stroke(
                    LinearGradient(
                        colors: [
                            accent.opacity(scheme == .dark ? 0.78 : 0.68),
                            tint.opacity(scheme == .dark ? 0.50 : 0.38),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 2.3, lineCap: .round)
                )
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, tint.opacity(scheme == .dark ? 0.24 : 0.16), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1.3, height: 96)
                .rotationEffect(.degrees(54))
                .offset(x: 14, y: 0)
                .opacity(isShown ? 1 : 0)
                .scaleEffect(y: isShown ? 1 : 0.5)
        }
        .frame(width: 204, height: 82)
        .rotationEffect(.degrees(-20))
        .animation(reduceMotion ? nil : ProductMotion.reading, value: tint)
        .onAppear {
            guard !revealed else { return }
            withAnimation(reduceMotion ? nil : ProductMotion.orbit) { revealed = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    func productSurface(
        _ tier: BBSurfaceTier,
        tint: Color = .bbBlue,
        cornerRadius: CGFloat? = nil,
        interactive: Bool = false
    ) -> some View {
        let radius = cornerRadius ?? (tier == .hero ? BBDesign.heroRadius : (tier == .well ? BBDesign.cornerRadiusSmall : BBDesign.cornerRadius))
        return modifier(ProductGlass(tier: tier, tint: tint, cornerRadius: radius, interactive: interactive))
    }

    func productWell(tint: Color = .bbBlue, padding: CGFloat = BBDesign.wellPadding) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .productSurface(.well, tint: tint, cornerRadius: BBDesign.cornerRadiusSmall)
    }

    /// 内容层标准次要按钮（Apple HIG：滚动内容与表单卡内使用标准 bordered，不使用 Liquid Glass）。
    @ViewBuilder
    func adaptiveGlassButton() -> some View {
        self.buttonStyle(.bordered)
    }

    /// 浮层/控制栏轻量胶囊按钮（避免在 NSPopover 等原生玻璃容器内叠加 .glass 导致 Glass-on-Glass）。
    @ViewBuilder
    func adaptiveCapsuleGlassButton(tint: Color? = nil) -> some View {
        self.buttonStyle(ProductSecondaryButtonStyle(capsule: true, accentTint: tint))
    }

    /// 图表直接排版在所在内容容器上。
    func chartSurface() -> some View {
        self
            .padding(.horizontal, 2)
            .padding(.top, 4)
    }
}

extension ScrollView {
    /// macOS 26+ 原生硬件加速滚边柔化；旧系统保留轻量渐变过渡。
    @ViewBuilder
    func productScrollEdges() -> some View {
        if #available(macOS 26.0, *) {
            self.contentMargins(.top, 14, for: .scrollContent)
                .scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self.contentMargins(.top, 14, for: .scrollContent)
                .mask {
                    VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                            .frame(height: 14)
                        Rectangle().fill(.black)
                    }
                }
        }
    }
}

struct ProductPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.972 : 1)
            .animation(reduceMotion ? nil : ProductMotion.press, value: configuration.isPressed)
    }
}

/// 侧栏导航按钮按压样式：保留清晰前景与背后滑移的 Liquid Glass，按下瞬间给予细腻缩放触感。
struct SidebarNavButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.975 : 1)
            .opacity(configuration.isPressed ? 0.86 : 1)
            .animation(reduceMotion ? nil : ProductMotion.press, value: configuration.isPressed)
    }
}

/// 统一平滑折叠区块：整行可悬停点击、箭头弹簧旋转、内容带裁切的平滑展开收起（替代 macOS 生硬的默认 DisclosureGroup）。
struct ProductDisclosure<Label: View, Content: View>: View {
    @State private var isExpanded = false
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var label: () -> Label
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : ProductMotion.reveal) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(isHovered || isExpanded ? Color.bbBlue : Color.secondary)
                        .frame(width: 14)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : ProductMotion.selection, value: isExpanded)
                    label()
                    Spacer(minLength: 4)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .background(
                    isHovered
                        ? Color.primary.opacity(scheme == .dark ? 0.065 : 0.04)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : ProductMotion.hover, value: isHovered)
            }
            .buttonStyle(ProductPressStyle())
            .onHover { isHovered = $0 }
            .accessibilityValue(isExpanded ? "已展开" : "已收起")
            .accessibilityHint(isExpanded ? "点击收起详情" : "点击展开详情")

            if isExpanded {
                content()
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .move(edge: .top))
                    )
            }
        }
        .clipped()
    }
}

extension ProductDisclosure where Label == Text {
    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = {
            Text(title)
                .font(BBType.captionMedium)
                .foregroundStyle(Color.bbInk)
        }
        self.content = content
    }
}

/// 卡片右上角轻量文字操作入口（克制去框，悬停柔显底槽与箭头轻推）。
struct CardActionChip: View {
    let title: String
    var tint: Color = .bbBlue
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .offset(x: hovered && !reduceMotion ? 2 : 0)
            }
            .font(BBType.captionMedium)
            .foregroundStyle(hovered ? tint : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                hovered
                    ? tint.opacity(scheme == .dark ? 0.16 : 0.09)
                    : Color.clear,
                in: Capsule()
            )
            .animation(reduceMotion ? nil : ProductMotion.hover, value: hovered)
        }
        .buttonStyle(ProductPressStyle())
        .onHover { hovered = $0 }
    }
}

struct ProductSecondaryButtonStyle: ButtonStyle {
    var capsule: Bool = false
    var accentTint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        SecondaryButtonBody(
            configuration: configuration,
            capsule: capsule,
            accentTint: accentTint
        )
    }

    private struct SecondaryButtonBody: View {
        let configuration: Configuration
        let capsule: Bool
        let accentTint: Color?
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var enabled
        @Environment(\.controlSize) private var controlSize
        @Environment(\.colorScheme) private var scheme
        @State private var isHovered = false

        var body: some View {
            let isSmall = controlSize == .small || controlSize == .mini
            let radius: CGFloat = capsule ? 999 : (isSmall ? 8 : 9.5)
            let fillColor: Color = if let accentTint {
                accentTint.opacity(isHovered ? (scheme == .dark ? 0.26 : 0.16) : (scheme == .dark ? 0.18 : 0.11))
            } else {
                scheme == .dark
                    ? Color.white.opacity(isHovered ? 0.14 : 0.085)
                    : Color.black.opacity(isHovered ? 0.08 : 0.05)
            }
            let borderColor: Color = if let accentTint {
                accentTint.opacity(isHovered ? 0.34 : 0.20)
            } else {
                scheme == .dark
                    ? Color.white.opacity(isHovered ? 0.16 : 0.10)
                    : Color.black.opacity(isHovered ? 0.12 : 0.08)
            }
            configuration.label
                .font(.system(size: isSmall ? 11.5 : 12.5, weight: accentTint != nil ? .semibold : .medium))
                .foregroundStyle(accentTint ?? Color.bbInk)
                .padding(.horizontal, isSmall ? 10 : 12)
                .padding(.vertical, isSmall ? 5 : 6)
                .background {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fillColor)
                        .overlay {
                            RoundedRectangle(cornerRadius: radius, style: .continuous)
                                .strokeBorder(borderColor, lineWidth: 0.75)
                        }
                }
                .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
                .animation(reduceMotion ? nil : ProductMotion.press, value: configuration.isPressed)
                .animation(reduceMotion ? nil : ProductMotion.hover, value: isHovered)
                .onHover { isHovered = $0 && enabled }
        }
    }
}

/// 区块标题：彩色微玻璃图标 + 深靛标题，支持右侧附属控件。
struct SectionHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    let tint: Color
    @ViewBuilder var trailing: Trailing

    init(
        title: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 9) {
            BrandSymbol(systemImage: systemImage, tint: tint, size: 26)
            Text(title)
                .font(BBType.cardTitle)
                .foregroundStyle(Color.bbInk)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, systemImage: String, tint: Color) {
        self.init(title: title, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// 状态/来源轻量胶囊徽章（克制无硬描边，避免页面色块过多）。
struct StatusPillBadge: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = .bbBlue
    var showDot: Bool = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 5) {
            if showDot {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.84)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(tint.opacity(scheme == .dark ? 0.16 : 0.095), in: Capsule())
    }
}

/// 内嵌统计块（供图表统计、本机数据汇总等统一使用 `.well` 槽）。
struct StatTile: View {
    let icon: String
    let tint: Color
    let value: String
    let unit: String
    let label: String

    var body: some View {
        ProductMetric(title: label, value: value, unit: unit, small: true, symbol: icon, tint: tint)
            .productWell(tint: tint, padding: 11)
    }
}

struct ChartLegendItem: View {
    let label: String
    let color: Color
    var value: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Capsule()
                .fill(color)
                .frame(width: 14, height: 3.5)
            Text(label)
                .font(BBType.captionMedium)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
            }
        }
    }
}

struct EmptyChartState: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 8) {
            BrandSymbol(systemImage: systemImage, tint: .bbBlue, size: 34)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.bbInk)
            Text(detail)
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .padding(.vertical, 8)
        .productSurface(.well, tint: .bbBlue)
    }
}
