//
//  UIComponents.swift
//  Solis film meter
//

// MARK: - 役割: アプリ全体で使う共通UI部品
// MARK: - 目次
// 1. 独立UIWindowオーバーレイ
// 2. 露出補正スライダー
// 3. Av/Tv/MセグメントとLiquid Glass装飾
// 4. 測光モードピッカー、警告表示、明暗2点測光ガイド
// 5. プレビュー露出差/露出状態/推奨値カード
// 6. スワイプ補助とゾーンシステム表示
// 7. カメラ状態オーバーレイ

import SwiftUI
import UIKit

extension Notification.Name {
    static let appOverlayWindowActivityChanged = Notification.Name("appOverlayWindowActivityChanged")
}

enum AppOverlayWindowActivityUserInfoKey {
    static let isActive = "isActive"
    static let activeCount = "activeCount"
}

@MainActor
private enum AppOverlayWindowActivity {
    private(set) static var activeCount = 0

    static func increment() {
        activeCount += 1
        postActivityChange()
    }

    static func decrement() {
        activeCount = max(0, activeCount - 1)
        postActivityChange()
    }

    private static func postActivityChange() {
        NotificationCenter.default.post(
            name: .appOverlayWindowActivityChanged,
            object: nil,
            userInfo: [
                AppOverlayWindowActivityUserInfoKey.isActive: activeCount > 0,
                AppOverlayWindowActivityUserInfoKey.activeCount: activeCount
            ]
        )
    }
}

// MARK: - App Overlay Window — キーボード影響を分離する独立UIWindow
enum AppOverlayWindowTransition: Equatable {
    case none
    case settings

    var presentationDuration: TimeInterval {
        switch self {
        case .none:
            return 0
        case .settings:
            return 0.22
        }
    }

    var dismissalDuration: TimeInterval {
        switch self {
        case .none:
            return 0
        case .settings:
            return 0.18
        }
    }
}

@MainActor
final class AppOverlayWindowController {
    private weak var previousKeyWindow: UIWindow?
    private var window: UIWindow?
    private var hostingController: UIHostingController<AnyView>?
    private var transition: AppOverlayWindowTransition = .none
    private var isDismissing = false
    private var isPresented = false

    func present<Content: View>(
        windowLevel: UIWindow.Level = .normal + 2,
        backgroundColor: UIColor = .clear,
        transition: AppOverlayWindowTransition = .none,
        @ViewBuilder content: () -> Content
    ) {
        dismiss(animated: false)
        self.transition = transition
        isDismissing = false

        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }

        previousKeyWindow = windowScene.windows.first(where: \.isKeyWindow)

        let hostingController = UIHostingController(rootView: AnyView(content()))
        hostingController.view.backgroundColor = backgroundColor

        let window = UIWindow(windowScene: windowScene)
        window.frame = windowScene.screen.bounds
        window.windowLevel = windowLevel
        window.backgroundColor = backgroundColor
        window.alpha = transition == .none ? 1 : 0
        window.rootViewController = hostingController
        window.makeKeyAndVisible()

        self.hostingController = hostingController
        self.window = window
        isPresented = true
        AppOverlayWindowActivity.increment()

        guard transition != .none else { return }

        UIView.animate(
            withDuration: transition.presentationDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            window.alpha = 1
        }
    }

    func dismiss(animated: Bool = true) {
        guard animated,
              transition != .none,
              !isDismissing,
              let window else {
            finishDismissal()
            return
        }

        isDismissing = true
        UIView.animate(
            withDuration: transition.dismissalDuration,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            window.alpha = 0
        } completion: { _ in
            self.finishDismissal()
        }
    }

    private func finishDismissal() {
        window?.isHidden = true
        window?.rootViewController = nil
        hostingController = nil
        window = nil
        previousKeyWindow?.makeKey()
        previousKeyWindow = nil
        isDismissing = false
        transition = .none

        if isPresented {
            isPresented = false
            AppOverlayWindowActivity.decrement()
        }
    }
}

// MARK: - Exposure Compensation Slider — 露出補正バー（-3〜+3EV、ドラッグ操作、ダブルタップでリセット）
struct ExposureCompensationSlider: View {
    @Binding var value: Double
    var refined: Bool = false
    let range: ClosedRange<Double> = -3...3
    @State private var dragStartValue: Double? = nil

    var body: some View {
        VStack(spacing: 6) {
            // ラベル行
            HStack(alignment: .firstTextBaseline) {
                Text("露出補正")
                    .font(.meterLabel(10))
                    .tracking(2)
                    .textCase(.uppercase)
                    .foregroundColor(refined ? .refinedTextSoft : .meterSecondary.opacity(0.7))
                Spacer()
                Text(value == 0 ? "± 0" : (value > 0 ? "+\(String(format: "%.1f", value))" : String(format: "%.1f", value)))
                    .font(.meterValue(13))
                    .foregroundColor(refined ? .refinedText : (value == 0 ? .meterSecondary.opacity(0.6) : (value > 0 ? .meterAccent : .cyan)))
                    .monospacedDigit()
            }

            // スライダー本体
            GeometryReader { geometry in
                let w = geometry.size.width
                let h = geometry.size.height
                let centerX = w / 2
                let currentX = (value - range.lowerBound) / (range.upperBound - range.lowerBound) * w

                ZStack(alignment: .leading) {
                    // トラック背景
                    RoundedRectangle(cornerRadius: MeterShape.control)
                        .fill(refined ? Color.refinedPanel : Color.meterButtonBg)
                        .overlay(RoundedRectangle(cornerRadius: MeterShape.control).stroke(refined ? Color.refinedStroke : Color.black.opacity(0.15), lineWidth: 0.5))
                        .frame(height: 6)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .allowsHitTesting(false)

                    // 目盛り（整数EV位置）
                    ForEach(Array(stride(from: Int(range.lowerBound), through: Int(range.upperBound), by: 1)), id: \.self) { ev in
                        let tickX = (Double(ev) - range.lowerBound) / (range.upperBound - range.lowerBound) * w
                        Rectangle()
                            .fill(refined ? (ev == 0 ? Color.refinedText.opacity(0.72) : Color.refinedTextSoft.opacity(0.22)) : (ev == 0 ? Color.meterSecondary.opacity(0.55) : Color.meterSecondary.opacity(0.2)))
                            .frame(width: ev == 0 ? 1.5 : 1, height: ev == 0 ? 18 : 9)
                            .position(x: tickX, y: h / 2)
                            .allowsHitTesting(false)
                    }

                    // 補正量の色塗り
                    if abs(value) > 0.05 {
                        RoundedRectangle(cornerRadius: MeterShape.control)
                            .fill(value > 0 ? Color.meterAccent : Color.cyan)
                            .frame(width: abs(currentX - centerX), height: 6)
                            .offset(x: value > 0 ? centerX : currentX)
                            .frame(maxHeight: .infinity, alignment: .center)
                            .allowsHitTesting(false)
                    }

                    // つまみ（表示用）
                    RoundedRectangle(cornerRadius: MeterShape.control)
                        .fill(refined ? Color.refinedSurface : Color(white: 0.80))
                        .overlay(RoundedRectangle(cornerRadius: MeterShape.control).stroke(refined ? Color.refinedStroke : Color.black.opacity(0.28), lineWidth: 0.5))
                        .frame(width: 11, height: 30)
                        .position(x: currentX, y: h / 2)
                        .allowsHitTesting(false)

                    // つまみ操作エリア（つまみ周辺のみタッチ受付）
                    Color.clear
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .position(x: currentX, y: h / 2)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { gesture in
                                    if dragStartValue == nil {
                                        dragStartValue = value
                                    }
                                    guard let startVal = dragStartValue else { return }
                                    let startX = (startVal - range.lowerBound) / (range.upperBound - range.lowerBound) * w
                                    let newX = startX + gesture.translation.width
                                    let raw = range.lowerBound + (newX / w) * (range.upperBound - range.lowerBound)
                                    let snapped = round(max(range.lowerBound, min(range.upperBound, raw)) * 3) / 3
                                    if snapped != value {
                                        HapticManager.shared.lightTap()
                                        value = snapped
                                    }
                                }
                                .onEnded { _ in
                                    dragStartValue = nil
                                }
                        )
                }
                .frame(height: 36)
                // ダブルタップでゼロリセット
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    withAnimation(.valueChange) { value = 0 }
                    HapticManager.shared.mediumTap()
                }
            }
            .frame(height: 36)

