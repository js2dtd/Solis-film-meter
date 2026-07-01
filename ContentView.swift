//
//  ContentView.swift
//  Solis film meter
//

// MARK: - 役割: 通常表示の露出計メイン画面
// MARK: - 目次
// 1. ContentView本体と通常/入射光レイアウト切替
// 2. Preview Section（プレビュー、測光オーバーレイ、全画面遷移）
// 3. Header / Current Settings / Zone表示
// 4. Av/Tv/M・露出補正・測光モード操作
// 5. 入射光測定UI、測定安定状態、カメラエラー表示
// 6. スポット/明暗2点測光ガイド、警告、ヘルプ表示

import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var viewModel: ExposureViewModel
    @ObservedObject var cameraManager: LightMeterCameraManager
    @ObservedObject var accessStore: PurchaseAccessStore
    @ObservedObject var shotRecordStore: ShotRecordStore
    @Binding var controlPanelOffset: CGFloat
    let screenWidth: CGFloat
    let visibleFocalLengthMultiplier: Double
    @Binding var showSettings: Bool
    @Binding var showShotHistory: Bool
    let requestFullscreenTransition: () -> Void
    @State private var showMeteringModeHelp: Bool = false
    @State private var selectedSpotWarningGuide: SpotMeteringWarning?
    @State private var showThreePointMeteringGuide: Bool = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                headerView

                GeometryReader { geo in
                    if viewModel.isIncidentMode {
                        VStack(spacing: 0) {
                            Spacer(minLength: 4)
                            incidentOverviewSection
                            Spacer(minLength: 8)
                            currentSettingsView
                            Spacer(minLength: 6)
                            modeSelectionView
                            Spacer(minLength: 6)
                            exposureCompensationView
                            Spacer(minLength: 6)
                            incidentModeView
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 16)
                    } else {
                        let contentFits = geo.size.height >= minimumPanelHeightForStaticLayout

                        if contentFits {
                            reflectivePanelFlexibleStack
                            .padding(.horizontal, 16)
                            .padding(.vertical, compactPanelVerticalPadding)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        } else {
                            ScrollView(showsIndicators: false) {
                                reflectivePanelScrollStack
                                .padding(.horizontal, 16)
                                .padding(.vertical, compactPanelVerticalPadding)
                            }
                            .scrollDisabled(contentFits)
                        }
                    }
                }
            }

            if showMeteringModeHelp {
                meteringModeHelpOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }

            if selectedSpotWarningGuide != nil, usesRefinedNormalUI {
                MeteringWarningGuidePopup(
                    refined: true,
                    onDismiss: dismissSpotWarningGuide
                )
                .transition(.opacity)
                .zIndex(11)
            }

            if showThreePointMeteringGuide, usesRefinedNormalUI {
                ThreePointMeteringGuidePopup(
                    refined: true,
                    onDismiss: dismissThreePointMeteringGuide
                )
                .transition(.opacity)
                .zIndex(12)
            }

            if let cameraError = cameraManager.error {
                cameraStatusOverlay(for: cameraError)
                    .transition(.opacity)
                    .zIndex(13)
            }
        }
        .onChange(of: viewModel.meteringMode) { _, _ in
            selectedSpotWarningGuide = nil
            showThreePointMeteringGuide = false
        }
    }

    private var usesCompactManualLayout: Bool {
        !viewModel.isIncidentMode && viewModel.exposureMode == .manual && usesRefinedInterface
    }

    private var usesAuxiliaryManualOverflowLayout: Bool {
        !viewModel.isIncidentMode && viewModel.exposureMode == .manual && viewModel.showAuxiliaryLabels
    }

    private var usesRefinedInterface: Bool {
        !viewModel.showAuxiliaryLabels
    }

    private var accessPolicy: AppAccessPolicy {
        accessStore.policy
    }

    private var availableMeteringModes: [MeteringMode] {
        viewModel.availableMeteringModes(for: accessPolicy)
    }

    private var compactPanelValueAvailableWidth: CGFloat {
        max(276, screenWidth - 44)
    }

    private var compactPanelSectionSpacing: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return 9
        }
        if usesCompactManualLayout {
            return usesRefinedInterface ? 16 : 15
        }
        return usesRefinedInterface ? 16 : 16
    }

    private var compactPanelVerticalPadding: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return 5
        }
        if usesCompactManualLayout {
            return usesRefinedInterface ? 8 : 6
        }
        return usesRefinedInterface ? 8 : 8
    }

    private var minimumPanelHeightForStaticLayout: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return 760
        }
        return usesCompactManualLayout ? 720 : 580
    }

    private var currentSettingsStackSpacing: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return 6
        }
        return usesCompactManualLayout ? 8 : compactPanelSectionSpacing
    }

    private var outOfRangeWarningTopAdjustment: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return -4
        }
        return viewModel.showAuxiliaryLabels ? -6 : -2
    }

    private var valueCardHorizontalSpacing: CGFloat {
        viewModel.showAuxiliaryLabels ? 6 : 6
    }

    private var reflectivePanelFlexibleStack: some View {
        VStack(spacing: compactPanelSectionSpacing) {
            previewSection
            currentSettingsView
            modeSelectionView
            exposureCompensationView
            meteringModeView
        }
    }

    private var reflectivePanelScrollStack: some View {
        VStack(spacing: compactPanelSectionSpacing) {
            previewSection
            currentSettingsView
            modeSelectionView
            exposureCompensationView
            meteringModeView
        }
    }

    // MARK: - Preview Section — カメラプレビュー画像（187×280px、露出シミュレーション付き）
    private var previewSection: some View {
        return VStack(spacing: usesCompactManualLayout ? 4 : 8) {
            ZStack {
                if cameraManager.isAuthorized && cameraManager.isRunning {
                    RoundedRectangle(cornerRadius: MeterShape.preview)
                        .fill(Color.clear)
                        .frame(width: 187, height: 280)
                        .clipShape(RoundedRectangle(cornerRadius: MeterShape.preview))
                } else {
                    RoundedRectangle(cornerRadius: MeterShape.preview)
                        .fill(usesRefinedInterface ? Color.refinedSurface.opacity(0.96) : Color.black.opacity(0.5))
                        .frame(width: 187, height: 280)
                        .overlay(
                            VStack(spacing: 8) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 28, weight: .medium))
                                Text("カメラを準備しています")
                                    .font(.meterLabel(12))
                                    .tracking(1)
                            }
                            .foregroundColor(usesRefinedInterface ? .refinedTextSoft.opacity(0.72) : .meterSecondary.opacity(0.5))
                        )
                }

                // 入射光モードバッジ
                if viewModel.isIncidentMode {
                    VStack {
                        HStack {
                            Text("INCIDENT")
                                .font(.system(size: 8, weight: .black, design: .monospaced))
                                .tracking(1)
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: MeterShape.control).fill(Color.cyan))
                            Spacer()
                        }
                        .padding(8)
                        Spacer()
                    }
                    .frame(width: 187, height: 280)
                    .allowsHitTesting(false)
                }

                // オーバーレイ情報
                previewOverlay
                    .allowsHitTesting(false)

                if !viewModel.isIncidentMode && (viewModel.meteringMode == .spot || viewModel.meteringMode == .threePoint) {
                    meteringModeOverlay
                        .allowsHitTesting(false)
                }

                if shouldShowSpotResetOverlay {
                    spotResetOverlay
                        .allowsHitTesting(false)
                }

                if shouldShowPreviewSpotWarningIndicator {
                    previewSpotWarningIndicatorOverlay
                }

                // 露出状態の枠
                RoundedRectangle(cornerRadius: MeterShape.preview)
                    .stroke(viewModel.exposureStatus.color, lineWidth: 3)
                    .allowsHitTesting(false)
            }
            .frame(width: 187, height: 280)
            .background(SharedPreviewSurfaceReporter(id: .panel))
            .contentShape(RoundedRectangle(cornerRadius: MeterShape.preview))
            .onTapGesture {
                guard cameraManager.error == nil else { return }
                requestFullscreenTransition()
            }

        }
    }

    @ViewBuilder
    private func cameraStatusOverlay(for error: CameraError) -> some View {
        ZStack {
            (usesRefinedInterface ? Color.black.opacity(0.26) : Color.black.opacity(0.18))
                .ignoresSafeArea()
            CameraStatusOverlayCard(
                error: error,
                refined: usesRefinedInterface,
                onOpenSettingsSheet: { showSettings = true },
                onOpenShotHistory: accessPolicy.allows(.shotRecords) ? { showShotHistory = true } : nil
            )
        }
    }

    private var incidentOverviewSection: some View {
        let usesRefinedIncidentUI = !viewModel.showAuxiliaryLabels
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Image(systemName: "sun.max.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("入射光測定")
                        .font(.meterValue(12))
                        .foregroundColor(usesRefinedIncidentUI ? .refinedText : .meterSecondary)
                    Text("プレビューは使わず、フロントカメラで光を測定します")
                        .font(.meterLabel(10))
                        .foregroundColor(usesRefinedIncidentUI ? .refinedTextSoft : .meterSecondary.opacity(0.65))
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("1. フロントカメラを光源側へ向ける")
                Text("2. カメラまわりを手やケースで遮らない")
                Text("3. 値が落ち着いたら HOLD")
            }
            .font(.meterLabel(10))
            .foregroundColor(usesRefinedIncidentUI ? .refinedTextSoft : .meterSecondary.opacity(0.72))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: MeterShape.card)
                .fill(usesRefinedIncidentUI ? Color.refinedSurface : Color.meterSurface)
                .overlay(RoundedRectangle(cornerRadius: MeterShape.card).stroke(usesRefinedIncidentUI ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5))
        )
    }

    private var previewOverlay: some View {
        VStack(spacing: 0) {
            if viewModel.meteringMode == .threePoint && viewModel.showAuxiliaryLabels {
                HStack {
                    Spacer()
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(previewBadgeTint)
                            .frame(width: 5, height: 5)
                        Text("2POINT")
                            .font(.meterLabel(9))
                            .tracking(0.5)
                            .foregroundColor(.white)
                        if let pendingKind = cameraManager.threePointPendingKind {
                            Text(
                                viewModel.showAuxiliaryLabels
                                    ? threePointMeteringBannerText(for: pendingKind)
                                    : "SET"
                            )
                                .font(.meterLabel(8))
                                .tracking(0.3)
                                .foregroundColor(.white.opacity(0.82))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        } else if cameraManager.isReflectiveMeasurementInProgress {
                            Text("測光中")
                                .font(.meterLabel(8))
                                .tracking(0.3)
                                .foregroundColor(.white.opacity(0.82))
                        } else if let threePoint = cameraManager.threePointMetering {
                            Text("DR \(String(format: "%.1f", threePoint.dynamicRangeEV))")
                                .font(.meterLabel(8))
                                .tracking(0.3)
                                .foregroundColor(.white.opacity(0.82))
                        } else {
                            Text("SET")
                                .font(.meterLabel(8))
                                .tracking(0.3)
                                .foregroundColor(.white.opacity(0.82))
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(
                        Group {
                            if usesRefinedNormalUI {
                                Capsule()
                                    .fill(Color.black.opacity(0.32))
                                    .overlay(Capsule().stroke(previewBadgeTint.opacity(0.52), lineWidth: 0.8))
                            } else {
                                RoundedRectangle(cornerRadius: MeterShape.control)
                                    .fill(previewBadgeTint.opacity(0.30))
                                    .overlay(RoundedRectangle(cornerRadius: MeterShape.control).stroke(previewBadgeTint.opacity(0.5), lineWidth: 0.5))
                            }
                        }
                    )
                    .padding(8)
                }
            }

            Spacer()

            EmptyView()
        }
        .frame(width: 187, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: MeterShape.preview))
    }

    private var meteringModeOverlay: some View {
        let isThreePoint = viewModel.meteringMode == .threePoint
        let title = isThreePoint ? "2点測光中" : "スポット測光中"
        let icon = isThreePoint ? "triangle" : "scope"
        let subtitle = isThreePoint ? "最明部と最暗部を中央で順に測ってください" : nil

        return ZStack {
            RoundedRectangle(cornerRadius: MeterShape.preview)
                .fill(Color.black.opacity(0.32))

            VStack(spacing: subtitle == nil ? 4 : 6) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(title)
                    .font(.meterValue(12))
                    .tracking(0.6)
                if let subtitle {
                    Text(subtitle)
                        .font(.meterLabel(9))
                        .tracking(0.3)
                        .foregroundColor(.white.opacity(0.82))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.38))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
        .frame(width: 187, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: MeterShape.preview))
    }

    private var shouldShowSpotResetOverlay: Bool {
        !viewModel.isIncidentMode &&
        viewModel.meteringMode == .spot &&
        cameraManager.spotMeteringWarning.isBrightArea &&
        !usesRefinedNormalUI
    }

    private var currentPreviewSpotWarning: SpotMeteringWarning {
        guard !viewModel.isIncidentMode, viewModel.meteringMode == .spot else { return .none }
        return cameraManager.spotMeteringWarning
    }

    private var currentPreviewThreePointTarget: ThreePointSampleKind? {
        guard !viewModel.isIncidentMode, viewModel.meteringMode == .threePoint else { return nil }
        return cameraManager.threePointPendingKind
    }

    private var shouldShowPanelThreePointPairIndicator: Bool {
        currentPreviewThreePointTarget != nil && usesRefinedNormalUI
    }

    private var shouldShowPreviewSpotWarningIndicator: Bool {
        if currentPreviewThreePointTarget != nil {
            return shouldShowPanelThreePointPairIndicator
        }
        if usesRefinedNormalUI {
            return !viewModel.isIncidentMode && viewModel.meteringMode == .spot
        }
        return currentPreviewSpotWarning.isOffTarget
    }

    private var spotResetOverlay: some View {
        ZStack {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.system(size: 12, weight: .medium))
                    Text("測光場所を変えてください")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundColor(Color.white.opacity(0.9))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.22))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                )
                .padding(.bottom, 42)
            }
        }
        .frame(width: 187, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: MeterShape.preview))
    }

    private var previewSpotWarningIndicatorOverlay: some View {
        VStack {
            HStack {
                if let pendingTarget = currentPreviewThreePointTarget, shouldShowPanelThreePointPairIndicator {
                    Spacer()
                    Button {
                        presentThreePointMeteringGuide()
                    } label: {
                        ThreePointMeteringTargetPairIndicator(
                            activeTarget: pendingTarget,
                            refined: true,
                            compact: true
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("2点測光ガイドを表示")
                    .padding(.top, 10)
                    .padding(.trailing, 10)
                } else if usesRefinedNormalUI {
                    MeteringWarningPairIndicator(
                        activeWarning: currentPreviewSpotWarning,
                        refined: usesRefinedNormalUI,
                        compact: true,
                        onTap: presentSpotWarningGuide
                    )
                    .padding(.top, 10)
                    .padding(.leading, 10)
                } else {
                    MeteringWarningTextChip(
                        warning: currentPreviewSpotWarning,
                        refined: false,
                        compact: true
                    )
                    .padding(.top, 8)
                    .padding(.leading, 8)
                }
                if !(currentPreviewThreePointTarget != nil && shouldShowPanelThreePointPairIndicator) {
                    Spacer()
                }
            }
            Spacer()
        }
        .frame(width: 187, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: MeterShape.preview))
    }

    private func presentSpotWarningGuide(_ warning: SpotMeteringWarning) {
        guard warning == .brightArea || warning == .offTarget else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedSpotWarningGuide = warning
        }
    }

    private func dismissSpotWarningGuide() {
        withAnimation(.easeInOut(duration: 0.18)) {
            selectedSpotWarningGuide = nil
        }
    }

    private func presentThreePointMeteringGuide() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showThreePointMeteringGuide = true
        }
    }

    private func dismissThreePointMeteringGuide() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showThreePointMeteringGuide = false
        }
    }

    private var previewParameterBar: some View {
        EmptyView()
    }

    private var currentAperture: Aperture {
        viewModel.exposureMode == .shutterPriority
            ? (viewModel.recommendedAperture ?? viewModel.aperture)
            : viewModel.aperture
    }

    private var currentShutterSpeed: ShutterSpeed {
        viewModel.exposureMode == .aperturePriority
            ? (viewModel.recommendedShutterSpeed ?? viewModel.shutterSpeed)
            : viewModel.shutterSpeed
    }

    private var currentLensStatusText: String {
        return cameraManager.isZoomLensPreset
            ? (viewModel.showAuxiliaryLabels ? "ズーム \(cameraManager.currentLensDisplay)" : cameraManager.currentLensDisplay)
            : cameraManager.currentLensDisplay
    }

    private var previewBadgeTint: Color {
        if viewModel.showAuxiliaryLabels,
           viewModel.meteringMode == .threePoint,
           let pendingKind = cameraManager.threePointPendingKind {
            return threePointMeteringTint(for: pendingKind)
        }
        if viewModel.meteringMode == .spot, cameraManager.spotMeteringWarning.isBrightArea {
            return .meterRed
        }
        return viewModel.exposureStatus.color
    }

    private var autoRecommendationTint: Color {
        if viewModel.meteringMode == .spot, cameraManager.spotMeteringWarning.isBrightArea {
            return .meterRed
        }
        return .meterAccent
    }

    private var autoRecommendationBorderWidth: CGFloat {
        if viewModel.meteringMode == .spot {
            switch cameraManager.spotMeteringWarning {
            case .none:
                break
            case .brightArea:
                return 3
            case .offTarget:
                break
            }
        }
        return 1
    }

    private var isTwoPointResultReady: Bool {
        viewModel.meteringMode != .threePoint || cameraManager.threePointMetering != nil
    }

    private var autoApertureDisplayValue: String {
        guard isTwoPointResultReady else { return "--" }
        return viewModel.recommendedAperture?.displayString ?? "---"
    }

    private var autoShutterDisplayValue: String {
        guard isTwoPointResultReady else { return "--" }
        return viewModel.recommendedShutterDisplayString ?? "---"
    }

    private var autoShutterSubtitle: String? {
        guard isTwoPointResultReady else { return nil }
        return viewModel.reciprocityCorrectedTime.map { "補正: \(formatCorrectedTime($0))" }
    }

    // MARK: - Header — アプリタイトル + 設定/履歴ボタン
    private var headerView: some View {
        ZStack {
            VStack(spacing: 3) {
                Text("Solis film meter")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .tracking(4)
                    .foregroundColor(usesRefinedInterface ? .refinedText : .meterAccent)
                HStack(spacing: 6) {
                    Rectangle().fill((usesRefinedInterface ? Color.refinedTextSoft : Color.meterSecondary).opacity(0.3)).frame(width: 20, height: 0.5)
                    Text("露出計")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .tracking(3)
                        .foregroundColor((usesRefinedInterface ? Color.refinedTextSoft : Color.meterSecondary).opacity(0.5))
                    Rectangle().fill((usesRefinedInterface ? Color.refinedTextSoft : Color.meterSecondary).opacity(0.3)).frame(width: 20, height: 0.5)
                }
            }

            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 20)).foregroundColor(usesRefinedInterface ? .refinedText : .meterSecondary)
                }
                Spacer()
                if accessPolicy.allows(.shotRecords) {
                    Button { showShotHistory = true } label: {
                        Image(systemName: "list.bullet").font(.system(size: 18)).foregroundColor(usesRefinedInterface ? .refinedText : .meterSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, panelHeaderTopPadding)
        .padding(.bottom, usesRefinedInterface ? 10 : 12)
        .background(usesRefinedInterface ? Color.refinedSurface.opacity(0.94) : Color.black.opacity(0.3))
    }

    private var panelHeaderTopPadding: CGFloat {
        max(12, currentTopSafeAreaInset + 8)
    }

    private var currentTopSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    // MARK: - Current Settings + Zone — AEL/露出ステータス/推奨値/ゾーンシステム表示
    private var currentSettingsView: some View {
        VStack(spacing: currentSettingsStackSpacing) {
            HStack(spacing: max(8, currentSettingsStackSpacing)) {
                if accessPolicy.allows(.autoExposureLock) {
                    aelButton
                }
                ExposureStatusBadge(status: viewModel.exposureStatus, evDifference: viewModel.evDifference, refined: usesRefinedInterface)
                if viewModel.showEVValue {
                    topInfoChip(
                        text: "EV \(String(format: "%.1f", viewModel.measuredEV))",
                        tint: viewModel.isLocked
                            ? (usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.5))
                            : (usesRefinedInterface ? .refinedText : .meterAccent)
                    )
                }
                if !viewModel.isIncidentMode {
                    topInfoChip(
                        text: currentLensStatusText,
                        tint: usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.7)
                    )
                }
            }

            recommendedValuesRow
            if viewModel.isIncidentMode {
                incidentMeasurementPanel
            }

            if !viewModel.isWithinRange {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("設定範囲外です")
                }
                .font(.meterLabel(12))
                .foregroundColor(.meterRed)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.meterRed.opacity(0.15)))
                .padding(.top, outOfRangeWarningTopAdjustment)
            }

            if !viewModel.isIncidentMode && viewModel.exposureMode == .manual {
                ZoneSystemView(currentZone: viewModel.currentZone)
            }
        }
    }

    private var aelButton: some View {
        let locked = viewModel.isLocked
        let isTwoPointMetering = !viewModel.isIncidentMode && viewModel.meteringMode == .threePoint
        let usesRefinedInterface = !viewModel.showAuxiliaryLabels
        return Button {
            guard !isTwoPointMetering else { return }
            viewModel.toggleLock()
            locked ? cameraManager.unlockExposure() : cameraManager.lockExposure()
        } label: {
            Text("AEL")
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundColor(
                    isTwoPointMetering
                        ? .meterSecondary.opacity(0.35)
                        : (locked ? (usesRefinedInterface ? .refinedBackground : .black) : (usesRefinedInterface ? .refinedText : .meterSecondary))
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: MeterShape.control)
                        .fill(
                            isTwoPointMetering
                                ? Color.meterButtonBg.opacity(0.5)
                                : (locked ? Color.cyan : (usesRefinedInterface ? Color.refinedPanel : Color.meterButtonBg))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: MeterShape.control)
                                .stroke(locked ? Color.cyan.opacity(0.75) : (usesRefinedInterface ? Color.refinedStroke : Color.black.opacity(0.2)), lineWidth: 0.5)
                        )
                )
        }
        .buttonStyle(.plain)
        .disabled(isTwoPointMetering)
    }

    private var incidentMeasurementPanel: some View {
        let usesRefinedIncidentUI = !viewModel.showAuxiliaryLabels
        return VStack(spacing: 8) {
            HStack {
                Text("測定状態")
                    .font(.meterLabel(10))
                    .foregroundColor(usesRefinedIncidentUI ? .refinedTextSoft : .meterSecondary.opacity(0.65))
                Spacer()
                Text(viewModel.isLocked ? "値を保持中" : cameraManager.measurementStateText)
                    .font(.meterValue(11))
                    .foregroundColor(incidentStatusColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: MeterShape.control)
                        .fill(usesRefinedIncidentUI ? Color.refinedPanel : Color.black.opacity(0.08))
                    RoundedRectangle(cornerRadius: MeterShape.control)
                        .fill(incidentStatusColor)
                        .frame(width: max(4, geo.size.width * cameraManager.measurementStability))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: MeterShape.box)
                .fill(usesRefinedIncidentUI ? Color.refinedSurface : Color.meterSurface)
                .overlay(RoundedRectangle(cornerRadius: MeterShape.box).stroke(usesRefinedIncidentUI ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5))
        )
    }

    private var recommendedValuesRow: some View {
        let mode = viewModel.exposureMode
        let isManual = mode == .manual
        let isAv = mode == .aperturePriority
        let isTv = mode == .shutterPriority
        let apertureAdjustable = !isTv  // Tv以外は絞り調整可能
        let ssAdjustable = !isAv        // Av以外はSS調整可能
        let ssValue = isAv
            ? autoShutterDisplayValue
            : viewModel.effectiveShutterDisplayString

        return GeometryReader { geo in
            let spacing = valueCardHorizontalSpacing
            let rowWidth = geo.size.width
            let widths = valueCardWidths(totalWidth: rowWidth, spacing: spacing)
            HStack(spacing: spacing) {
                if usesRefinedInterface && !viewModel.isIncidentMode {
                    CompactValueControl(
                        title: "絞り",
                        value: isTv ? autoApertureDisplayValue : viewModel.aperture.displayString,
                        showTitle: false,
                        refined: true,
                        presentation: .panel,
                        isAuto: isTv,
                        autoTint: autoRecommendationTint,
                        autoBorderLineWidth: autoRecommendationBorderWidth,
                        isEnabled: apertureAdjustable,
                        isCalculated: isTv || isManual,
                        onIncrement: { viewModel.adjustAperture(by: 1, emitHaptics: false) },
                        onDecrement: { viewModel.adjustAperture(by: -1, emitHaptics: false) }
                    )
                    .frame(width: widths[0])

                    CompactValueControl(
                        title: "SS",
                        value: ssValue,
                        subtitle: isAv ? autoShutterSubtitle : viewModel.reciprocityCorrectedTime.map { "補正:\(formatCorrectedTime($0))" },
                        showTitle: false,
                        refined: true,
                        presentation: .panel,
                        isAuto: isAv,
                        autoTint: autoRecommendationTint,
                        autoBorderLineWidth: autoRecommendationBorderWidth,
                        isEnabled: ssAdjustable,
                        isCalculated: isAv || isManual,
                        onIncrement: { viewModel.adjustShutterSpeed(by: 1, emitHaptics: false) },
                        onDecrement: { viewModel.adjustShutterSpeed(by: -1, emitHaptics: false) }
                    )
                    .frame(width: widths[1])

                    CompactValueControl(
                        title: "ISO",
                        value: "\(viewModel.iso.rawValue)",
                        showTitle: false,
                        refined: true,
                        presentation: .panel,
                        isEnabled: true,
                        isCalculated: isManual,
                        onIncrement: { adjustISO(by: 1, emitHaptics: false) },
                        onDecrement: { adjustISO(by: -1, emitHaptics: false) }
                    )
                    .frame(width: widths[2])
                } else {
                    RecommendedValueDisplay(
                        title: "絞り",
                        value: isTv
                            ? autoApertureDisplayValue
                            : viewModel.aperture.displayString,
                        showTitle: viewModel.showAuxiliaryLabels,
                        isAuto: isTv,
                        autoBorderLineWidth: autoRecommendationBorderWidth,
                        isCalculated: isTv || isManual,
                        color: autoRecommendationTint,
                        isAdjustable: apertureAdjustable,
                        onIncrement: { viewModel.adjustAperture(by: 1, emitHaptics: false) },
                        onDecrement: { viewModel.adjustAperture(by: -1, emitHaptics: false) },
                        refined: usesRefinedInterface
                    )
                    .frame(width: widths[0])
                    RecommendedValueDisplay(
                        title: "シャッター",
                        value: ssValue,
                        subtitle: isAv ? autoShutterSubtitle : viewModel.reciprocityCorrectedTime.map { "補正: \(formatCorrectedTime($0))" },
                        showTitle: viewModel.showAuxiliaryLabels,
                        isAuto: isAv,
                        autoBorderLineWidth: autoRecommendationBorderWidth,
                        isCalculated: isAv || isManual,
                        color: autoRecommendationTint,
                        isAdjustable: ssAdjustable,
                        onIncrement: { viewModel.adjustShutterSpeed(by: 1, emitHaptics: false) },
                        onDecrement: { viewModel.adjustShutterSpeed(by: -1, emitHaptics: false) },
                        refined: usesRefinedInterface
                    )
                    .frame(width: widths[1])
                    RecommendedValueDisplay(
                        title: "ISO",
                        value: "\(viewModel.iso.rawValue)",
                        showTitle: viewModel.showAuxiliaryLabels,
                        isCalculated: isManual,
                        color: isManual ? .meterAccent : .meterSecondary,
                        isAdjustable: true,
                        onIncrement: { adjustISO(by: 1, emitHaptics: false) },
                        onDecrement: { adjustISO(by: -1, emitHaptics: false) },
                        refined: usesRefinedInterface
                    )
                    .frame(width: widths[2])
                }
            }
            .frame(width: rowWidth)
            .animation(.easeInOut(duration: 0.18), value: viewModel.exposureMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .frame(height: viewModel.showAuxiliaryLabels ? 92 : 84)
    }

    private var valueCardWeights: [CGFloat] {
        switch viewModel.exposureMode {
        case .manual:
            return [0.96, 1.12, 0.96]
        case .aperturePriority:
            return [0.94, 1.20, 0.94]
        case .shutterPriority:
            return [1.04, 1.06, 0.96]
        }
    }

    private func valueCardWidths(totalWidth: CGFloat, spacing: CGFloat) -> [CGFloat] {
        let weights = valueCardWeights
        let usableWidth = max(0, totalWidth - spacing * CGFloat(weights.count - 1))
        let totalWeight = weights.reduce(0, +)
        return weights.map { usableWidth * ($0 / totalWeight) }
    }

    private func adjustISO(by direction: Int, emitHaptics: Bool = true) {
        viewModel.adjustISO(by: direction, emitHaptics: emitHaptics)
    }

    private func formatCorrectedTime(_ seconds: Double) -> String {
        ExposureDurationFormatter.displayString(for: seconds)
    }

    // MARK: - Mode Selection — Av/Tv/Mモード切替
    private var modeSelectionView: some View {
        SegmentedModePicker(
            selectedMode: $viewModel.exposureMode,
            refined: usesRefinedInterface,
            forceLiquidGlass: true,
            compactLiquidGlass: true,
            colorlessLiquidGlass: true,
            prismaticLiquidGlass: true,
            availableModes: viewModel.availableExposureModes
        )
    }

    // MARK: - Exposure Compensation — 露出補正スライダー（-3〜+3EV）
    private var exposureCompensationView: some View {
        ExposureCompensationSlider(value: $viewModel.exposureCompensation, refined: usesRefinedInterface)
            .padding(.horizontal)
    }

    // MARK: - Metering Mode + Incident Light — 測光モード選択 + 入射光測定切替
    private var meteringModeView: some View {
        VStack(spacing: meteringModeSectionSpacing) {
            HStack(spacing: 0) {
                MeteringModePicker(
                    selectedMode: $viewModel.meteringMode,
                    spotReferenceTarget: viewModel.spotMeteringReferenceTarget,
                    showModeLabels: viewModel.showAuxiliaryLabels,
                    availableModes: availableMeteringModes
                )
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showMeteringModeHelp.toggle()
                    }
                } label: {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.meterSecondary.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            if accessPolicy.allows(.incidentMetering) {
                incidentModeButton
            }
        }
    }

    private var meteringModeHelpOverlay: some View {
        ZStack {
            Color.black.opacity(0.24)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showMeteringModeHelp = false
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("測光モードの説明")
                            .font(.meterValue(13))
                            .foregroundColor(usesRefinedNormalUI ? .refinedText : .meterSecondary)
                    }
                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showMeteringModeHelp = false
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(usesRefinedNormalUI ? .refinedTextSoft : .meterSecondary.opacity(0.7))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(usesRefinedNormalUI ? Color.refinedPanel : Color.meterButtonBg.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                }

                VStack(spacing: 8) {
                    ForEach(generatedMeteringHelpEntries) { entry in
                        meteringModeHelpRow(entry)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 360)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(usesRefinedNormalUI ? Color.refinedSurface : Color.meterCardBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(usesRefinedNormalUI ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 24, x: 0, y: 10)
            )
            .padding(.horizontal, 24)
        }
    }

    private var generatedMeteringHelpEntries: [MeteringModeHelpEntry] {
        availableMeteringModes.map { mode in
            MeteringModeHelpEntry(
                mode: mode,
                description: generatedMeteringDescription(for: mode)
            )
        }
    }

    private func generatedMeteringDescription(for mode: MeteringMode) -> String {
        switch mode {
        case .spot:
            return "タップした位置の小さな範囲を重点的に測ります。中心ほど強く見るため、精度を優先する場合は中央付近をタップして測光してください。"
        case .centerWeighted:
            return "画面全体を見ながら中央を強めに測ります。人物や主題を中央付近に置く構図で使いやすいバランス型です。"
        case .matrix:
            return "画面全体を見て中央をやや重視しつつ、極端な明部や暗部の影響を抑えて測ります。明暗差が大きい場面でも偏りを抑えやすい設定です。"
        case .average:
            return "画面全体をほぼ均等に測ります。構図全体の明るさを基準にしたいときに向いています。"
        case .threePoint:
            return "最明部と最暗部を中央のマスクに順に合わせて測ります。中間調は自動で計算するので、画面端のAE補正を避けながら明暗差の大きい場面を測りたいときに向いています。"
        }
    }

    private func meteringModeHelpRow(_ entry: MeteringModeHelpEntry) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.mode.icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(usesRefinedNormalUI ? .cyan : .meterAccent)
                .frame(width: 22, height: 22)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.mode.displayName)
                    .font(.meterValue(11))
                    .foregroundColor(usesRefinedNormalUI ? .refinedText : .meterSecondary)
                Text(entry.description)
                    .font(.meterLabel(10))
                    .foregroundColor(usesRefinedNormalUI ? .refinedTextSoft : .meterSecondary.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(usesRefinedNormalUI ? Color.refinedPanel : Color.meterSurface.opacity(0.55))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(usesRefinedNormalUI ? Color.refinedStroke.opacity(0.6) : Color.black.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private var incidentModeView: some View {
        Group {
            if accessPolicy.allows(.incidentMetering) {
                incidentModeButton
            }
        }
    }

    private var incidentModeButton: some View {
        let active = viewModel.isIncidentMode
        return Button {
            showMeteringModeHelp = false
            if active {
                viewModel.isIncidentMode = false
            } else {
                activateIncidentMode()
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .strokeBorder(active ? Color.cyan : Color.meterSecondary.opacity(0.3), lineWidth: 1.5)
                    .background(Circle().fill(active ? Color.cyan.opacity(0.15) : Color.clear))
                    .frame(width: 11, height: 11)
                Text(active ? "反射光測定に戻る" : incidentModeButtonTitle)
                    .font(.meterLabel(10))
                    .foregroundColor(active ? .cyan : (usesRefinedInterface ? .refinedText : .meterSecondary.opacity(0.6)))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Spacer(minLength: 10)
                if active {
                    Text("INCIDENT")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.5)
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, incidentModeButtonVerticalPadding)
            .frame(maxWidth: incidentModeButtonMaxWidth, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        usesRefinedInterface
                            ? (active ? Color.refinedPanel : Color.refinedSurface)
                            : (active ? Color.meterSecondary.opacity(0.85) : Color.meterButtonBg.opacity(0.5))
                    )
                    .overlay(Capsule(style: .continuous).stroke(
                        usesRefinedInterface
                            ? (active ? Color.cyan.opacity(0.7) : Color.refinedStroke)
                            : (active ? Color.cyan.opacity(0.7) : Color.meterSecondary.opacity(0.15)),
                        lineWidth: active ? 1.5 : 0.5
                    ))
            )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule(style: .continuous))
    }

    private var meteringModeSectionSpacing: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return 3
        }
        if usesCompactManualLayout {
            return usesRefinedInterface ? 10 : 3
        }
        return 6
    }

    private var incidentModeButtonVerticalPadding: CGFloat {
        if usesAuxiliaryManualOverflowLayout {
            return 5
        }
        if usesCompactManualLayout {
            return usesRefinedInterface ? 9 : 6
        }
        return 8
    }

    private var incidentModeButtonMaxWidth: CGFloat {
        if viewModel.showAuxiliaryLabels {
            return 296
        }
        return viewModel.isIncidentMode ? 260 : 220
    }

    private var incidentStatusText: String {
        viewModel.isLocked ? "HOLD" : cameraManager.measurementStateText
    }

    private var incidentStatusColor: Color {
        if viewModel.isLocked {
            return viewModel.showAuxiliaryLabels ? .meterAccent : .cyan
        }
        if cameraManager.measurementStability >= 0.82 {
            return .meterGreen
        }
        return .cyan
    }

    private var incidentStateBadge: some View {
        Text(incidentStatusText)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(incidentStatusColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(incidentStatusColor.opacity(0.12))
                    .overlay(Capsule().stroke(incidentStatusColor.opacity(0.35), lineWidth: 0.6))
            )
    }

    private var incidentStabilityBar: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("安定度")
                    .font(.meterLabel(9))
                    .foregroundColor(.meterSecondary.opacity(0.55))
                Spacer()
                Text("\(Int((cameraManager.measurementStability * 100).rounded()))%")
                    .font(.meterValue(10))
                    .foregroundColor(incidentStatusColor)
                    .monospacedDigit()
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.black.opacity(0.08))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(incidentStatusColor)
                        .frame(width: max(8, geo.size.width * cameraManager.measurementStability))
                }
            }
            .frame(height: 6)
        }
    }

    private func activateIncidentMode() {
        guard accessPolicy.allows(.incidentMetering) else { return }
        showMeteringModeHelp = false
        viewModel.isIncidentMode = true
    }

    private var usesRefinedNormalUI: Bool {
        !viewModel.showAuxiliaryLabels && !viewModel.isIncidentMode
    }

    private var incidentModeButtonTitle: String {
        viewModel.showAuxiliaryLabels ? "入射光測定（フロントカメラ）" : "入射光測定"
    }

    @ViewBuilder
    private func topInfoChip(text: String, tint: Color) -> some View {
        if usesRefinedInterface {
            Text(text)
                .font(.meterValue(10))
                .foregroundColor(tint)
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.refinedSurface)
                        .overlay(Capsule().stroke(Color.refinedStroke.opacity(0.9), lineWidth: 0.7))
                )
        } else {
            Text(text)
                .font(.meterValue(12))
                .foregroundColor(tint)
                .monospacedDigit()
        }
    }
}

private struct MeteringModeHelpEntry: Identifiable {
    let mode: MeteringMode
    let description: String

    var id: String { mode.rawValue }
}
