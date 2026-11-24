import SwiftUI

/// 自定义关于面板。
///
/// 产品名称与功能说明、版本均由 AppBrand 集中提供。
/// 无常驻定时器，不新增持续资源占用。
struct AboutPanelView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        let shown = appeared || reduceMotion
        ZStack {
            AppBackdrop()
            BrandOrbit(tint: .bbBlue)
                .offset(x: 12, y: -42)
                .opacity(0.85)

            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: Color.bbBlue.opacity(0.22), radius: 12, y: 4)
                    .scaleEffect(shown ? 1 : 0.92)

                Text(AppBrand.displayName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bbInk)

                StatusPillBadge(text: AppBrand.tagline, tint: .bbBlue)

                Text("版本 \(AppBrand.version) (\(AppBrand.build))")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .padding(28)
        }
        .frame(width: 380, height: 240)
        .onAppear {
            guard !appeared else { return }
            withAnimation(reduceMotion ? nil : ProductMotion.reveal) {
                appeared = true
            }
        }
    }
}