            // 目盛りラベル
            HStack {
                Text("\(Int(range.lowerBound))")
                    .font(.meterLabel(10))
                    .foregroundColor(refined ? .cyan.opacity(0.9) : .cyan.opacity(0.7))
                Spacer()
                Text("0")
                    .font(.meterLabel(10))
                    .foregroundColor(refined ? .refinedTextSoft.opacity(0.6) : .meterSecondary.opacity(0.3))
                Spacer()
                Text("+\(Int(range.upperBound))")
                    .font(.meterLabel(10))
                    .foregroundColor(refined ? .meterAccent.opacity(0.95) : .meterAccent.opacity(0.8))
            }
        }
    }
}

// MARK: - Segmented Mode Picker — Av/Tv/M 露出モード切替ボタン
struct SegmentedModePicker: View {
    @Binding var selectedMode: ExposureMode
    var refined: Bool = false
    var forceLiquidGlass: Bool = false
    var compactLiquidGlass: Bool = false
    var colorlessLiquidGlass: Bool = false
    var prismaticLiquidGlass: Bool = false
    var availableModes: [ExposureMode] = ExposureMode.allCases
    @State private var activeDragBubbleOffset: CGFloat? = nil

    private var liquidGlassInset: CGFloat { compactLiquidGlass ? 4 : 5 }
    private var liquidGlassSpacing: CGFloat { compactLiquidGlass ? 8 : 9 }
    private var liquidGlassItemHeight: CGFloat { compactLiquidGlass ? 40 : 46 }
    private var liquidGlassFontSize: CGFloat { compactLiquidGlass ? 14 : 15 }
    private var legacyCornerRadius: CGFloat { 20 }
    
    var body: some View {
        if refined || forceLiquidGlass {
            liquidGlassPicker
        } else {
            legacyPicker
        }
    }

    private var legacyPicker: some View {
        HStack(spacing: 6) {
            pickerButtons(
                selectedTextColor: .black,
                unselectedTextColor: Color.meterSecondary.opacity(0.6),
                selectedBackground: AnyView(
                    RoundedRectangle(cornerRadius: legacyCornerRadius, style: .continuous)
                        .fill(Color.meterAccent)
                ),
                unselectedBackground: AnyView(
                    RoundedRectangle(cornerRadius: legacyCornerRadius, style: .continuous)
                        .fill(Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: legacyCornerRadius, style: .continuous)
                                .stroke(Color.meterSecondary.opacity(0.2), lineWidth: 0.5)
                        )
                ),
                height: 38,
                fontSize: 14
            )
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: legacyCornerRadius + 3, style: .continuous)
                .fill(Color.meterSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: legacyCornerRadius + 3, style: .continuous)
                        .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    private var liquidGlassPicker: some View {
        GeometryReader { geometry in
            let modes = availableModes
            let itemWidth = liquidGlassItemWidth(in: geometry.size.width, modeCount: modes.count)
            let selectedOffset = liquidGlassBubbleOffset(
                for: selectedModeIndex(in: modes),
                itemWidth: itemWidth
            )
            let bubbleOffset = activeDragBubbleOffset ?? selectedOffset

            ZStack(alignment: .leading) {
                ModeSelectionLiquidGlassTrack(
                    colorless: colorlessLiquidGlass,
                    prismatic: prismaticLiquidGlass
                )

                ModeSelectionLiquidGlassBubble(
                    colorless: colorlessLiquidGlass,
                    prismatic: prismaticLiquidGlass
                )
                    .frame(width: itemWidth, height: liquidGlassItemHeight)
                    .offset(x: bubbleOffset)
                    .allowsHitTesting(false)
                    .animation(.spring(response: 0.28, dampingFraction: 0.82), value: selectedMode)
                    .animation(.spring(response: 0.22, dampingFraction: 0.88), value: activeDragBubbleOffset)

                HStack(spacing: liquidGlassSpacing) {
                    ForEach(modes) { mode in
                        liquidGlassModeButton(mode)
                            .frame(width: itemWidth, height: liquidGlassItemHeight)
                    }
                }
                .padding(liquidGlassInset)
            }
            .contentShape(Capsule(style: .continuous))
            .simultaneousGesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .local)
                    .onChanged { value in
                        updateLiquidGlassSelection(
                            at: value.location.x,
                            totalWidth: geometry.size.width,
                            modes: modes,
                            itemWidth: itemWidth
                        )
                    }
                    .onEnded { _ in
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            activeDragBubbleOffset = nil
                        }
                    }
            )
        }
        .frame(height: liquidGlassItemHeight + liquidGlassInset * 2)
        .shadow(
            color: Color.black.opacity(colorlessLiquidGlass ? 0.12 : 0.22),
            radius: colorlessLiquidGlass ? 8 : 14,
            x: 0,
            y: colorlessLiquidGlass ? 4 : 8
        )
    }

    private func liquidGlassModeButton(_ mode: ExposureMode) -> some View {
        Button {
            selectMode(mode)
        } label: {
            let selected = selectedMode == mode
            Text(mode.shortName)
                .font(.meterValue(liquidGlassFontSize))
                .tracking(1.2)
                .foregroundColor(liquidGlassTextColor(selected: selected))
                .shadow(
                    color: liquidGlassTextShadowColor(selected: selected),
                    radius: colorlessLiquidGlass ? 0 : (selected ? 2 : 1),
                    x: 0,
                    y: colorlessLiquidGlass ? 0 : 1
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func liquidGlassTextColor(selected: Bool) -> Color {
        if colorlessLiquidGlass {
            if refined {
                return selected ? Color.refinedBackground.opacity(0.94) : Color.refinedText.opacity(0.82)
            }
            return selected ? Color.meterSecondary.opacity(0.90) : Color.meterSecondary.opacity(0.78)
        }

        if refined {
            return selected ? Color.refinedBackground.opacity(0.92) : Color.refinedText.opacity(0.78)
        }
        return selected ? Color.meterSecondary.opacity(0.92) : Color.meterSecondary.opacity(0.66)
    }

    private func liquidGlassTextShadowColor(selected: Bool) -> Color {
        guard !colorlessLiquidGlass else { return .clear }
        return selected ? Color.white.opacity(0.28) : Color.black.opacity(0.30)
    }

    private func pickerButtons(
        selectedTextColor: Color,
        unselectedTextColor: Color,
        selectedBackground: AnyView,
        unselectedBackground: AnyView,
        height: CGFloat,
        fontSize: CGFloat
    ) -> some View {
        ForEach(availableModes) { mode in
            Button {
                selectMode(mode)
            } label: {
                let selected = selectedMode == mode
                Text(mode.shortName)
                    .font(.meterValue(fontSize))
                    .tracking(1.2)
                    .foregroundColor(selected ? selectedTextColor : unselectedTextColor)
                    .shadow(color: selected ? Color.cyan.opacity(0.42) : Color.black.opacity(0.28), radius: selected ? 3 : 1, x: 0, y: 1)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(selected ? selectedBackground : unselectedBackground)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func selectMode(_ mode: ExposureMode) {
        guard selectedMode != mode else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            selectedMode = mode
        }
        HapticManager.shared.selectionChanged()
    }

    private func liquidGlassItemWidth(in totalWidth: CGFloat, modeCount: Int) -> CGFloat {
        guard modeCount > 0 else { return 0 }
        let availableWidth = max(0, totalWidth - liquidGlassInset * 2)
        let totalSpacing = liquidGlassSpacing * CGFloat(max(0, modeCount - 1))
        return max(1, (availableWidth - totalSpacing) / CGFloat(modeCount))
    }

    private func selectedModeIndex(in modes: [ExposureMode]) -> Int {
        modes.firstIndex(of: selectedMode) ?? 0
    }

    private func liquidGlassBubbleOffset(for index: Int, itemWidth: CGFloat) -> CGFloat {
        liquidGlassInset + CGFloat(index) * (itemWidth + liquidGlassSpacing)
    }

    private func updateLiquidGlassSelection(
        at locationX: CGFloat,
        totalWidth: CGFloat,
        modes: [ExposureMode],
        itemWidth: CGFloat
    ) {
        guard !modes.isEmpty else { return }

        let firstOffset = liquidGlassBubbleOffset(for: 0, itemWidth: itemWidth)
        let lastOffset = liquidGlassBubbleOffset(for: modes.count - 1, itemWidth: itemWidth)
        let draggedOffset = min(max(locationX - itemWidth / 2, firstOffset), lastOffset)
        activeDragBubbleOffset = draggedOffset

        let relativeX = min(max(locationX - liquidGlassInset, 0), max(0, totalWidth - liquidGlassInset * 2))
        let slotWidth = itemWidth + liquidGlassSpacing
        let rawIndex = Int((relativeX / max(slotWidth, 1)).rounded(.down))
        let nearestIndex = min(max(rawIndex, 0), modes.count - 1)
        selectMode(modes[nearestIndex])
    }
}

private struct ModeSelectionLiquidGlassTrack: View {
    var colorless: Bool = false
    var prismatic: Bool = false

    var body: some View {
        let shape = Capsule(style: .continuous)

        if #available(iOS 26.0, *) {
            if colorless {
                shape
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(.regular.interactive(), in: shape)
                    .overlay(
                        shape.stroke(Color.white.opacity(prismatic ? 0.20 : 0.32), lineWidth: 0.7)
                    )
                    .overlay(
                        shape
                            .inset(by: 1.5)
                            .stroke(Color.black.opacity(prismatic ? 0.06 : 0.10), lineWidth: 0.5)
                    )
            } else {
                shape
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(0.10))
                            .interactive(),
                        in: shape
                    )
                    .overlay(
                        shape.fill(Color.white.opacity(0.12))
                    )
                    .overlay(
                        shape.stroke(Color.white.opacity(0.42), lineWidth: 0.9)
                    )
                    .overlay(
                        ModeSelectionDiffractionEdge(opacity: 0.18, lineWidth: 0.7)
                            .clipShape(shape)
                    )
                    .overlay(
                        shape
                            .inset(by: 1.5)
                            .stroke(Color.black.opacity(0.10), lineWidth: 0.5)
                    )
            }
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.white.opacity(colorless ? 0.04 : 0.18)))
                .overlay(shape.stroke(Color.white.opacity(colorless ? 0.28 : 0.45), lineWidth: 0.9))
        }
    }
}

