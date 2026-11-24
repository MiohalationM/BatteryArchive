import AppKit
import Charts
import Foundation
import SwiftUI
import Testing

@testable import BatteryBar

@Suite(.serialized) struct ProductLayoutVisualTests {
  @Test func subsecondUsageIsNotPresentedAsZero() {
    #expect(UsageTimeFormat.duration(0) == "0m")
    #expect(UsageTimeFormat.duration(0.2) == "<1m")
    #expect(UsageTimeFormat.duration(59.9) == "<1m")
    #expect(UsageTimeFormat.duration(60) == "1m")
  }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BA_RENDER_PRODUCT_QA"] == "1"))
    @MainActor func powerStatesFitCompactAndDesktopSurfaces() throws {
      let output = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/qa-ui-refresh")
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let states: [(Bool?, Bool, Double, Int?)] = [
        (true, false, 80, 80), (true, true, 79, 80),
        (false, false, 42, nil), (nil, false, 0, nil), (true, false, 100, 100),
      ]
      for width in [340.0, 604.0] {
        for scheme in [ColorScheme.light, .dark] {
          let content = VStack(spacing: 16) {
            ForEach(states.indices, id: \.self) { index in
              let state = states[index]
              let presentation = PowerStatePresentation.resolve(
                external: state.0, charging: state.1,
                level: state.2, target: state.3, behavior: nil)
              VStack(alignment: .leading, spacing: 10) {
                PowerStatusHeading(
                  presentation: presentation,
                  level: state.0 == nil ? nil : state.2,
                  compact: width == 340
                )
                BatteryChargeGauge(
                  level: state.0 == nil ? nil : state.2,
                  mode: presentation.mode,
                  targetPercent: state.3,
                  height: width == 340 ? 7 : 9
                )
              }
              .productCard(accent: presentation.tint, tier: .hero)
            }
          }
          .padding(16).frame(width: width)
          .background { AppBackdrop() }
          .environment(\.colorScheme, scheme)
          let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
          var image: CGImage?
          appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.cgImage
          }
          let rendered = try #require(image)
          #expect(rendered.width == Int(width * 2))
          let data = try #require(
            NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
          try data.write(
            to: output.appendingPathComponent(
              "states-\(Int(width))-\(scheme == .dark ? "dark" : "light").png"))
        }
      }
    }

    /// Exercise the real shared views in a native compositor, without a sampler or store.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BA_RENDER_PRODUCT_QA"] == "1"))
    @MainActor func brandedSurfacesInNativeWindow() async throws {
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      let output = root.appendingPathComponent(".build/qa-glass-brand")
      try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let app = NSApplication.shared
      let previousIcon = app.applicationIconImage
      let previousPolicy = app.activationPolicy()
      app.setActivationPolicy(.regular)
      app.applicationIconImage = NSImage(contentsOf: root.appendingPathComponent("Sources/BatteryBar/Resources/AppIcon.png"))
      defer {
        app.applicationIconImage = previousIcon
        app.setActivationPolicy(previousPolicy)
      }

      let scenarios: [(String, BrandPreviewMode, Double, Double, ColorScheme)] = [
        ("overview-light", .overview, 940.0, 660.0, .light),
        ("overview-dark", .overview, 940.0, 660.0, .dark),
        ("overview-compact", .overview, 840.0, 580.0, .light),
        ("history-compact", .history, 840.0, 580.0, .light),
        ("power-light", .power, 940.0, 660.0, .light),
        ("health-light", .health, 940.0, 704.0, .light),
        ("settings-light", .settings, 940.0, 660.0, .light),
      ]

      for (name, mode, width, height, scheme) in scenarios {
        let content = BrandOverviewFixture(mode: mode)
          .environment(\.colorScheme, scheme)
          .frame(width: width, height: height)
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(
          contentRect: NSRect(x: 0, y: 0, width: width, height: height),
          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "BatteryArchive · 视觉预览（示例数据）"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(500))
        hosting.layoutSubtreeIfNeeded()
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(abs(hosting.frame.height - window.frame.height) < 1)
        for buttonType in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
          let button = try #require(window.standardWindowButton(buttonType))
          #expect(!button.isHidden)
        }
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)",
                             output.appendingPathComponent("\(name).png").path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus != 0 {
          // 命令行会话无屏幕录制 TCC 权限时，回退至同外观高分 ImageRenderer 导出视觉预览
          let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
          let renderContent = BrandOverviewFixture(mode: mode, scrollable: false)
            .environment(\.colorScheme, scheme)
            .frame(width: width, height: height, alignment: .topLeading)
            .clipped()
          var fallback: CGImage?
          appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: renderContent)
            renderer.scale = 2
            fallback = renderer.cgImage
          }
          let rendered = try #require(fallback)
          let data = try #require(
            NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]))
          try data.write(to: output.appendingPathComponent("\(name).png"))
        }
        let image = try #require(NSImage(contentsOf: output.appendingPathComponent("\(name).png")))
        #expect(image.size.width >= width)
      }

      // Render 340pt Popover (light/dark) & About panel previews via ImageRenderer
      for scheme in [ColorScheme.light, .dark] {
        let appearance = try #require(NSAppearance(named: scheme == .dark ? .darkAqua : .aqua))
        let popoverPreview = PopoverPreviewFixture()
          .environment(\.colorScheme, scheme)
        var popImage: CGImage?
        appearance.performAsCurrentDrawingAppearance {
          let renderer = ImageRenderer(content: popoverPreview)
          renderer.scale = 2
          popImage = renderer.cgImage
        }
        let renderedPop = try #require(popImage)
        let popData = try #require(
          NSBitmapImageRep(cgImage: renderedPop).representation(using: .png, properties: [:]))
        try popData.write(
          to: output.appendingPathComponent("popover-\(scheme == .dark ? "dark" : "light").png"))
      }

      let lightAppearance = try #require(NSAppearance(named: .aqua))
      var chargingPopImage: CGImage?
      lightAppearance.performAsCurrentDrawingAppearance {
        let renderer = ImageRenderer(
          content: PopoverPreviewFixture(charging: true).environment(\.colorScheme, .light)
        )
        renderer.scale = 2
        chargingPopImage = renderer.cgImage
      }
      let renderedChargingPop = try #require(chargingPopImage)
      let chargingPopData = try #require(
        NSBitmapImageRep(cgImage: renderedChargingPop).representation(using: .png, properties: [:]))
      try chargingPopData.write(to: output.appendingPathComponent("popover-charging-light.png"))

      var aboutImage: CGImage?
      lightAppearance.performAsCurrentDrawingAppearance {
        let renderer = ImageRenderer(content: AboutPanelView().environment(\.colorScheme, .light))
        renderer.scale = 2
        aboutImage = renderer.cgImage
      }
      if let aboutImage,
         let aboutData = NSBitmapImageRep(cgImage: aboutImage).representation(using: .png, properties: [:]) {
        try aboutData.write(to: output.appendingPathComponent("about-light.png"))
      }
    }
  }

  private enum BrandPreviewMode {
    case overview, history, power, health, settings
  }

  private struct BrandOverviewFixture: View {
    var mode: BrandPreviewMode
    var scrollable = true

    @ViewBuilder
    private func scrollContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
      if scrollable {
        ScrollView { content() }.productScrollEdges()
      } else {
        Color.clear
          .overlay(alignment: .topLeading) {
            content()
              .padding(.top, 10)
              .frame(maxWidth: .infinity, alignment: .topLeading)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .clipped()
      }
    }

    private var section: ProductSection {
      switch mode {
      case .overview: .overview
      case .power: .energy
      case .history, .health: .battery
      case .settings: .settings
      }
    }

    private static var sampleHealthRecords: [BatteryHealthRecord] {
      let calendar = Calendar.current
      let today = calendar.startOfDay(for: Date())
      return (0..<45).map { idx in
        let dayOffset = idx - 44
        let date = calendar.date(byAdding: .day, value: dayOffset, to: today) ?? today
        let systemHealth: Double = idx < 22 ? 96 : (idx < 36 ? 95 : 94)
        let fcc = 4088 - idx * 3 - (idx % 3 == 0 ? 4 : 0)
        let cycles = 156 + (idx * 17) / 44
        let peakTemp = 31.2 + Double(idx % 6) * 0.9
        return BatteryHealthRecord(
          dayKey: BatteryHealthRecord.dayKey(for: date, calendar: calendar),
          recordedAt: date.addingTimeInterval(36_000),
          systemHealthPercent: systemHealth,
          fullChargeCapacityMah: fcc,
          nominalCapacityMah: fcc + 18,
          designCapacityMah: 4382,
          cycleCount: cycles,
          designCycleCount: 1000,
          peakTemperatureC: peakTemp
        )
      }
    }

    var body: some View {
      HStack(spacing: 0) {
        ProductSidebar(selection: .constant(section)) {
          VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
              Image(systemName: "powerplug.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.bbBlue)
              Text("95%")
                .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.bbInk)
              Spacer(minLength: 4)
              Circle().fill(Color.bbBlue).frame(width: 6, height: 6)
            }
            BatteryChargeGauge(level: 95, mode: .external, targetPercent: 95, height: 5)
            Text("电源供电").font(BBType.caption).foregroundStyle(.secondary)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 6)
        }

        VStack(spacing: 0) {
          switch mode {
          case .overview:
            overviewBody
          case .history:
            historyBody
          case .power:
            powerBody
          case .health:
            healthBody
          case .settings:
            settingsBody
          }
        }
      }
      .background { AppBackdrop() }
    }

    private func fixtureLegendDot(color: Color, text: String) -> some View {
      HStack(spacing: 5) {
        Circle().fill(color).frame(width: 6, height: 6)
        Text(text).font(BBType.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
      }
    }

    private var overviewBody: some View {
      VStack(spacing: 0) {
        ProductPageHeader(title: "概览", subtitle: "此刻的状态，今天的记录")
        scrollContainer {
          VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
            VStack(alignment: .leading, spacing: 16) {
              PowerStatusHeading(
                presentation: PowerStatePresentation(
                  mode: .external,
                  title: "电源供电",
                  detail: "已达充电上限 95% · 电池未充电",
                  symbol: "powerplug.fill"
                ),
                level: 95
              )
              VStack(alignment: .leading, spacing: 8) {
                BatteryChargeGauge(level: 95, mode: .external, targetPercent: 95, height: 10)
                HStack(spacing: 8) {
                  Spacer(minLength: 8)
                  Text("充电上限 95%")
                    .font(BBType.captionMedium.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
              }
              HStack(spacing: 10) {
                StatTile(icon: "bolt.fill", tint: .bbAmber, value: "22.8", unit: "W", label: "电源输入")
                StatTile(icon: "waveform.path.ecg", tint: .bbBlue, value: "22.8", unit: "W", label: "整机功耗")
                VStack(alignment: .leading, spacing: 6) {
                  HStack(spacing: 6) {
                    BrandSymbol(systemImage: "pause.circle.fill", tint: .bbTeal, size: 20)
                    Text("电池状态").font(BBType.captionMedium).foregroundStyle(.secondary)
                  }
                  StatusPillBadge(text: "已达上限 · 停充", tint: .bbTeal)
                }
                .productWell(tint: .bbTeal, padding: 11)
              }
            }
            .padding(BBDesign.heroPadding)
            .productSurface(.hero, tint: .bbBlue, cornerRadius: BBDesign.heroRadius)

            HStack {
              Text("今日记录").font(BBType.sectionTitle).foregroundStyle(Color.bbInk)
              Spacer()
              StatusPillBadge(text: "示例数据", systemImage: "calendar", tint: .bbBlue)
            }

            HStack(alignment: .top, spacing: BBDesign.sectionSpacing) {
              VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "今日功耗", systemImage: "waveform.path.ecg", tint: .bbAmber) {
                  CardActionChip(title: "详情", tint: .bbBlue) {}
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                  Text("11.4").font(BBType.metricLarge.monospacedDigit()).foregroundStyle(Color.bbInk)
                  Text("W").font(BBType.bodyMedium).foregroundStyle(.secondary)
                  Text("今日平均").font(BBType.caption).foregroundStyle(.secondary).padding(.leading, 2)
                }
                HStack(spacing: 8) {
                  StatusPillBadge(text: "峰值 18.6 W", tint: .bbAmber)
                  StatusPillBadge(text: "已记录 15h 56m", tint: .bbBlue)
                }
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .productCard(accent: .bbAmber)

              VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "电池使用", systemImage: "battery.75percent", tint: .bbMint) {
                  CardActionChip(title: "详情", tint: .bbBlue) {}
                }
                Text("2h 15m").font(BBType.metricLarge.monospacedDigit()).foregroundStyle(Color.bbInk)
                VStack(alignment: .leading, spacing: 7) {
                  GeometryReader { geo in
                    HStack(spacing: 2) {
                      Capsule().fill(Color.bbMint).frame(width: geo.size.width * 0.78)
                      Capsule().fill(Color.bbSlateBlue.opacity(0.65))
                    }
                  }.frame(height: 6)
                  HStack(spacing: 12) {
                    fixtureLegendDot(color: .bbMint, text: "亮屏 1h 45m")
                    fixtureLegendDot(color: .bbSlateBlue, text: "息屏 30m")
                  }
                }
              }
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
              .productCard(accent: .bbMint)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
              SectionHeader(title: "电池状况", systemImage: "battery.100percent", tint: .bbMint) {
                CardActionChip(title: "健康详情", tint: .bbBlue) {}
              }
              LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
              ) {
                StatTile(icon: "heart.fill", tint: .bbMint, value: "94", unit: "%", label: "最大容量")
                StatTile(icon: "arrow.2.circlepath", tint: .bbBlue, value: "173", unit: "次", label: "循环次数")
                StatTile(icon: "thermometer.medium", tint: .bbAmber, value: "28.7", unit: "°C", label: "电池温度")
                StatTile(icon: "shield.lefthalf.filled", tint: .bbTeal, value: "95", unit: "%", label: "充电上限")
              }
            }
            .productCard(accent: .bbMint)
          }
          .padding(.horizontal, BBDesign.pagePadding).padding(.bottom, 24)
        }
      }
    }

    private var historyBody: some View {
      VStack(spacing: 0) {
        ProductPageHeader(title: "电池", subtitle: "离电使用与电池健康", systemImage: "battery.75percent", tint: .bbMint) {
          ProductSegmentedControl(
            title: "页面",
            selection: .constant(false),
            options: [.init(false, "使用"), .init(true, "健康")],
            tint: .bbBlue
          )
          .frame(width: 196)
        }
        scrollContainer {
          VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
            HistoryDateNavigator(
              date: .constant(Date()), period: .constant(.day),
              first: Date().addingTimeInterval(-86_400 * 5), calendar: .current,
              allowsPeriods: false, tint: .bbMint
            )
            VStack(alignment: .leading, spacing: 12) {
              SectionHeader(title: "当天回顾", systemImage: "battery.75percent", tint: .bbMint)
              LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
              ) {
                StatTile(icon: "sun.max.fill", tint: .bbMint, value: "1h 45m", unit: "", label: "离电亮屏")
                StatTile(icon: "moon.zzz.fill", tint: .bbSlateBlue, value: "30m", unit: "", label: "离电息屏")
                StatTile(icon: "waveform.path.ecg", tint: .bbTeal, value: "5.5", unit: "W", label: "平均离电功耗")
              }
            }
            .productCard(accent: .bbMint)
          }
          .padding(.horizontal, BBDesign.pagePadding)
          .padding(.bottom, 24)
        }
      }
    }

    private var powerBody: some View {
      let now = Date()
      let points = (0..<24).map { idx in
        TrendPoint(
          time: now.addingTimeInterval(Double(-24 + idx) * 150),
          value: 7.5 + sin(Double(idx) * 0.5) * 4.2 + Double(idx % 3) * 0.8,
          coverage: 1.0
        )
      }
      return VStack(spacing: 0) {
        ProductPageHeader(title: "功耗", subtitle: "整机功耗、分项估算与趋势", systemImage: "bolt.fill", tint: .bbAmber)
        scrollContainer {
          VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
            HStack(spacing: 20) {
              VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                  BrandSymbol(systemImage: "waveform.path.ecg", tint: .bbBlue, size: 28)
                  Text("整机功耗").font(BBType.cardTitle).foregroundStyle(Color.bbInk)
                  StatusPillBadge(text: "实测", tint: .bbMint, showDot: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                  Text("12.0").font(BBType.heroNumber().monospacedDigit()).foregroundStyle(Color.bbInk)
                  Text("W").font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                }
                Text("外接电源直供").font(BBType.bodyMedium).foregroundStyle(.secondary)
              }
              Spacer()
              LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                MetricWellCell(title: "电源输入", value: "12.0 W", systemImage: "bolt.fill", tint: .bbAmber)
                MetricWellCell(title: "电池功率", value: "未充电", systemImage: "battery.75percent", tint: .bbMint)
                MetricWellCell(title: "低电量模式", value: "关闭", systemImage: "leaf.fill", tint: .bbTeal)
                MetricWellCell(title: "系统热压力", value: "正常", systemImage: "thermometer.medium", tint: .bbMint)
              }
              .frame(maxWidth: 360)
            }
            .padding(BBDesign.heroPadding)
            .productSurface(.hero, tint: .bbBlue, cornerRadius: BBDesign.heroRadius)

            VStack(alignment: .leading, spacing: 14) {
              SectionHeader(title: "功耗趋势", systemImage: "waveform.path.ecg", tint: .bbAmber) {
                ProductSegmentedControl(
                  title: "时间范围",
                  selection: .constant(TimeRange.hour1),
                  options: TimeRange.allCases.map { .init($0, $0.rawValue) },
                  tint: .bbBlue
                )
                .frame(width: 210)
              }
              HStack(spacing: 10) {
                StatTile(icon: "chart.bar.fill", tint: .bbBlue, value: "9.4", unit: "W", label: "平均功耗")
                StatTile(icon: "arrow.up.circle.fill", tint: .bbAmber, value: "15.2", unit: "W", label: "峰值功耗")
                StatTile(icon: "arrow.down.circle.fill", tint: .bbMint, value: "4.1", unit: "W", label: "最低功耗")
              }
              HStack(spacing: 12) {
                ChartLegendItem(label: "整机功耗", color: .bbAmber, value: "11.2 W")
                Spacer()
                StatusPillBadge(text: "已记录 1小时", tint: .bbBlue)
              }
              TrendChartPlot(points: points, timeRange: .hour1, unit: "W", tintColor: .bbAmber)
            }
            .productCard(accent: .bbAmber)
          }
          .padding(.horizontal, BBDesign.pagePadding)
          .padding(.bottom, 24)
        }
      }
    }

    private var healthBody: some View {
      VStack(spacing: 0) {
        ProductPageHeader(title: "电池", subtitle: "离电使用与电池健康", systemImage: "battery.75percent", tint: .bbMint) {
          ProductSegmentedControl(
            title: "页面",
            selection: .constant(true),
            options: [.init(false, "使用"), .init(true, "健康")],
            tint: .bbBlue
          )
          .frame(width: 196)
        }
        scrollContainer {
          VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
            HStack(spacing: 20) {
              HStack(spacing: 16) {
                ZStack {
                  Circle().stroke(Color.bbMint.opacity(0.16), lineWidth: 7)
                  Circle().trim(from: 0, to: 0.94)
                    .stroke(Color.bbMint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                  Image(systemName: "heart.fill").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.bbMint)
                }
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                  StatusPillBadge(text: "最大容量", tint: .bbMint)
                  HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("94").font(BBType.heroNumber().monospacedDigit()).foregroundStyle(Color.bbInk)
                    Text("%").font(.system(size: 17, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                  }
                }
              }
              Spacer()
              HStack(spacing: 10) {
                StatTile(icon: "arrow.2.circlepath", tint: .bbBlue, value: "173", unit: "次", label: "循环次数").frame(width: 148)
                StatTile(icon: "thermometer.medium", tint: .bbAmber, value: "32.4", unit: "°C", label: "电池温度").frame(width: 148)
              }
            }
            .padding(BBDesign.heroPadding)
            .productSurface(.hero, tint: .bbMint, cornerRadius: BBDesign.heroRadius)

            BatteryHealthTrendCard(records: Self.sampleHealthRecords)

            VStack(alignment: .leading, spacing: 14) {
              SectionHeader(title: "容量与电源", systemImage: "battery.100percent", tint: .bbMint) {
                Button("打开系统电池设置") {}.adaptiveGlassButton().controlSize(.small)
              }
              CapacityComparisonBar(maxCapacity: 3944, designCapacity: 4382)
              LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                MetricWellCell(title: "当前满充容量", value: "3944 mAh", systemImage: "battery.100percent", tint: .bbMint)
                MetricWellCell(title: "设计容量", value: "4382 mAh", systemImage: "ruler", tint: .bbBlue)
                MetricWellCell(title: "电池标称容量", value: "3962 mAh", systemImage: "gauge.with.dots.needle.67percent", tint: .bbTeal)
                MetricWellCell(title: "设计循环上限", value: "1000 次", systemImage: "arrow.2.circlepath", tint: .bbBlue)
                MetricWellCell(title: "适配器额定功率", value: "45 W", systemImage: "powerplug.fill", tint: .bbAmber)
                MetricWellCell(title: "系统充电上限", value: "95%", systemImage: "shield.lefthalf.filled", tint: .bbTeal)
              }
            }
            .productCard(accent: .bbMint)
            .padding(.top, 12)
          }
          .padding(.horizontal, BBDesign.pagePadding)
          .padding(.bottom, 24)
        }
      }
    }

    private var settingsBody: some View {
      VStack(spacing: 0) {
        ProductPageHeader(title: "设置", subtitle: "应用行为、采样与本机数据", systemImage: "gearshape.fill", tint: .bbBlue)
        scrollContainer {
          VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
            VStack(alignment: .leading, spacing: 14) {
              SectionHeader(title: "常规与提醒", systemImage: "bell.badge.fill", tint: .bbBlue)
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text("开机时自动启动").font(BBType.bodyMedium).foregroundStyle(Color.bbInk)
                  Text("已在登录项中启用").font(BBType.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.small)
              }
              Divider().opacity(0.45)
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text("低电量提醒").font(BBType.bodyMedium).foregroundStyle(Color.bbInk)
                  Text("电量 ≤ 20% 且未接电时提醒").font(BBType.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: .constant(true)).labelsHidden().toggleStyle(.switch).controlSize(.small)
              }
            }
            .productCard(accent: .bbBlue)

            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 12) {
                BrandSymbol(systemImage: "shield.slash", tint: .bbBlue, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                  Text("高级采样").font(BBType.cardTitle).foregroundStyle(Color.bbInk)
                  Text("未开启 · 基础监控照常运行").font(BBType.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: .constant(false)).labelsHidden().toggleStyle(.switch).controlSize(.small)
              }
              Text("开启后每 10 秒采样 CPU / GPU / 内存分项功耗（首次需管理员授权）；关闭后不运行后台服务，基础电量与记录照常工作。")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              Divider().opacity(0.4)
              HStack(spacing: 8) {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                Text("辅助服务状态").font(BBType.caption).foregroundStyle(.secondary)
                Spacer()
                Text("已关闭").font(.system(size: 11.5, weight: .semibold, design: .rounded)).foregroundStyle(Color.bbInk)
              }
              HStack(spacing: 8) {
                Image(systemName: "trash.fill").font(.system(size: 11)).foregroundStyle(.red)
                Text("移除后需要管理员授权，再次开启高级采样时将重新安装")
                  .font(BBType.caption).foregroundStyle(.secondary)
                Spacer()
                Button("移除辅助服务…") {}.adaptiveGlassButton().controlSize(.small).disabled(true)
              }
            }
            .productCard(accent: .bbBlue)

            VStack(alignment: .leading, spacing: 12) {
              SectionHeader(title: "本机数据", systemImage: "internaldrive.fill", tint: .bbTeal)
              LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
              ) {
                StatTile(icon: "heart.fill", tint: .bbMint, value: "45", unit: "天", label: "健康记录")
                StatTile(icon: "calendar", tint: .bbTeal, value: "30", unit: "天", label: "使用明细")
                StatTile(icon: "clock.arrow.circlepath", tint: .bbAmber, value: "24", unit: "小时", label: "功耗趋势")
              }
              Text("电池健康与每日汇总永久保留，详细使用曲线保留 30 天，近期功耗与温度曲线保留 24 小时。全部数据仅保存在本机。")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
              ProductDisclosure("采样与存储诊断") { EmptyView() }
            }
            .productCard(accent: .bbTeal)
          }
          .padding(.horizontal, BBDesign.pagePadding)
          .padding(.bottom, 24)
          .frame(maxWidth: BBDesign.formMaxWidth, alignment: .leading)
          .frame(maxWidth: .infinity, alignment: .topLeading)
        }
      }
    }
  }

  private struct PopoverPreviewFixture: View {
    var charging = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 7) {
          BrandSymbol(systemImage: "battery.100percent.bolt", tint: .bbBlue, size: 17)
          Text(AppBrand.displayName)
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .foregroundStyle(Color.bbInk)
          Spacer()
          if charging {
            StatusPillBadge(text: "充电中", tint: .bbAmber, showDot: true)
          } else {
            StatusPillBadge(text: "健康 94%", systemImage: "battery.100percent", tint: .bbMint)
          }
        }

        VStack(alignment: .leading, spacing: 9) {
          HStack(alignment: .center, spacing: 10) {
            BrandSymbol(
              systemImage: charging ? "battery.100percent.bolt" : "battery.75percent",
              tint: charging ? .bbAmber : .bbMint,
              size: 32
            )
            VStack(alignment: .leading, spacing: 2) {
              Text(charging ? "电源供电 · 正在充电" : "电池供电")
                .font(.system(size: 14.5, weight: .bold))
                .foregroundStyle(Color.bbInk)
              Text(charging ? "充电目标 95%" : "正在使用电池")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
              Text(charging ? "78" : "93")
                .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.bbInk)
              Text("%")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            }
          }

          BatteryChargeGauge(
            level: charging ? 78 : 93,
            mode: charging ? .charging : .battery,
            targetPercent: 95,
            height: 7
          )

          HStack(spacing: 6) {
            if charging {
              Label("预计 42m 后达 95%", systemImage: "bolt.badge.clock")
                .font(BBType.caption)
                .foregroundStyle(Color.bbAmber)
                .lineLimit(1)
            } else {
              Label("预计可用 3h 44m · 系统估算", systemImage: "clock")
                .font(BBType.caption)
                .foregroundStyle(Color.bbMint)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("上限 95%")
              .font(BBType.caption.monospacedDigit())
              .foregroundStyle(.secondary)
          }
        }

        hairlineDivider

        VStack(spacing: 6) {
          telemetryRow("waveform.path.ecg", .bbBlue, "整机功耗", charging ? "14.2" : "12.1", "W")
          if charging {
            telemetryRow("bolt.fill", .bbAmber, "电源输入", "45.6", "W")
          } else {
            telemetryRow("battery.75percent", .bbMint, "电池放出", "12.1", "W")
          }
          telemetryRow("thermometer.medium", .bbAmber, "电池温度", charging ? "33.4" : "31.2", "°C")
          telemetryRow("clock.fill", .bbMint, "今日离电", charging ? "2h 15m" : "3h 38m", "")
        }

        hairlineDivider

        HStack(spacing: 8) {
          Button {} label: {
            HStack(spacing: 5) {
              Image(systemName: "macwindow").font(.system(size: 11, weight: .semibold))
              Text("打开概览").font(.system(size: 12, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
          }
          .adaptiveCapsuleGlassButton(tint: .bbBlue)

          Button {} label: {
            HStack(spacing: 5) {
              Image(systemName: "bolt.fill").font(.system(size: 10.5, weight: .semibold))
              Text("功耗分析").font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
          }
          .adaptiveCapsuleGlassButton()

          Button {} label: {
            Image(systemName: "gearshape.fill")
              .font(.system(size: 12, weight: .medium))
              .frame(width: 18, height: 18)
          }
          .adaptiveCapsuleGlassButton()
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 13)
      .frame(width: 312)
      .background { AppBackdrop() }
    }

    private func telemetryRow(_ icon: String, _ tint: Color, _ label: String, _ value: String, _ unit: String) -> some View {
      HStack(spacing: 8) {
        Image(systemName: icon)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(tint)
          .frame(width: 20, height: 20)
          .background(tint.opacity(scheme == .dark ? 0.16 : 0.11), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        Text(label)
          .font(.system(size: 12.5, weight: .medium))
          .foregroundStyle(Color.bbInk.opacity(0.84))
        Spacer(minLength: 8)
        HStack(alignment: .firstTextBaseline, spacing: 2.5) {
          Text(value)
            .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.bbInk)
          if !unit.isEmpty {
            Text(unit).font(BBType.caption).foregroundStyle(.secondary)
          }
        }
      }
      .padding(.vertical, 2.5)
    }

    private var hairlineDivider: some View {
      Rectangle()
        .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08))
        .frame(height: 0.75)
    }
  }