private struct ModeSelectionLiquidGlassBubble: View {
    var colorless: Bool = false
    var prismatic: Bool = false

    var body: some View {
        let shape = Capsule(style: .continuous)

        Group {
            if colorless {
                ModeSelectionColorlessLiquidGlassBubble(prismatic: prismatic)
            } else {
                ModeSelectionTintedLiquidGlassBubble()
            }
        }
        .clipShape(shape)
        .shadow(color: Color.white.opacity(colorless ? (prismatic ? 0.14 : 0.10) : 0.20), radius: prismatic ? 6 : 10, x: 0, y: -2)
        .shadow(color: colorless ? Color.clear : Color.cyan.opacity(0.18), radius: 14, x: 0, y: 6)
        .shadow(color: Color.black.opacity(colorless ? 0.12 : 0.18), radius: colorless ? 6 : 9, x: 0, y: colorless ? 3 : 5)
    }
}

private struct ModeSelectionColorlessLiquidGlassBubble: View {
    var prismatic: Bool

    var body: some View {
        let shape = Capsule(style: .continuous)

        ZStack {
            if #available(iOS 26.0, *) {
                shape
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(.regular.interactive(), in: shape)
            } else {
                shape
                    .fill(.ultraThinMaterial)
            }

            if prismatic {
                ModeSelectionTranslucentLens(opacity: 0.44)
                    .clipShape(shape)

                ModeSelectionPrismEdge(opacity: 0.76, lineWidth: 1.05)
                    .clipShape(shape)

                ModeSelectionChromaticBloom(opacity: 0.42)
                    .clipShape(shape)
            }

            shape
                .stroke(Color.white.opacity(prismatic ? 0.58 : 0.58), lineWidth: 0.8)

            shape
                .inset(by: 1.5)
                .stroke(Color.black.opacity(prismatic ? 0.06 : 0.10), lineWidth: 0.5)
        }
    }
}

private struct ModeSelectionTranslucentLens: View {
    var opacity: Double

    var body: some View {
        let shape = Capsule(style: .continuous)

        ZStack {
            shape
                .fill(Color.white.opacity(opacity * 0.30))
                .blendMode(.screen)

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(opacity * 0.58),
                            Color.white.opacity(opacity * 0.22),
                            Color.clear
                        ],
                        center: .topLeading,
                        startRadius: 4,
                        endRadius: 120
                    )
                )
                .blendMode(.screen)

            shape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(opacity * 0.20),
                            Color.clear,
                            Color.black.opacity(opacity * 0.08)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .allowsHitTesting(false)
    }
}

private struct ModeSelectionTintedLiquidGlassBubble: View {
    var body: some View {
        let shape = Capsule(style: .continuous)

        ZStack {
            if #available(iOS 26.0, *) {
                shape
                    .fill(Color.white.opacity(0.001))
                    .glassEffect(
                        .regular
                            .tint(Color.white.opacity(0.11))
                            .interactive(),
                        in: shape
                    )
            } else {
                shape
                    .fill(.ultraThinMaterial)
            }

            shape
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.58),
                            Color.white.opacity(0.34),
                            Color.white.opacity(0.13),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 5,
                        endRadius: 88
                    )
                )

            ModeSelectionGlassCaustics()
                .clipShape(shape)
                .blendMode(.screen)

            shape
                .stroke(Color.white.opacity(0.74), lineWidth: 1.0)

            ModeSelectionDiffractionEdge(opacity: 0.82, lineWidth: 1.25)
                .clipShape(shape)
        }
    }
}

private struct ModeSelectionPrismEdge: View {
    var opacity: Double
    var lineWidth: CGFloat

    var body: some View {
        let shape = Capsule(style: .continuous)

        ZStack {
            shape
                .stroke(Color.red.opacity(opacity * 0.55), lineWidth: lineWidth)
                .offset(x: -1.2, y: -0.6)
                .blur(radius: 0.35)

            shape
                .stroke(Color.yellow.opacity(opacity * 0.48), lineWidth: lineWidth * 0.8)
                .offset(x: -0.35, y: -1.0)
                .blur(radius: 0.45)

            shape
                .stroke(Color.cyan.opacity(opacity * 0.70), lineWidth: lineWidth)
                .offset(x: 0.8, y: 0.7)
                .blur(radius: 0.3)

            shape
                .stroke(Color.blue.opacity(opacity * 0.58), lineWidth: lineWidth * 0.9)
                .offset(x: 1.45, y: 1.0)
                .blur(radius: 0.4)

            shape
                .trim(from: 0.56, to: 0.92)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.yellow.opacity(opacity * 0.58),
                            Color.pink.opacity(opacity * 0.78),
                            Color.cyan.opacity(opacity * 0.82),
                            Color.blue.opacity(opacity * 0.70)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth * 1.45, lineCap: .round)
                )
                .blur(radius: 0.7)

            shape
                .trim(from: 0.04, to: 0.30)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(opacity * 0.74),
                            Color.white.opacity(opacity * 0.82),
                            Color.pink.opacity(opacity * 0.72),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth * 1.2, lineCap: .round)
                )
                .blur(radius: 0.55)
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

private struct ModeSelectionChromaticBloom: View {
    var opacity: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.cyan.opacity(opacity * 0.18),
                                Color.pink.opacity(opacity * 0.20),
                                Color.yellow.opacity(opacity * 0.14),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: width * 1.08, height: max(10, height * 0.22))
                    .rotationEffect(.degrees(-12))
                    .offset(x: -width * 0.02, y: -height * 0.28)
                    .blur(radius: 3.5)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.yellow.opacity(opacity * 0.14),
                                Color.pink.opacity(opacity * 0.18),
                                Color.blue.opacity(opacity * 0.20),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 1.1, height: max(8, height * 0.18))
                    .rotationEffect(.degrees(10))
                    .offset(x: width * 0.05, y: height * 0.30)
                    .blur(radius: 3.8)
            }
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

private struct ModeSelectionGlassCaustics: View {
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = geometry.size.height

            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.50),
                                Color.cyan.opacity(0.16),
                                Color.clear
                            ],
                            center: .topLeading,
                            startRadius: 3,
                            endRadius: max(width, height) * 0.72
                        )
                    )
                    .blur(radius: 5)
                    .offset(x: -width * 0.24, y: -height * 0.22)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.white.opacity(0.24),
                                Color.cyan.opacity(0.10),
                                Color.pink.opacity(0.12),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width * 0.92, height: max(8, height * 0.22))
                    .rotationEffect(.degrees(-17))
                    .offset(x: -width * 0.04, y: -height * 0.16)
                    .blur(radius: 3.2)

                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.yellow.opacity(0.08),
                                Color.pink.opacity(0.10),
                                Color.cyan.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .bottomLeading,
                            endPoint: .topTrailing
                        )
                    )
                    .frame(width: width * 1.08, height: max(10, height * 0.28))
                    .rotationEffect(.degrees(13))
                    .offset(x: width * 0.12, y: height * 0.18)
                    .blur(radius: 4.5)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct ModeSelectionDiffractionEdge: View {
    var opacity: Double
    var lineWidth: CGFloat

    var body: some View {
        let shape = Capsule(style: .continuous)

        ZStack {
            shape
                .trim(from: 0.02, to: 0.28)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.cyan.opacity(opacity),
                            Color.white.opacity(opacity * 0.88),
                            Color.pink.opacity(opacity * 0.72),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .blur(radius: 0.35)

            shape
                .trim(from: 0.58, to: 0.88)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.yellow.opacity(opacity * 0.46),
                            Color.pink.opacity(opacity * 0.64),
                            Color.cyan.opacity(opacity * 0.50)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    ),
                    style: StrokeStyle(lineWidth: lineWidth * 0.82, lineCap: .round)
                )
                .blur(radius: 0.45)

            shape
                .stroke(
                    AngularGradient(
                        colors: [
                            Color.white.opacity(opacity * 0.28),
                            Color.cyan.opacity(opacity * 0.44),
                            Color.clear,
                            Color.pink.opacity(opacity * 0.34),
                            Color.yellow.opacity(opacity * 0.22),
                            Color.white.opacity(opacity * 0.28)
                        ],
                        center: .center
                    ),
                    lineWidth: lineWidth * 0.55
                )
                .blur(radius: 0.25)
                .opacity(0.74)
        }
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

// MARK: - Metering Mode Picker — スポット/中央重点/マルチ/平均/2点 測光モード切替
struct MeteringModePicker: View {
    @Binding var selectedMode: MeteringMode
    var spotReferenceTarget: SpotMeteringReferenceTarget = .shadow
    var showModeLabels: Bool = true
    var availableModes: [MeteringMode] = MeteringMode.allCases
    private var buttonCornerRadius: CGFloat { showModeLabels ? 20 : 19 }
    
    var body: some View {
        HStack(spacing: 8) {
            ForEach(availableModes) { mode in
                Button {
                    selectedMode = mode
                    HapticManager.shared.selectionChanged()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 18, weight: showModeLabels ? .medium : .semibold))
                            .frame(width: 24, height: 20)
                        Text(showModeLabels ? mode.displayName : mode.compactLabel)
                            .font(.meterLabel(showModeLabels ? 8 : 7))
                            .tracking(showModeLabels ? 0.5 : 0.2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if mode == .spot, selectedMode == .spot {
                            HStack(spacing: 3) {
                                Image(systemName: spotReferenceTarget.iconName)
                                    .font(.system(size: 7, weight: .semibold))
                                Text(spotReferenceTarget.shortTitle)
                                    .font(.system(size: 7, weight: .bold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(showModeLabels ? Color.meterAccent.opacity(0.18) : Color.refinedPanelSoft.opacity(0.12))
                            )
                        }
                    }
                    .foregroundColor(
                        showModeLabels
                            ? (selectedMode == mode ? .meterAccent : .meterSecondary.opacity(0.45))
                            : (selectedMode == mode ? .refinedText : .refinedTextOnDark)
                    )
                    .frame(width: showModeLabels ? 62 : 60, height: showModeLabels ? 58 : 56)
                    .background(
                        RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                            .fill(
                                selectedMode == mode
                                    ? (showModeLabels ? Color.meterAccent.opacity(0.12) : Color.refinedSurface)
                                    : (showModeLabels ? Color.clear : Color.refinedPanel)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous)
                                    .stroke(
                                        selectedMode == mode
                                            ? (showModeLabels ? Color.meterAccent.opacity(0.6) : Color.refinedStroke)
                                            : Color.meterSecondary.opacity(showModeLabels ? 0.15 : 0.06),
                                        lineWidth: selectedMode == mode ? 1 : 0.5
                                    )
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: buttonCornerRadius, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct MeteringAttentionIndicator: View {
    let showDotOnly: Bool
    let text: String
    let refined: Bool
    let warning: SpotMeteringWarning
    var compact: Bool = false

    private var tint: Color {
        warningIndicatorTint(for: warning)
    }

    var body: some View {
        Group {
            if showDotOnly {
                if refined {
                    refinedDot
                } else {
                    classicDot
                }
            } else {
                if refined {
                    refinedLabel
                } else {
                    classicLabel
                }
            }
        }
    }

    private var classicDot: some View {
        Group {
            if warning == .brightArea {
                Circle()
                    .fill(tint)
                    .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1))
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(tint)
                    .rotationEffect(.degrees(45))
                    .overlay(
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(Color.white.opacity(0.9), lineWidth: 1)
                            .rotationEffect(.degrees(45))
                    )
            }
        }
        .frame(width: compact ? 9 : 10, height: compact ? 9 : 10)
    }

    private var refinedDot: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.16))
                .frame(width: compact ? 15 : 18, height: compact ? 15 : 18)
            Circle()
                .stroke(tint.opacity(0.92), lineWidth: 1.1)
                .frame(width: compact ? 11 : 14, height: compact ? 11 : 14)
            if warning == .brightArea {
                Circle()
                    .fill(tint)
                    .frame(width: compact ? 4.5 : 5.5, height: compact ? 4.5 : 5.5)
            } else {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(tint)
                    .frame(width: compact ? 4.5 : 5.5, height: compact ? 4.5 : 5.5)
                    .rotationEffect(.degrees(45))
            }
        }
        .shadow(color: tint.opacity(0.28), radius: compact ? 4 : 5, x: 0, y: 0)
    }

    private var classicLabel: some View {
        Text(text)
            .font(.system(size: compact ? 8 : 10, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.92))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, compact ? 3 : 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.22))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
                    )
            )
    }

    private var refinedLabel: some View {
        HStack(spacing: compact ? 5 : 6) {
            refinedDot
            Text(text)
                .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                .tracking(0.3)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(.white.opacity(0.95))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.3))
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.5), lineWidth: 0.8)
                )
        )
    }
}

struct MeteringWarningTextChip: View {
    let warning: SpotMeteringWarning
    let refined: Bool
    var compact: Bool = false

    private var text: String {
        switch warning {
        case .brightArea:
            return warning.detailText ?? warning.shortText ?? ""
        case .offTarget:
            return warning.shortText ?? warning.detailText ?? ""
        case .none:
            return ""
        }
    }

    private var tint: Color {
        warningIndicatorTint(for: warning)
    }

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
            .tracking(0.2)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .foregroundColor(.white.opacity(0.95))
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 4 : 5)
            .background(
                Capsule()
                    .fill(Color.black.opacity(refined ? 0.3 : 0.22))
                    .overlay(
                        Capsule()
                            .stroke(tint.opacity(0.5), lineWidth: 0.8)
                    )
            )
    }
}

struct MeteringWarningPairIndicator: View {
    let activeWarning: SpotMeteringWarning
    let refined: Bool
    var compact: Bool = false
    var onTap: (SpotMeteringWarning) -> Void

    private let warnings: [SpotMeteringWarning] = [.brightArea, .offTarget]

    private func tint(for warning: SpotMeteringWarning) -> Color {
        warningIndicatorTint(for: warning)
    }

    private func slot(for warning: SpotMeteringWarning) -> some View {
        let isActive = activeWarning == warning
        let tint = tint(for: warning)

        return Button {
            onTap(warning)
        } label: {
            ZStack {
                Circle()
                    .fill(isActive ? tint.opacity(refined ? 0.18 : 0.12) : Color.white.opacity(refined ? 0.08 : 0.12))
                    .frame(width: compact ? 15 : 18, height: compact ? 15 : 18)
                Circle()
                    .stroke(isActive ? tint.opacity(0.92) : Color.white.opacity(refined ? 0.22 : 0.28), lineWidth: isActive ? 1.1 : 0.7)
                    .frame(width: compact ? 11 : 14, height: compact ? 11 : 14)
                Circle()
                    .fill(isActive ? tint : Color.white.opacity(refined ? 0.18 : 0.22))
                    .frame(width: compact ? 4.5 : 5.5, height: compact ? 4.5 : 5.5)
            }
            .shadow(color: isActive ? tint.opacity(0.28) : .clear, radius: compact ? 4 : 5, x: 0, y: 0)
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                slot(for: warning)
            }
        }
    }
}

private func warningIndicatorTint(for warning: SpotMeteringWarning) -> Color {
    switch warning {
    case .brightArea:
        return .meterRed
    case .offTarget, .none:
        return Color(red: 1.0, green: 0.86, blue: 0.22)
    }
}

func threePointMeteringTint(for target: ThreePointSampleKind) -> Color {
    switch target {
    case .highlight:
        return Color(red: 1.0, green: 0.72, blue: 0.28)
    case .midtone:
        return .white
    case .shadow:
        return Color(red: 0.45, green: 0.78, blue: 1.0)
    }
}

private func threePointMeteringInstructionText(for target: ThreePointSampleKind) -> String {
    switch target {
    case .highlight:
        return "最明部を測光"
    case .midtone:
        return "中間調を確認"
    case .shadow:
        return "最暗部を測光"
    }
}

func threePointMeteringBannerText(for target: ThreePointSampleKind) -> String {
    switch target {
    case .highlight:
        return "最明部を中央で取得"
    case .midtone:
        return "中間調を確認"
    case .shadow:
        return "最暗部を中央で取得"
    }
}

struct ThreePointMeteringTargetTextChip: View {
    let target: ThreePointSampleKind
    let refined: Bool
    var compact: Bool = false

    private var tint: Color {
        threePointMeteringTint(for: target)
    }

    var body: some View {
        HStack(spacing: compact ? 5 : 6) {
            Circle()
                .fill(tint)
                .frame(width: compact ? 7 : 8, height: compact ? 7 : 8)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                )
            Text(threePointMeteringInstructionText(for: target))
                .font(.system(size: compact ? 8 : 10, weight: .bold, design: .rounded))
                .tracking(0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(.white.opacity(0.95))
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background(
            Capsule()
                .fill(Color.black.opacity(refined ? 0.3 : 0.22))
                .overlay(
                    Capsule()
                        .stroke(tint.opacity(0.55), lineWidth: 0.8)
                )
        )
        .accessibilityLabel(threePointMeteringInstructionText(for: target))
    }
}

struct ThreePointMeteringTargetPairIndicator: View {
    let activeTarget: ThreePointSampleKind
    let refined: Bool
    var compact: Bool = false

    private let targets: [ThreePointSampleKind] = [.highlight, .shadow]

    private func slot(for target: ThreePointSampleKind) -> some View {
        let isActive = activeTarget == target
        let tint = threePointMeteringTint(for: target)

        return ZStack {
            Circle()
                .fill(isActive ? tint.opacity(refined ? 0.18 : 0.12) : Color.white.opacity(refined ? 0.08 : 0.12))
                .frame(width: compact ? 15 : 18, height: compact ? 15 : 18)
            Circle()
                .stroke(isActive ? tint.opacity(0.92) : Color.white.opacity(refined ? 0.22 : 0.28), lineWidth: isActive ? 1.1 : 0.7)
                .frame(width: compact ? 11 : 14, height: compact ? 11 : 14)
            Circle()
                .fill(isActive ? tint : Color.white.opacity(refined ? 0.18 : 0.22))
                .frame(width: compact ? 4.5 : 5.5, height: compact ? 4.5 : 5.5)
        }
        .shadow(color: isActive ? tint.opacity(0.28) : .clear, radius: compact ? 4 : 5, x: 0, y: 0)
        .accessibilityHidden(true)
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            ForEach(targets, id: \.rawValue) { target in
                slot(for: target)
            }
        }
        .accessibilityLabel(threePointMeteringInstructionText(for: activeTarget))
    }
}

struct MeteringWarningGuidePopup: View {
    let refined: Bool
    var onDismiss: () -> Void

    private var titleColor: Color {
        refined ? .refinedText : .meterSecondary
    }

    private var secondaryColor: Color {
        refined ? .refinedTextSoft : .meterSecondary.opacity(0.72)
    }

    private var panelFill: Color {
        refined ? .refinedSurface : .meterCardBg.opacity(0.98)
    }

    private var panelStroke: Color {
        refined ? .refinedStroke : Color.black.opacity(0.12)
    }

    private var primaryButtonFill: Color {
        refined ? .refinedPanel : .meterAccent
    }

    private var primaryButtonText: Color {
        refined ? .refinedTextOnDark : .black
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(titleColor)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("警告インジケーター")
                            .font(.meterValue(14))
                            .foregroundColor(titleColor)
                        Text("補助テキストなしでは、左上の2点で警告の種類を示します。")
                            .font(.meterLabel(10))
                            .foregroundColor(secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(secondaryColor)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(refined ? Color.refinedPanel : Color.meterButtonBg.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }

                warningIndicatorPreview

                VStack(spacing: 8) {
                    warningGuideRow(
                        sideLabel: "左",
                        warning: .brightArea,
                        title: "かなり明るい場所",
                        description: "水面やガラスなどの強い反射面を測っている可能性があります。"
                    )
                    warningGuideRow(
                        sideLabel: "右",
                        warning: .offTarget,
                        title: "基準外測光点",
                        description: "選んだ基準より外れた明るさの場所を測っています。"
                    )
                }

                Button {
                    onDismiss()
                } label: {
                    Text("閉じる")
                        .font(.meterValue(12))
                        .foregroundColor(primaryButtonText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(primaryButtonFill)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(panelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(panelStroke, lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 28, x: 0, y: 12)
            )
            .padding(.horizontal, 24)
        }
    }

    private var warningIndicatorPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("左上の表示イメージ")
                .font(.meterLabel(10))
                .foregroundColor(secondaryColor)

            HStack(spacing: 18) {
                warningPreviewSlot(sideLabel: "左", warning: .brightArea)
                warningPreviewSlot(sideLabel: "右", warning: .offTarget)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(refined ? Color.refinedPanel : Color.meterSurface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(refined ? Color.refinedStroke.opacity(0.6) : Color.black.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
    }

    private func warningPreviewSlot(sideLabel: String, warning: SpotMeteringWarning) -> some View {
        VStack(spacing: 6) {
            MeteringAttentionIndicator(
                showDotOnly: true,
                text: "",
                refined: refined,
                warning: warning,
                compact: false
            )
            Text(sideLabel)
                .font(.meterLabel(9))
                .foregroundColor(secondaryColor)
        }
        .frame(minWidth: 32)
    }

    private func warningGuideRow(
        sideLabel: String,
        warning: SpotMeteringWarning,
        title: String,
        description: String
    ) -> some View {
        let rowTint = warningIndicatorTint(for: warning)

        return HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                MeteringAttentionIndicator(
                    showDotOnly: true,
                    text: "",
                    refined: refined,
                    warning: warning,
                    compact: false
                )
                Text(sideLabel)
                    .font(.meterLabel(9))
                    .foregroundColor(secondaryColor)
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.meterValue(11))
                    .foregroundColor(titleColor)
                Text(description)
                    .font(.meterLabel(10))
                    .foregroundColor(secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(refined ? Color.refinedPanel : Color.meterSurface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            refined ? rowTint.opacity(0.28) : rowTint.opacity(0.22),
                            lineWidth: 0.5
                        )
                )
        )
    }
}

struct ThreePointMeteringGuidePopup: View {
    let refined: Bool
    var onDismiss: () -> Void

    private var titleColor: Color {
        refined ? .refinedText : .meterSecondary
    }

    private var secondaryColor: Color {
        refined ? .refinedTextSoft : .meterSecondary.opacity(0.72)
    }

    private var panelFill: Color {
        refined ? .refinedSurface : .meterCardBg.opacity(0.98)
    }

    private var panelStroke: Color {
        refined ? .refinedStroke : Color.black.opacity(0.12)
    }

    private var primaryButtonFill: Color {
        refined ? .refinedPanel : .meterAccent
    }

    private var primaryButtonText: Color {
        refined ? .refinedTextOnDark : .black
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "triangle")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(titleColor)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("2点測光ガイド")
                            .font(.meterValue(14))
                            .foregroundColor(titleColor)
                        Text("補助テキストなしでは、右上の2点で次に中央へ合わせる対象を示します。")
                            .font(.meterLabel(10))
                            .foregroundColor(secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)

                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(secondaryColor)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(refined ? Color.refinedPanel : Color.meterButtonBg.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }

                threePointIndicatorPreview

                VStack(spacing: 8) {
                    threePointGuideRow(
                        target: .highlight,
                        title: "最明部",
                        description: "オレンジが点灯したら、いちばん明るい部分を中央のマスクへ合わせて測光します。"
                    )
                    threePointGuideRow(
                        target: .shadow,
                        title: "最暗部",
                        description: "ブルーが点灯したら、いちばん暗い部分を中央のマスクへ合わせて測光します。"
                    )
                }

                Button {
                    onDismiss()
                } label: {
                    Text("閉じる")
                        .font(.meterValue(12))
                        .foregroundColor(primaryButtonText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(primaryButtonFill)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(panelFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(panelStroke, lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 28, x: 0, y: 12)
            )
            .padding(.horizontal, 24)
        }
    }

    private var threePointIndicatorPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("右上の表示イメージ")
                .font(.meterLabel(10))
                .foregroundColor(secondaryColor)

            HStack(spacing: 18) {
                threePointPreviewSlot(title: "最明", target: .highlight)
                threePointPreviewSlot(title: "最暗", target: .shadow)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(refined ? Color.refinedPanel : Color.meterSurface.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(refined ? Color.refinedStroke.opacity(0.6) : Color.black.opacity(0.08), lineWidth: 0.5)
                    )
            )
        }
    }

    private func threePointPreviewSlot(title: String, target: ThreePointSampleKind) -> some View {
        VStack(spacing: 6) {
            ThreePointMeteringTargetPairIndicator(
                activeTarget: target,
                refined: refined,
                compact: true
            )
            Text(title)
                .font(.meterLabel(9))
                .foregroundColor(secondaryColor)
        }
        .frame(minWidth: 40)
    }

    private func threePointGuideRow(
        target: ThreePointSampleKind,
        title: String,
        description: String
    ) -> some View {
        let rowTint = threePointMeteringTint(for: target)

        return HStack(alignment: .top, spacing: 10) {
            ThreePointMeteringTargetPairIndicator(
                activeTarget: target,
                refined: refined,
                compact: true
            )
            .frame(width: 40, alignment: .leading)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.meterValue(11))
                    .foregroundColor(titleColor)
                Text(description)
                    .font(.meterLabel(10))
                    .foregroundColor(secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(refined ? Color.refinedPanel : Color.meterSurface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            refined ? rowTint.opacity(0.28) : rowTint.opacity(0.22),
                            lineWidth: 0.5
                        )
                )
        )
    }
}

struct PreviewExposureDeltaReadout: View {
    let status: ExposureStatus
    let evDifference: Double
    let tint: Color
    var compact: Bool = true

    private var isProper: Bool {
        status == .proper
    }

    private var directionSymbol: String {
        switch status {
        case .severeUnderexposure, .underexposure, .slightUnderexposure:
            return "-"
        case .proper:
            return ""
        case .slightOverexposure, .overexposure, .severeOverexposure:
            return "+"
        }
    }

    var body: some View {
        HStack(spacing: compact ? 4 : 6) {
            if isProper {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.18))
                        .frame(width: compact ? 12 : 14, height: compact ? 12 : 14)
                    Circle()
                        .fill(tint)
                        .frame(width: compact ? 5 : 6, height: compact ? 5 : 6)
                }
            } else {
                Text(directionSymbol)
                    .font(.system(size: compact ? 11 : 12, weight: .black, design: .monospaced))
                    .foregroundColor(tint)
            }

            Text(evDifference.evString)
                .font(.meterValue(compact ? 9 : 11))
                .tracking(0.35)
                .foregroundColor(.white.opacity(0.95))
                .monospacedDigit()
        }
    }
}

// MARK: - Exposure Status Badge — 露出状態カプセル（適正/オーバー/アンダー + EV差分）
struct ExposureStatusBadge: View {
    let status: ExposureStatus
    let evDifference: Double
    var refined: Bool = false

    private var statusShapeCount: Int {
        switch status {
        case .severeUnderexposure, .severeOverexposure:
            return 3
        case .underexposure, .overexposure:
            return 2
        case .slightUnderexposure, .slightOverexposure:
            return 1
        case .proper:
            return 1
        }
    }
    
    var body: some View {
        Group {
            if refined {
                HStack(spacing: 7) {
                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(index < statusShapeCount ? status.color : status.color.opacity(0.18))
                                .frame(width: 4, height: status == .proper ? 10 : CGFloat(8 + index * 2))
                        }
                    }

                    Text(evDifference.evString)
                        .font(.meterValue(11))
                        .monospacedDigit()

                    if status != .proper {
                        Image(systemName: status.icon)
                            .font(.system(size: 9, weight: .bold))
                    }
                }
                .foregroundColor(status.color)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.refinedSurface)
                        .overlay(Capsule().stroke(status.color.opacity(0.42), lineWidth: 0.9))
                )
            } else {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(status.color)
                        .frame(width: 4, height: 4)
                    Text(status.displayName)
                        .font(.meterLabel(10))
                        .tracking(0.5)
                    Text("\(evDifference.evString) EV")
                        .font(.meterValue(9))
                        .opacity(0.8)
                }
                .foregroundColor(status.color)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: MeterShape.control)
                        .fill(Color.meterSecondary.opacity(0.88))
                        .overlay(RoundedRectangle(cornerRadius: MeterShape.control).stroke(status.color.opacity(0.6), lineWidth: 1))
                )
            }
        }
    }
}

// MARK: - Recommended Value Display — 推奨値カード（絞り/SS/ISO）青=調整可能、橙=AUTO
struct RecommendedValueDisplay: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var showTitle: Bool = true
    var isAuto: Bool = false
    var autoBorderLineWidth: CGFloat = 1
    let isCalculated: Bool
    let color: Color
    var isAdjustable: Bool = false
    var onIncrement: (() -> Void)? = nil
    var onDecrement: (() -> Void)? = nil
    var refined: Bool = false
    @State private var swipeStepIndex: Int = 0
    @State private var isSwipeActive: Bool = false

    private let swipeStepWidth: CGFloat = 24

    private var valueBoxHeight: CGFloat {
        refined && !showTitle ? 60 : 66
    }

    private var valueFontSize: CGFloat {
        let baseSize: CGFloat = {
            if refined && !showTitle {
                return 26
            }
            return showTitle ? 21 : 23
        }()

        switch value.count {
        case 7...:
            return baseSize - 5
        case 5...6:
            return baseSize - 3
        case 4:
            return baseSize - 1.5
        default:
            return baseSize
        }
    }

    private var subtitleFontSize: CGFloat {
        showTitle ? 10 : 11
    }

    private var displayColor: Color {
        if refined && !showTitle {
            if isAuto { return color == .meterRed ? .meterRed : .refinedText }
            if isAdjustable { return .refinedText }
            if isCalculated { return color == .meterAccent ? .refinedText : color }
            return .refinedText
        }
        if isAuto { return color }
        if isAdjustable { return .meterBlue }
        if isCalculated { return color }
        return .meterSecondary
    }

    var body: some View {
        VStack(spacing: 0) {
            // 値表示ボックス
            VStack(spacing: 3) {
                if refined && !showTitle {
                    Capsule()
                        .fill(displayColor.opacity(isAuto ? 0.9 : 0.65))
                        .frame(width: 18, height: 3)
                        .padding(.bottom, 2)
                }
                if showTitle {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.meterLabel(8))
                            .tracking(1.5)
                            .foregroundColor(refined && !showTitle ? .refinedTextSoft : (isAdjustable ? .meterBlue.opacity(0.7) : .meterSecondary.opacity(0.5)))
                            .textCase(.uppercase)
                    }
                }
                VStack(spacing: 2) {
                    Text(value)
                        .font(.meterValue(valueFontSize))
                        .foregroundColor(displayColor)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(0.62)
                        .monospacedDigit()
                    if let subtitle = subtitle ?? ((refined && !showTitle && isAuto) ? " " : nil) {
                        Text(subtitle)
                            .font(.meterValue(subtitleFontSize))
                            .foregroundColor(self.subtitle != nil ? displayColor : .clear)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                            .frame(height: refined && !showTitle ? 12 : nil)
                    } else if !(refined && !showTitle) {
                        Text(" ")
                            .font(.meterValue(subtitleFontSize))
                            .foregroundColor(.clear)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                    }

                    SwipeArrowRail(
                        tint: displayColor,
                        refined: refined && !showTitle,
                        active: isSwipeActive
                    )
                    .opacity(isAdjustable ? 1 : 0)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: valueBoxHeight)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: MeterShape.box)
                    .fill(refined && !showTitle ? refinedCardBackground : defaultCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: MeterShape.box)
                            .stroke(
                                refined && !showTitle ? refinedCardBorder : defaultCardBorder,
                                lineWidth: refined && !showTitle ? (isAuto ? autoBorderLineWidth : 0.9) : (isAuto ? autoBorderLineWidth : (isAdjustable || isCalculated ? 1 : 0.5))
                            )
                    )
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: MeterShape.box))
        .gesture(valueSwipeGesture)
        .animation(.easeInOut(duration: 0.18), value: isAdjustable)
        .animation(.easeInOut(duration: 0.18), value: isAuto)
    }

    private var valueSwipeGesture: some Gesture {
        DragGesture(minimumDistance: isAdjustable ? 6 : .infinity)
            .onChanged { gesture in
                guard isAdjustable else { return }
                isSwipeActive = true
                let nextStep = Int(gesture.translation.width / swipeStepWidth)
                applySwipeDelta(nextStep - swipeStepIndex)
                swipeStepIndex = nextStep
            }
            .onEnded { _ in
                swipeStepIndex = 0
                isSwipeActive = false
            }
    }

    private func applySwipeDelta(_ delta: Int) {
        guard delta != 0 else { return }
        if delta > 0 {
            for _ in 0..<delta {
                onIncrement?()
                HapticManager.shared.selectionChanged()
            }
        } else {
            for _ in 0..<(-delta) {
                onDecrement?()
                HapticManager.shared.selectionChanged()
            }
        }
    }

    private var defaultCardBackground: Color {
        isAuto ? color.opacity(0.12) : isAdjustable ? Color.meterBlue.opacity(0.08) : isCalculated ? color.opacity(0.12) : Color.meterSurface
    }

    private var defaultCardBorder: Color {
        isAuto ? color : isAdjustable ? Color.meterBlue.opacity(0.35) : isCalculated ? color.opacity(0.4) : Color.black.opacity(0.12)
    }

    private var refinedCardBackground: Color {
        if isAuto { return color == .meterRed ? color.opacity(0.16) : .refinedSurface }
        if isAdjustable { return .refinedSurface }
        if isCalculated { return color == .meterAccent ? .refinedSurface : color.opacity(0.14) }
        return .refinedBackground
    }

    private var refinedCardBorder: Color {
        if isAuto { return color == .meterRed ? color.opacity(0.95) : Color.white.opacity(0.82) }
        if isAdjustable { return .refinedStroke }
        if isCalculated { return color == .meterAccent ? .refinedStroke : color.opacity(0.45) }
        return .refinedStroke
    }
}

struct SwipeArrowRail: View {
    let tint: Color
    let refined: Bool
    let active: Bool

    var body: some View {
        HStack(spacing: refined ? 5 : 6) {
            Image(systemName: "chevron.left")
            Capsule()
                .fill(tint.opacity(active ? 0.9 : (refined ? 0.34 : 0.28)))
                .frame(maxWidth: .infinity)
                .frame(height: refined ? 1.5 : 2)
            Image(systemName: "chevron.right")
        }
        .font(.system(size: refined ? 9 : 10, weight: .bold))
        .foregroundColor(tint.opacity(active ? 0.92 : (refined ? 0.46 : 0.36)))
        .frame(maxWidth: .infinity)
        .padding(.horizontal, refined ? 8 : 10)
        .padding(.top, refined ? 1 : 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Zone System View — ゾーンシステム表示（Mモード時のみ、0〜X段階）
struct ZoneSystemView: View {
    let currentZone: Int

    private let zoneLabels = ["0", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    private let zoneGrays: [Double] = [0.03, 0.08, 0.18, 0.28, 0.38, 0.50, 0.62, 0.72, 0.82, 0.92, 0.98]

    var body: some View {
        VStack(spacing: 3) {
            // ゾーンバー
            HStack(spacing: 1) {
                ForEach(Array(0...10), id: \.self) { zone in
                    let isActive = zone == currentZone
                    Rectangle()
                        .fill(Color(white: zoneGrays[zone]))
                        .frame(height: 16)
                        .overlay(Group {
                            if isActive {
                                Rectangle().stroke(Color.meterAccent, lineWidth: 2)
                            }
                        })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.15), lineWidth: 0.5))

            // ゾーンラベル
            HStack(spacing: 1) {
                ForEach(Array(0...10), id: \.self) { zone in
                    let isActive = zone == currentZone
                    Text(zoneLabels[zone])
                        .font(.system(size: 7, weight: isActive ? .black : .regular, design: .monospaced))
                        .foregroundColor(isActive ? .meterAccent : .meterSecondary.opacity(0.3))
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct CameraStatusOverlayCard: View {
    let error: CameraError
    let refined: Bool
    var onOpenSettingsSheet: (() -> Void)? = nil
    var onOpenShotHistory: (() -> Void)? = nil

    @Environment(\.openURL) private var openURL

    private var backgroundColor: Color {
        refined ? .refinedSurface : .meterCardBg
    }

    private var borderColor: Color {
        refined ? Color.refinedStroke.opacity(0.9) : Color.black.opacity(0.12)
    }

    private var primaryTextColor: Color {
        refined ? .refinedText : .meterSecondary
    }

    private var secondaryTextColor: Color {
        refined ? .refinedTextSoft : .meterSecondary.opacity(0.74)
    }

    private var buttonFillColor: Color {
        refined ? .cyan : .meterAccent
    }

    private var buttonTextColor: Color {
        refined ? .black : .meterBackground
    }

    private var secondaryButtonTextColor: Color {
        refined ? .refinedText : .meterSecondary
    }

    private var secondaryButtonFillColor: Color {
        refined ? .refinedPanel : .meterSurface
    }

    private var secondaryButtonStrokeColor: Color {
        refined ? Color.refinedStroke.opacity(0.72) : Color.black.opacity(0.12)
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill((refined ? Color.cyan : Color.meterAccent).opacity(refined ? 0.18 : 0.16))
                    .frame(width: 58, height: 58)
                Image(systemName: error.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(refined ? .cyan : .meterAccent)
            }

            VStack(spacing: 10) {
                Text(error.promptTitle)
                    .font(.meterValue(16))
                    .foregroundColor(primaryTextColor)
                    .multilineTextAlignment(.center)

                Text(error.promptMessage)
                    .font(.meterLabel(12))
                    .foregroundColor(secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                if let supportingMessage = error.supportingMessage {
                    Text(supportingMessage)
                        .font(.meterLabel(10))
                        .foregroundColor(secondaryTextColor.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }
            }

            if error.showsOpenSettingsButton {
                Button {
                    guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(settingsURL)
                } label: {
                    Text("設定を開く")
                        .font(.meterValue(13))
                        .foregroundColor(buttonTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(buttonFillColor)
                        )
                }
                .buttonStyle(.plain)
            }

            if onOpenSettingsSheet != nil || onOpenShotHistory != nil {
                HStack(spacing: 10) {
                    if let onOpenSettingsSheet {
                        secondaryActionButton(title: "設定", action: onOpenSettingsSheet)
                    }
                    if let onOpenShotHistory {
                        secondaryActionButton(title: "撮影記録", action: onOpenShotHistory)
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 24)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 28)
                        .stroke(borderColor, lineWidth: refined ? 1 : 0.8)
                )
                .shadow(
                    color: refined ? Color.black.opacity(0.28) : Color.black.opacity(0.16),
                    radius: refined ? 26 : 18,
                    y: 10
                )
        )
        .padding(.horizontal, 24)
    }

    private func secondaryActionButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.meterLabel(12))
                .foregroundColor(secondaryButtonTextColor)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(secondaryButtonFillColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(secondaryButtonStrokeColor, lineWidth: 0.8)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}
