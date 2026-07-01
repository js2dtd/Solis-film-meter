//
//  FullScreenMeterView.swift
//  Solis film meter
//

// MARK: - 役割: 全画面表示の露出計UI
// MARK: - 目次
// 1. FullScreenMeterView本体と全画面サーフェス
// 2. プレビュー、測光マスク、タップ/ズーム処理
// 3. 上部バー・値カード・下部操作UI・AEL
// 4. スポット/明暗2点測光ガイド、警告、リセット
// 5. 入射光測定UIとHOLD表示
// 6. 撮影メモ、コラージュ生成、写真ライブラリ保存
// 7. 測光ガイドCanvas、Liquid Glass背景、コンパクト値操作部品

import SwiftUI
import AVFoundation
import Photos
import UIKit

struct FullScreenMeterView: View {
    @ObservedObject var cameraManager: LightMeterCameraManager
    @ObservedObject var viewModel: ExposureViewModel
    @ObservedObject var accessStore: PurchaseAccessStore
    @ObservedObject var shotRecordStore: ShotRecordStore
    let activePreset: CameraFilmPreset?
    @Binding var controlPanelOffset: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
    let visibleFocalLengthMultiplier: Double
    @Binding var showSettings: Bool
    @Binding var showShotHistory: Bool
    private let centerActionButtonOuterSize: CGFloat = 60
    private let centerActionButtonInnerSize: CGFloat = 48
    private let shutterButtonVerticalOffset: CGFloat = 5
    private let incidentHoldButtonVerticalOffset: CGFloat = 9
    private let incidentFooterStatusTrailingInset: CGFloat = 34
    private let incidentBottomControlsVerticalOffset: CGFloat = -18
    private let exposureModeCenterOffset: CGFloat = 18
    private let exposureModeButtonSpacing: CGFloat = 5
    private let valueControlsRowVerticalOffset: CGFloat = 10

    @State private var tapPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @State private var tapPointOpacity: Double = 0.3
    @State private var showSaveConfirmation: Bool = false
    @State private var isSaving: Bool = false
    @State private var isPreparingShotSave: Bool = false
    @State private var pendingShotSaveDraft: PendingShotSaveDraft?
    @State private var shotSaveNote: String = ""
    @State private var shotMemoOverlayWindow: AppOverlayWindowController?
    @State private var zoomGestureStartFocalLength: Double?
    @State private var showSpotTapGuidancePopup: Bool = false
    @State private var showShotMemoUpsellPopup: Bool = false
    @State private var hasShownSpotTapGuidanceForCurrentSpotSelection: Bool = false
    @State private var selectedSpotWarningGuide: SpotMeteringWarning?
    @State private var showThreePointMeteringGuide: Bool = false
    @State private var fullscreenPreviewGuideFrame: CGRect = .zero

    private var usesRefinedInterface: Bool {
        !viewModel.showAuxiliaryLabels
    }

    private var accessPolicy: AppAccessPolicy {
        accessStore.policy
    }

    private var isFullscreenSettled: Bool {
        controlPanelOffset >= screenWidth * 0.9
    }

    var body: some View {
        ZStack {
            fullscreenMeterSurface
                .zIndex(0)
        }
        .coordinateSpace(name: "fullScreenMeter")
        .statusBarHidden()
        .onAppear {
            presentSpotTapGuidanceIfNeeded()
        }
        .onChange(of: viewModel.meteringMode) { _, newValue in
            selectedSpotWarningGuide = nil
            showThreePointMeteringGuide = false
            if newValue == .spot {
                hasShownSpotTapGuidanceForCurrentSpotSelection = false
                presentSpotTapGuidanceIfNeeded()
            } else {
                showSpotTapGuidancePopup = false
                hasShownSpotTapGuidanceForCurrentSpotSelection = false
            }
        }
        .onChange(of: accessStore.accessLevel) { _, _ in
            if accessPolicy.allows(.shotRecords) {
                dismissShotMemoUpsell()
            }
        }
        .onChange(of: controlPanelOffset) { _, _ in
            presentSpotTapGuidanceIfNeeded()
        }
        .onChange(of: viewModel.isIncidentMode) { _, isIncident in
            if isIncident {
                showSpotTapGuidancePopup = false
                showThreePointMeteringGuide = false
            } else {
                presentSpotTapGuidanceIfNeeded()
            }
        }
        .onPreferenceChange(FullScreenPreviewGuideFrameKey.self) { newFrame in
            updateFullscreenPreviewGuideFrame(newFrame)
        }
        .onDisappear {
            dismissShotMemoWindow()
        }
    }

    private var fullscreenMeterSurface: some View {
        GeometryReader { rootGeo in
            let layoutSize = CGSize(
                width: max(rootGeo.size.width, screenWidth),
                height: max(rootGeo.size.height, screenHeight)
            )
            let previewGuideFrame = fullscreenPreviewGuideFrame

            ZStack {
                let maskOverscan = max(layoutSize.width, layoutSize.height) * 2
                let expandedScreenSize = CGSize(
                    width: layoutSize.width + maskOverscan * 2,
                    height: layoutSize.height + maskOverscan * 2
                )
                let expandedPreviewFrame = previewGuideFrame.offsetBy(
                    dx: maskOverscan,
                    dy: maskOverscan
                )

                if shouldShowMeteringFrameMask,
                   previewGuideFrame.width > 1,
                   previewGuideFrame.height > 1 {
                    previewOutsideMeteringFrameMask(
                        screenSize: expandedScreenSize,
                        previewFrame: expandedPreviewFrame
                    )
                    .offset(x: -maskOverscan, y: -maskOverscan)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }

                VStack(spacing: 0) {
                    topBar()
                    meterDisplayArea

                    bottomControls()
                }

                if shouldShowCenterTapMask, previewGuideFrame.width > 1, previewGuideFrame.height > 1 {
                    fullScreenMeteringFocusOverlay(
                        screenSize: expandedScreenSize,
                        previewFrame: expandedPreviewFrame
                    )
                    .offset(x: -maskOverscan, y: -maskOverscan)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(8)
                }

                // 保存完了表示
                if showSaveConfirmation {
                    savedOverlay
                }

                if showSpotTapGuidancePopup {
                    spotTapGuidancePopup
                        .transition(.opacity)
                        .zIndex(20)
                }

                if selectedSpotWarningGuide != nil, usesRefinedNormalUI {
                    MeteringWarningGuidePopup(
                        refined: true,
                        onDismiss: dismissSpotWarningGuide
                    )
                    .transition(.opacity)
                    .zIndex(21)
                }

                if showThreePointMeteringGuide, usesRefinedNormalUI {
                    ThreePointMeteringGuidePopup(
                        refined: true,
                        onDismiss: dismissThreePointMeteringGuide
                    )
                    .transition(.opacity)
                    .zIndex(22)
                }

                if showShotMemoUpsellPopup {
                    ShotMemoUpsellPopup(
                        refined: usesRefinedInterface,
                        isProcessing: accessStore.isPurchaseActionInProgress,
                        activePurchasePlan: accessStore.activePurchasePlan,
                        statusMessage: accessStore.purchaseStatusMessage,
                        onPurchaseMonthly: {
                            if viewModel.enableHaptics { HapticManager.shared.lightTap() }
                            accessStore.purchaseFullVersion(plan: .monthly)
                        },
                        onPurchaseLifetime: {
                            if viewModel.enableHaptics { HapticManager.shared.lightTap() }
                            accessStore.purchaseFullVersion(plan: .lifetime)
                        },
                        onRestore: {
                            if viewModel.enableHaptics { HapticManager.shared.lightTap() }
                            accessStore.restorePurchases()
                        },
                        onDismiss: dismissShotMemoUpsell
                    )
                    .transition(.opacity)
                    .zIndex(23)
                }

                if let cameraError = cameraManager.error {
                    cameraStatusOverlay(for: cameraError)
                        .transition(.opacity)
                        .zIndex(24)
                }
            }
            .frame(width: layoutSize.width, height: layoutSize.height)
        }
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard)
    }

    private func updateFullscreenPreviewGuideFrame(_ newFrame: CGRect) {
        guard isValidFullscreenPreviewGuideFrame(newFrame) else { return }
        fullscreenPreviewGuideFrame = newFrame
    }

    private func isValidFullscreenPreviewGuideFrame(_ frame: CGRect) -> Bool {
        frame.width > 1 &&
        frame.height > 1 &&
        frame.origin.x.isFinite &&
        frame.origin.y.isFinite &&
        frame.width.isFinite &&
        frame.height.isFinite
    }

    private func previewOutsideMeteringFrameMask(
        screenSize: CGSize,
        previewFrame: CGRect
    ) -> some View {
        let screenRect = CGRect(origin: .zero, size: screenSize)
        let visibleCutout = previewFrame.intersection(screenRect)

        return PreviewOutsideOverlayShape(
            cutout: visibleCutout.isNull ? .zero : visibleCutout,
            cornerRadius: MeterShape.preview
        )
        .fill(Color.black.opacity(usesRefinedInterface ? 0.28 : 0.22), style: FillStyle(eoFill: true))
        .frame(width: screenSize.width, height: screenSize.height)
        .clipped()
    }

    private var meterDisplayArea: some View {
        GeometryReader { meterGeo in
            if viewModel.isIncidentMode {
                incidentMeasurementArea(size: meterGeo.size)
            } else {
                reflectivePreviewArea(size: meterGeo.size)
            }
        }
    }

    private func reflectivePreviewArea(size: CGSize) -> some View {
        let areaWidth = max(1, size.width)
        let areaHeight = max(1, size.height)
        let previewWidth = max(1, areaWidth)
        let previewHeight = max(1, previewWidth * 3 / 2)

        return ZStack {
            Color.clear
                .frame(width: areaWidth, height: areaHeight)
                .allowsHitTesting(false)

            if cameraManager.isAuthorized && cameraManager.isRunning && previewWidth > 10 && previewHeight > 10 {
                RoundedRectangle(cornerRadius: MeterShape.preview)
                    .fill(Color.clear)
                    .frame(width: previewWidth, height: previewHeight)
                    .background(
                        ZStack {
                            SharedPreviewSurfaceReporter(id: .fullscreen)
                            GeometryReader { proxy in
                                Color.clear
                                    .preference(
                                        key: FullScreenPreviewGuideFrameKey.self,
                                        value: proxy.frame(in: .named("fullScreenMeter"))
                                    )
                            }
                        }
                    )
                    .clipShape(RoundedRectangle(cornerRadius: MeterShape.preview))
                    .overlay(
                        MeteringGuideOverlay(
                            mode: viewModel.meteringMode,
                            width: previewWidth,
                            height: previewHeight,
                            spotPoint: tapPoint,
                            spotOpacity: tapPointOpacity,
                            threePointMetering: cameraManager.threePointMetering,
                            threePointSelectionMarkers: cameraManager.threePointSelectionMarkers
                        )
                    )
                    .overlay {
                        if shouldShowCenterTapMask {
                            spotTapGuidanceOverlay(
                                previewWidth: previewWidth,
                                previewHeight: previewHeight
                            )
                        }
                    }
                    .overlay(alignment: reflectiveExposureBannerAlignment) {
                        reflectiveExposureBanner
                            .padding(.top, 12)
                            .padding(.horizontal, 12)
                            .allowsHitTesting(false)
                    }
                    .overlay {
                        if shouldShowSpotResetOverlay {
                            spotResetOverlay
                                .frame(width: previewWidth, height: previewHeight)
                                .allowsHitTesting(false)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if shouldShowPreviewSpotWarningIndicator {
                            previewSpotWarningIndicator
                                .padding(.top, 12)
                                .padding(.leading, 12)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if shouldShowThreePointPairIndicator {
                            previewThreePointIndicator
                                .padding(.top, 12)
                                .padding(.trailing, 12)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: MeterShape.preview))
                    .onTapGesture { location in
                        let relativeX = location.x / previewWidth
                        let relativeY = location.y / previewHeight
                        guard relativeX >= 0, relativeX <= 1, relativeY >= 0, relativeY <= 1 else { return }
                        handleTap(
                            location: location,
                            relativeX: relativeX,
                            relativeY: relativeY,
                            previewSize: CGSize(width: previewWidth, height: previewHeight)
                        )
                    }
                    .simultaneousGesture(fullscreenZoomGesture)
            } else {
                RoundedRectangle(cornerRadius: MeterShape.preview)
                    .fill(usesRefinedInterface ? Color.refinedSurface.opacity(0.96) : Color.black.opacity(0.5))
                    .frame(width: previewWidth, height: previewHeight)
                    .overlay {
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 34, weight: .medium))
                            Text("カメラを準備しています")
                                .font(.meterLabel(12))
                                .tracking(1)
                        }
                        .foregroundColor(usesRefinedInterface ? .refinedTextSoft.opacity(0.74) : .meterSecondary.opacity(0.52))
                    }
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func cameraStatusOverlay(for error: CameraError) -> some View {
        ZStack {
            (usesRefinedInterface ? Color.black.opacity(0.34) : Color.black.opacity(0.22))
                .ignoresSafeArea()
            CameraStatusOverlayCard(
                error: error,
                refined: usesRefinedInterface,
                onOpenSettingsSheet: { showSettings = true },
                onOpenShotHistory: accessPolicy.allows(.shotRecords) ? { showShotHistory = true } : nil
            )
        }
    }

    private func formatCorrectedTime(_ seconds: Double) -> String {
        ExposureDurationFormatter.displayString(for: seconds)
    }

    private var reflectiveExposureBanner: some View {
        let spotWarning = cameraManager.spotMeteringWarning
        let tint = bannerTintColor(for: spotWarning)
        return Group {
            if usesRefinedNormalUI, viewModel.meteringMode != .threePoint {
                PreviewExposureDeltaReadout(
                    status: viewModel.exposureStatus,
                    evDifference: viewModel.evDifference,
                    tint: tint,
                    compact: false
                )
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.34))
                        .overlay(
                            Capsule()
                                .stroke(tint.opacity(0.6), lineWidth: 0.9)
                        )
                )
            } else {
                HStack(spacing: 8) {
                    if viewModel.meteringMode == .threePoint {
                        Image(systemName: "triangle")
                            .font(.system(size: 11, weight: .bold))
                        if let pendingKind = cameraManager.threePointPendingKind {
                            Text("2POINT")
                                .font(.meterValue(12))
                            if viewModel.showAuxiliaryLabels {
                                Text(threePointMeteringBannerText(for: pendingKind))
                                    .font(.meterValue(11))
                                    .opacity(0.85)
                            } else if cameraManager.measurementStateText == "安定してからタップ" {
                                Text("安定してからタップ")
                                    .font(.meterValue(11))
                                    .opacity(0.85)
                            }
                        } else if let threePoint = cameraManager.threePointMetering {
                            Text("2POINT")
                                .font(.meterValue(12))
                            Text("中間 \(String(format: "%.1f", threePoint.midtone.ev))")
                                .font(.meterValue(11))
                                .monospacedDigit()
                                .opacity(0.9)
                            Text("DR \(String(format: "%.1f", threePoint.dynamicRangeEV))EV")
                                .font(.meterValue(11))
                                .monospacedDigit()
                                .opacity(0.85)
                        } else {
                            Text("2POINT")
                                .font(.meterValue(12))
                            Text(cameraManager.measurementStateText)
                                .font(.meterValue(11))
                                .opacity(0.85)
                        }
                    } else {
                        Image(systemName: viewModel.exposureStatus.icon)
                            .font(.system(size: 12, weight: .bold))
                        Text(viewModel.exposureStatus.displayName)
                            .font(.meterValue(12))
                        if viewModel.meteringMode == .spot, spotWarning.isBrightArea, let warningText = spotWarning.detailText {
                            Text(warningText)
                                .font(.meterValue(11))
                                .opacity(0.9)
                        } else {
                            Text("\(viewModel.evDifference.evString) EV")
                                .font(.meterValue(11))
                                .monospacedDigit()
                                .opacity(0.85)
                        }
                    }
                }
                .foregroundColor(tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Group {
                        if usesRefinedNormalUI {
                            Capsule()
                                .fill(Color.black.opacity(0.34))
                                .overlay(
                                    Capsule()
                                        .stroke(tint.opacity(0.6), lineWidth: 0.9)
                                )
                        } else {
                            Capsule()
                                .fill(Color.meterSecondary.opacity(0.9))
                                .overlay(
                                    Capsule()
                                        .stroke(tint, lineWidth: 1)
                                )
                        }
                    }
                )
            }
        }
    }

    private var reflectiveExposureBannerAlignment: Alignment {
        usesRefinedNormalUI && viewModel.meteringMode != .threePoint ? .topTrailing : .top
    }

    private func bannerTintColor(for warning: SpotMeteringWarning) -> Color {
        if viewModel.showAuxiliaryLabels,
           viewModel.meteringMode == .threePoint,
           let pendingKind = cameraManager.threePointPendingKind {
            return threePointMeteringTint(for: pendingKind)
        }
        if viewModel.meteringMode == .spot, warning.isBrightArea {
            return .meterRed
        }
        return viewModel.exposureStatus.color
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

    private var shouldShowThreePointPairIndicator: Bool {
        currentPreviewThreePointTarget != nil && usesRefinedNormalUI
    }

    private var shouldShowPreviewSpotWarningIndicator: Bool {
        if currentPreviewThreePointTarget != nil {
            return false
        }
        if usesRefinedNormalUI {
            return !viewModel.isIncidentMode && viewModel.meteringMode == .spot
        }
        return currentPreviewSpotWarning.isOffTarget
    }

    private var shouldShowThreePointResetButton: Bool {
        !viewModel.isIncidentMode &&
        viewModel.meteringMode == .threePoint &&
        cameraManager.threePointMetering != nil
    }

    private var spotResetOverlay: some View {
        ZStack {
            VStack {
                Spacer()
                HStack(spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 15, weight: .medium))
                    Text("測光場所を変えてください")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(Color.white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.24))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                )
                .padding(.bottom, 24)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var previewSpotWarningIndicator: some View {
        Group {
            if usesRefinedNormalUI {
                MeteringWarningPairIndicator(
                    activeWarning: currentPreviewSpotWarning,
                    refined: usesRefinedNormalUI,
                    onTap: presentSpotWarningGuide
                )
            } else {
                MeteringWarningTextChip(
                    warning: currentPreviewSpotWarning,
                    refined: false
                )
            }
        }
    }

    private var previewThreePointIndicator: some View {
        Group {
            if let pendingTarget = currentPreviewThreePointTarget {
                Button {
                    presentThreePointMeteringGuide()
                } label: {
                    ThreePointMeteringTargetPairIndicator(
                        activeTarget: pendingTarget,
                        refined: true
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("2点測光ガイドを表示")
            }
        }
    }

    private var threePointResetButton: some View {
        Button {
            resetThreePointMetering()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .bold))
                Text("再測光")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundColor(usesRefinedNormalUI ? .refinedText : .white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                FullscreenLiquidGlassBackground(
                    shape: Capsule(),
                    tint: usesRefinedNormalUI ? .cyan : .meterAccent,
                    tintStrength: 0.22,
                    strokeOpacity: 0.34
                )
            )
        }
        .buttonStyle(.plain)
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
        return viewModel.reciprocityCorrectedTime.map { "補正:\(formatCorrectedTime($0))" }
    }

    private func incidentMeasurementArea(size: CGSize) -> some View {
        VStack(spacing: 12) {
            incidentInstructionCard
            incidentStatusPanel
            incidentEVPanel
            incidentSettingsCard

            if !viewModel.isWithinRange {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("設定範囲外です")
                }
                .font(.meterLabel(11))
                .foregroundColor(.meterRed)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color.meterRed.opacity(0.12)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(width: size.width, height: size.height, alignment: .center)
        .background(
            ZStack {
                LinearGradient(
                    colors: [
                        usesRefinedInterface ? Color.refinedSurface : Color.meterSurface.opacity(0.35),
                        usesRefinedInterface ? Color.refinedBackground : Color.meterBackground
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill((usesRefinedInterface ? Color.refinedPanelSoft : Color.cyan).opacity(0.08))
                    .frame(width: 260, height: 260)
                    .blur(radius: 12)
                    .offset(x: -70, y: -90)

                Circle()
                    .fill((usesRefinedInterface ? Color.refinedTextSoft : Color.meterAccent).opacity(0.09))
                    .frame(width: 220, height: 220)
                    .blur(radius: 18)
                    .offset(x: 110, y: 150)
            }
        )
    }

    // MARK: - Saved Overlay — 写真保存完了トースト
    private var savedOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 28))
            Text("保存しました")
                .font(.meterLabel(12))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.75)))
        .transition(.opacity)
    }

    private var screenExposureStatusBorder: some View {
        GeometryReader { proxy in
            ContainerRelativeShape()
                .strokeBorder(
                    viewModel.exposureStatus.color.opacity(0.94),
                    lineWidth: 2.4
                )
                .shadow(color: viewModel.exposureStatus.color.opacity(0.32), radius: 6, x: 0, y: 0)
                .padding(5)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .ignoresSafeArea()
        }
        .ignoresSafeArea()
    }

    private var spotTapGuidancePopup: some View {
        ZStack {
            Color.black.opacity(0.42)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissSpotTapGuidance()
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "scope")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(usesRefinedNormalUI ? .refinedText : .meterAccent)
                        .frame(width: 28, height: 28)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("スポット測光のご案内")
                            .font(.meterValue(14))
                            .foregroundColor(usesRefinedNormalUI ? .refinedText : .meterSecondary)
                    }

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("画面端は AE の影響を受けやすく、測光値がずれやすくなります。")
                    Text("被写体が端にある場合も、近い明るさの場所を中央付近で測ってください。")
                }
                .font(.meterLabel(10))
                .foregroundColor(usesRefinedNormalUI ? .refinedTextSoft : .meterSecondary.opacity(0.72))

                Button {
                    dismissSpotTapGuidance()
                } label: {
                    Text("閉じる")
                        .font(.meterValue(12))
                        .foregroundColor(usesRefinedNormalUI ? .refinedTextOnDark : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(usesRefinedNormalUI ? Color.refinedPanel : Color.meterAccent)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(usesRefinedNormalUI ? Color.refinedSurface : Color.meterCardBg.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(usesRefinedNormalUI ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.24), radius: 28, x: 0, y: 12)
            )
            .padding(.horizontal, 24)
        }
    }

    private var shouldShowCenterTapMask: Bool {
        (viewModel.meteringMode == .spot || viewModel.meteringMode == .threePoint) && !viewModel.isIncidentMode
    }

    private var shouldShowMeteringFrameMask: Bool {
        !viewModel.isIncidentMode &&
        isFullscreenSettled &&
        !shouldShowCenterTapMask
    }

    private func fullScreenMeteringFocusOverlay(
        screenSize: CGSize,
        previewFrame: CGRect
    ) -> some View {
        let screenRect = CGRect(origin: .zero, size: screenSize)
        let localCutoutRect = centerMeteringMaskRect(
            previewWidth: previewFrame.width,
            previewHeight: previewFrame.height
        )
        let cutoutRect = localCutoutRect.offsetBy(dx: previewFrame.minX, dy: previewFrame.minY)

        return ZStack {
            PreviewEllipseCutoutShape(cutout: cutoutRect)
                .fill(
                    Color.black.opacity(usesRefinedNormalUI ? 0.48 : 0.38),
                    style: FillStyle(eoFill: true)
                )

            Ellipse()
                .stroke(
                    Color.cyan.opacity(0.86),
                    lineWidth: 1.6
                )
                .frame(width: cutoutRect.width, height: cutoutRect.height)
                .position(x: cutoutRect.midX, y: cutoutRect.midY)
                .shadow(color: Color.black.opacity(0.45), radius: 4, x: 0, y: 1)
        }
        .frame(width: screenRect.width, height: screenRect.height)
        .clipped()
    }

    private func spotTapGuidanceOverlay(previewWidth: CGFloat, previewHeight: CGFloat) -> some View {
        let cutoutRect = centerMeteringMaskRect(previewWidth: previewWidth, previewHeight: previewHeight)

        return ZStack {
            PreviewEllipseCutoutShape(cutout: cutoutRect)
                .fill(
                    Color.black.opacity(usesRefinedNormalUI ? 0.44 : 0.34),
                    style: FillStyle(eoFill: true)
                )

            Ellipse()
                .stroke(
                    Color.cyan.opacity(0.86),
                    lineWidth: 1.6
                )
                .frame(width: cutoutRect.width, height: cutoutRect.height)
                .position(x: cutoutRect.midX, y: cutoutRect.midY)
        }
        .frame(width: previewWidth, height: previewHeight)
        .allowsHitTesting(false)
    }

    private func fullScreenSpotTapGuidanceOverlay(
        areaWidth: CGFloat,
        areaHeight: CGFloat,
        previewFrame: CGRect,
        previewWidth: CGFloat,
        previewHeight: CGFloat
    ) -> some View {
        let localCutoutRect = centerMeteringMaskRect(previewWidth: previewWidth, previewHeight: previewHeight)
        let cutoutRect = localCutoutRect.offsetBy(dx: previewFrame.minX, dy: previewFrame.minY)

        return ZStack {
            PreviewEllipseCutoutShape(cutout: cutoutRect)
                .fill(
                    Color.black.opacity(usesRefinedNormalUI ? 0.34 : 0.26),
                    style: FillStyle(eoFill: true)
                )

            Ellipse()
                .stroke(
                    Color.cyan.opacity(0.72),
                    lineWidth: 1.4
                )
                .frame(width: cutoutRect.width, height: cutoutRect.height)
                .position(x: cutoutRect.midX, y: cutoutRect.midY)
                .shadow(color: Color.black.opacity(0.45), radius: 4, x: 0, y: 1)
        }
        .frame(width: areaWidth, height: areaHeight)
        .allowsHitTesting(false)
    }

    private func centerMeteringMaskRect(previewWidth: CGFloat, previewHeight: CGFloat) -> CGRect {
        let cutoutWidth = min(max(previewWidth * 0.5, 148) + 30.0, previewWidth - 18)
        let cutoutHeight = min(max(previewHeight * 0.62, 184), previewHeight - 42)
        return CGRect(
            x: (previewWidth - cutoutWidth) / 2,
            y: (previewHeight - cutoutHeight) / 2 - 8,
            width: cutoutWidth,
            height: cutoutHeight
        )
    }

    private func isInsideCenterMeteringMask(_ location: CGPoint, previewSize: CGSize) -> Bool {
        let maskRect = centerMeteringMaskRect(
            previewWidth: previewSize.width,
            previewHeight: previewSize.height
        )
        guard maskRect.width > 0, maskRect.height > 0 else { return false }

        let normalizedX = (location.x - maskRect.midX) / (maskRect.width / 2)
        let normalizedY = (location.y - maskRect.midY) / (maskRect.height / 2)
        return (normalizedX * normalizedX) + (normalizedY * normalizedY) <= 1
    }

    // MARK: - Top Bar — EV値/レンズ情報/露出ステータス表示
    private func topBar() -> some View {
        ZStack {
            if viewModel.isIncidentMode {
                ZStack {
                    IncidentSensorTitleGlow(refined: usesRefinedInterface)
                        .offset(y: -4)

                    VStack(spacing: 2) {
                        Text("INCIDENT METER")
                            .font(.meterValue(15))
                            .foregroundColor(usesRefinedInterface ? .refinedText : .cyan)
                        Text("FRONT CAMERA")
                            .font(.meterLabel(9))
                            .foregroundColor(usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.7))
                            .tracking(1.5)
                    }
                }
            } else {
                if usesRefinedNormalUI {
                    VStack(spacing: 5) {
                        Text("EV \(String(format: "%.1f", viewModel.measuredEV))")
                            .font(.meterValue(17))
                            .foregroundColor(.refinedText)
                            .shadow(color: Color.black.opacity(0.62), radius: 2.2, x: 0, y: 1)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                FullscreenLiquidGlassBackground(
                                    shape: Capsule(),
                                    tint: .cyan,
                                    tintStrength: 0.12,
                                    strokeOpacity: 0.24
                                )
                            )

                        Text(currentLensStatusText)
                            .font(.meterLabel(9))
                            .foregroundColor(.refinedTextSoft)
                            .monospacedDigit()
                            .shadow(color: Color.black.opacity(0.58), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                FullscreenLiquidGlassBackground(
                                    shape: Capsule(),
                                    tint: .white,
                                    tintStrength: 0.05,
                                    strokeOpacity: 0.16
                                )
                            )
                    }
                } else {
                    VStack(spacing: 2) {
                        Text("EV \(String(format: "%.1f", viewModel.measuredEV))")
                            .font(.meterValue(18))
                            .foregroundColor(.meterAccent)
                        Text(currentLensStatusText)
                            .font(.meterLabel(10))
                            .foregroundColor(.meterSecondary.opacity(0.7))
                            .monospacedDigit()
                    }
                }
            }

            // 左右ボタン
            HStack {
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 20))
                        .foregroundColor((viewModel.isIncidentMode && usesRefinedInterface) ? .refinedText : (usesRefinedNormalUI ? .refinedText : .meterSecondary))
                        .frame(width: 38, height: 34)
                        .background(fullscreenGlassControlBackground(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Spacer()
                HStack(spacing: 10) {
                    if !viewModel.isIncidentMode {
                        collapseToPanelButton
                    }
                    if accessPolicy.allows(.shotRecords) {
                        Button { showShotHistory = true } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 16))
                                .foregroundColor((viewModel.isIncidentMode && usesRefinedInterface) ? .refinedText : (usesRefinedNormalUI ? .refinedText : .meterSecondary))
                                .frame(width: 34, height: 32)
                                .background(fullscreenGlassControlBackground(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                    }
                    if accessPolicy.allows(.autoExposureLock), !viewModel.isIncidentMode && viewModel.meteringMode != .threePoint {
                        aelButton
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 56)
        .padding(.bottom, 10)
    }

    private var collapseToPanelButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                controlPanelOffset = 0
            }
        } label: {
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(usesRefinedNormalUI ? .refinedTextOnDark : .meterSecondary)
                .frame(width: 30, height: 28)
                .background(fullscreenGlassControlBackground(cornerRadius: MeterShape.control))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("小さいプレビューに戻る")
    }

    private var aelButton: some View {
        let locked = viewModel.isLocked
        let label = viewModel.isIncidentMode ? "HOLD" : "AEL"
        let isTwoPointMetering = !viewModel.isIncidentMode && viewModel.meteringMode == .threePoint
        return Button {
            guard !isTwoPointMetering else { return }
            viewModel.toggleLock()
            locked ? cameraManager.unlockExposure() : cameraManager.lockExposure()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .tracking(1)
                .foregroundColor(
                    isTwoPointMetering
                        ? .meterSecondary.opacity(0.35)
                        : (locked ? (usesRefinedInterface ? .refinedBackground : .white) : (usesRefinedInterface ? .refinedText : .meterSecondary))
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    FullscreenLiquidGlassBackground(
                        shape: RoundedRectangle(cornerRadius: MeterShape.control, style: .continuous),
                        tint: locked ? .cyan : .white,
                        tintStrength: locked ? 0.34 : 0.08,
                        strokeOpacity: locked ? 0.48 : 0.18
                    )
                )
        }
        .buttonStyle(.plain)
        .disabled(cameraManager.isReflectiveMeasurementInProgress || isTwoPointMetering)
    }

    // MARK: - Bottom Controls — モード切替/測光モード/値調整コントロール
    private func bottomControls() -> some View {
        VStack(spacing: viewModel.isIncidentMode ? 6 : 8) {
            valueControlsRow

            if viewModel.isIncidentMode {
                incidentShutterRow
            } else {
                shutterRow
            }

            if !viewModel.isIncidentMode {
                Text("右上の縮小ボタンで詳細コントロール")
                    .font(.meterLabel(9))
                    .foregroundColor(.meterSecondary.opacity(0.4))
                    .opacity(viewModel.showAuxiliaryLabels ? 1 : 0)
                    .offset(y: viewModel.showAuxiliaryLabels ? 4 : 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, viewModel.isIncidentMode ? 8 : 10)
        .padding(.bottom, viewModel.isIncidentMode ? incidentBottomControlsBottomPadding : 16)
        .offset(y: viewModel.isIncidentMode ? incidentBottomControlsVerticalOffset : 0)
    }

    private var incidentBottomControlsBottomPadding: CGFloat {
        let safeBottom = currentBottomSafeAreaInset
        let extraClearance: CGFloat = viewModel.showAuxiliaryLabels ? 8 : 6
        return max(12, safeBottom + extraClearance)
    }

    private var currentBottomSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .windows
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    private var shutterRow: some View {
        GeometryReader { geo in
            let centerReservedWidth = centerActionButtonOuterSize + 28
            let sideWidth = max(0, (geo.size.width - centerReservedWidth) / 2)

            HStack(spacing: 0) {
                HStack {
                    exposureModeButtons
                    Spacer(minLength: 0)
                }
                .frame(width: sideWidth, alignment: .leading)
                .offset(x: exposureModeCenterOffset)

                shutterButton
                    .frame(width: centerReservedWidth)

                HStack {
                    Spacer(minLength: 0)
                    meteringModeButtons(maxWidth: sideWidth)
                }
                .frame(width: sideWidth, alignment: .trailing)
            }
        }
        .frame(height: centerActionButtonOuterSize + 8)
    }

    private var incidentShutterRow: some View {
        ZStack {
            incidentHoldButton

            HStack(spacing: 0) {
                exposureModeButtons
                    .offset(x: exposureModeCenterOffset)
                Spacer()
                incidentFooterStatus
            }
        }
    }

    private var exposureModeButtons: some View {
        HStack(spacing: exposureModeButtonSpacing) {
            ForEach(viewModel.availableExposureModes) { mode in
                Button {
                    viewModel.exposureMode = mode
                    if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
                } label: {
                    let selected = viewModel.exposureMode == mode
                    Text(mode.shortName)
                        .font(.meterValue(11))
                        .tracking(1)
                        .foregroundColor(selected ? fullscreenSelectedControlTextColor : fullscreenUnselectedControlTextColor)
                        .shadow(color: Color.black.opacity(0.58), radius: 1.8, x: 0, y: 1)
                        .frame(width: 34, height: 28)
                        .background(
                            FullscreenLiquidGlassBackground(
                                shape: Capsule(style: .continuous),
                                tint: selected ? .cyan : .white,
                                tintStrength: selected ? 0.28 : 0.07,
                                strokeOpacity: selected ? 0.42 : 0.16
                            )
                        )
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func meteringModeButtons(maxWidth: CGFloat) -> some View {
        let availableModes = viewModel.availableMeteringModes(for: accessPolicy)
        if availableModes.count <= 1 {
            Button {
                if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
                presentSpotTapGuidanceIfNeeded(force: true)
            } label: {
                meteringModeControlLabel(maxWidth: maxWidth, showsChevron: false)
            }
            .buttonStyle(.plain)
            .disabled(cameraManager.isReflectiveMeasurementInProgress)
        } else {
            Menu {
                Section("測光モード") {
                    ForEach(availableModes) { mode in
                        Button {
                            handleMeteringModeSelection(mode)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: mode.icon)
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 14, height: 14)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(mode.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                    if viewModel.showAuxiliaryLabels {
                                        Text(mode.shortDescription)
                                            .font(.system(size: 10, weight: .medium))
                                    }
                                }
                                Spacer(minLength: 8)
                                if viewModel.meteringMode == mode {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                }
                            }
                        }
                    }
                }

                if viewModel.meteringMode == .spot {
                    Section("スポット測光の基準") {
                        ForEach(SpotMeteringReferenceTarget.allCases) { target in
                            Button {
                                viewModel.spotMeteringReferenceTarget = target
                                if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: target.iconName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .frame(width: 14, height: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(target.title)
                                            .font(.system(size: 12, weight: .semibold))
                                        if viewModel.showAuxiliaryLabels {
                                            Text(target.detailText)
                                                .font(.system(size: 10, weight: .medium))
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if viewModel.spotMeteringReferenceTarget == target {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                meteringModeControlLabel(maxWidth: maxWidth, showsChevron: true)
            }
            .buttonStyle(.plain)
            .disabled(cameraManager.isReflectiveMeasurementInProgress)
        }
    }

    private func meteringModeControlLabel(maxWidth: CGFloat, showsChevron: Bool) -> some View {
        let controlWidth = min(meteringModeControlWidth, maxWidth)
        return HStack(spacing: 6) {
            Image(systemName: viewModel.meteringMode == .threePoint ? "triangle" : viewModel.meteringMode.icon)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel.showAuxiliaryLabels ? viewModel.meteringMode.displayName : viewModel.meteringMode.compactLabel)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.66)
                    .layoutPriority(1)
                Text(meteringModeSummaryText)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if viewModel.meteringMode == .spot {
                Image(systemName: viewModel.spotMeteringReferenceTarget.iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 14, height: 14)
            }

            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundColor(usesRefinedNormalUI ? .refinedTextOnDark : .white.opacity(0.88))
        .shadow(color: Color.black.opacity(0.58), radius: 1.8, x: 0, y: 1)
        .padding(.leading, 10)
        .padding(.trailing, showsChevron ? 6 : 10)
        .frame(width: controlWidth, height: 36)
        .background(
            FullscreenLiquidGlassBackground(
                shape: Capsule(style: .continuous),
                tint: .white,
                tintStrength: 0.08,
                strokeOpacity: 0.18
            )
        )
        .contentShape(Capsule(style: .continuous))
    }

    private var meteringModeControlWidth: CGFloat {
        min(max(screenWidth * 0.34, 136), 146)
    }

    private var meteringModeSummaryText: String {
        if viewModel.meteringMode == .spot {
            return viewModel.showAuxiliaryLabels
                ? "基準 \(viewModel.spotMeteringReferenceTarget.shortTitle)"
                : viewModel.spotMeteringReferenceTarget.shortTitle
        }
        return viewModel.showAuxiliaryLabels
            ? viewModel.meteringMode.shortDescription
            : viewModel.meteringMode.shortDescription
    }

    private var valueControlsRow: some View {
        let isAv = viewModel.exposureMode == .aperturePriority
        let isTv = viewModel.exposureMode == .shutterPriority
        return GeometryReader { geo in
            let spacing: CGFloat = 4
            let rowWidth = min(geo.size.width, fullscreenValueCardRowWidth)
            let sideInset = max(0, (geo.size.width - rowWidth) / 2)
            let widths = valueCardWidths(totalWidth: rowWidth, spacing: spacing)

            HStack(spacing: spacing) {
                CompactValueControl(
                    title: "絞り",
                    value: isTv ? autoApertureDisplayValue : currentAperture.displayString,
                    showTitle: viewModel.showAuxiliaryLabels,
                    refined: usesRefinedInterface,
                    presentation: .fullscreen,
                    isAuto: isTv,
                    autoTint: autoRecommendationTint,
                    autoBorderLineWidth: autoRecommendationBorderWidth,
                    isEnabled: !isTv,
                    isCalculated: isTv,
                    onIncrement: { viewModel.adjustAperture(by: 1, emitHaptics: false) },
                    onDecrement: { viewModel.adjustAperture(by: -1, emitHaptics: false) }
                )
                .frame(width: widths[0])
                CompactValueControl(
                    title: "SS",
                    value: isAv ? autoShutterDisplayValue : currentShutterDisplayValue,
                    subtitle: isAv ? autoShutterSubtitle : viewModel.reciprocityCorrectedTime.map { "補正:\(formatCorrectedTime($0))" },
                    showTitle: viewModel.showAuxiliaryLabels,
                    refined: usesRefinedInterface,
                    presentation: .fullscreen,
                    isAuto: isAv,
                    autoTint: autoRecommendationTint,
                    autoBorderLineWidth: autoRecommendationBorderWidth,
                    isEnabled: !isAv,
                    isCalculated: isAv,
                    onIncrement: { viewModel.adjustShutterSpeed(by: 1, emitHaptics: false) },
                    onDecrement: { viewModel.adjustShutterSpeed(by: -1, emitHaptics: false) }
                )
                .frame(width: widths[1])
                CompactValueControl(
                    title: "ISO",
                    value: "\(viewModel.iso.rawValue)",
                    showTitle: viewModel.showAuxiliaryLabels,
                    refined: usesRefinedInterface,
                    presentation: .fullscreen,
                    isEnabled: true,
                    isCalculated: false,
                    onIncrement: { adjustISO(by: 1, emitHaptics: false) },
                    onDecrement: { adjustISO(by: -1, emitHaptics: false) }
                )
                .frame(width: widths[2])
            }
            .frame(width: rowWidth)
            .animation(.easeInOut(duration: 0.2), value: viewModel.exposureMode)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .overlay(alignment: .topTrailing) {
                if shouldShowThreePointResetButton {
                    threePointResetButton
                        .padding(.trailing, sideInset + 8)
                        .offset(y: -42)
                        .zIndex(2)
                }
            }
        }
        .frame(height: viewModel.showAuxiliaryLabels ? 96 : 88)
        .offset(y: valueControlsRowVerticalOffset)
    }

    private var fullscreenValueCardRowWidth: CGFloat {
        max(270, screenWidth - 32)
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

    private var incidentInstructionCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("手順")
                .font(.meterValue(11))
                .foregroundColor(usesRefinedInterface ? .refinedText : .meterSecondary)

            VStack(alignment: .leading, spacing: 4) {
                incidentInstructionRow(number: "1", text: "フロントカメラを被写体に近づけ、光源側へ向ける")
                incidentInstructionRow(number: "2", text: "カメラ周辺を手やケースで遮らない")
                incidentInstructionRow(number: "3", text: "値が安定したら HOLD")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(usesRefinedInterface ? Color.refinedSurface : Color.meterCardBg.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(usesRefinedInterface ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5))
        )
    }

    private var incidentStatusPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("測定状態")
                    .font(.meterLabel(9))
                    .foregroundColor(usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.65))
                Spacer()
                Text(viewModel.isLocked ? "値を保持中" : cameraManager.measurementStateText)
                    .font(.meterValue(10))
                    .foregroundColor(incidentStateColor)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(usesRefinedInterface ? Color.refinedPanel : Color.meterSecondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(incidentStateColor)
                        .frame(width: max(4, geo.size.width * cameraManager.measurementStability))
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(usesRefinedInterface ? Color.refinedSurface : Color.meterCardBg.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(usesRefinedInterface ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5))
        )
    }

    private var incidentEVPanel: some View {
        VStack(spacing: 4) {
            Text("EV")
                .font(.meterLabel(11))
                .foregroundColor(usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.6))
                .tracking(2)

            Text(String(format: "%.1f", viewModel.measuredEV))
                .font(.system(size: 56, weight: .black, design: .monospaced))
                .foregroundColor(usesRefinedInterface ? .cyan : .meterAccent)
                .minimumScaleFactor(0.6)
                .lineLimit(1)

            Text(viewModel.exposureStatus.displayName)
                .font(.meterValue(11))
                .foregroundColor(viewModel.exposureStatus.color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(usesRefinedInterface ? Color.refinedPanel : Color.meterSurface.opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke((usesRefinedInterface ? Color.cyan : viewModel.exposureStatus.color).opacity(0.35), lineWidth: 1))
        )
    }

    private var incidentRecommendationRow: some View {
        HStack(spacing: 10) {
            incidentValueCard(
                title: incidentApertureIsCalculated ? "推奨 F" : "F",
                value: currentAperture.displayString,
                tint: incidentApertureIsCalculated ? (usesRefinedInterface ? .cyan : .meterAccent) : (usesRefinedInterface ? .refinedText : .meterSecondary),
                isCalculated: incidentApertureIsCalculated
            )
            incidentValueCard(
                title: incidentShutterIsCalculated ? "推奨 SS" : "SS",
                value: currentShutterDisplayValue,
                tint: incidentShutterIsCalculated ? (usesRefinedInterface ? .cyan : .meterAccent) : (usesRefinedInterface ? .refinedText : .meterSecondary),
                isCalculated: incidentShutterIsCalculated
            )
            incidentValueCard(
                title: "ISO",
                value: "\(viewModel.iso.rawValue)",
                tint: usesRefinedInterface ? .refinedText : .meterSecondary,
                isCalculated: false
            )
        }
    }

    private var incidentFooterStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(incidentStateColor)
                .frame(width: 7, height: 7)
            Text(incidentStatusText)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.8)
                .foregroundColor(incidentStateColor)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(usesRefinedInterface ? Color.refinedPanel : Color.meterSecondary.opacity(0.85))
                .overlay(Capsule().stroke(incidentStateColor.opacity(0.5), lineWidth: 0.6))
        )
        .padding(.trailing, incidentFooterStatusTrailingInset)
    }

    private var incidentStateBadge: some View {
        Text(incidentStatusText)
            .font(.system(size: 8, weight: .black, design: .monospaced))
            .tracking(0.8)
            .foregroundColor(incidentStateColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(incidentStateColor.opacity(0.12))
                    .overlay(Capsule().stroke(incidentStateColor.opacity(0.35), lineWidth: 0.6))
            )
    }

    private func incidentInstructionRow(number: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundColor(.black)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Color.cyan.opacity(0.75)))
            Text(text)
                .font(.meterLabel(10))
                .foregroundColor(usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.82))
            Spacer(minLength: 0)
        }
    }

    private var incidentApertureIsCalculated: Bool {
        viewModel.exposureMode == .shutterPriority
    }

    private var incidentShutterIsCalculated: Bool {
        viewModel.exposureMode == .aperturePriority
    }

    private func incidentValueCard(title: String, value: String, tint: Color, isCalculated: Bool) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.meterLabel(9))
                .foregroundColor(isCalculated ? ((usesRefinedInterface ? Color.cyan : Color.meterAccent).opacity(0.8)) : (usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.6)))
            Text(value)
                .font(.system(size: 21, weight: .black, design: .monospaced))
                .foregroundColor(tint)
                .minimumScaleFactor(0.55)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(usesRefinedInterface ? Color.refinedSurface : Color.meterCardBg.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke((usesRefinedInterface ? tint.opacity(0.32) : tint.opacity(0.2)), lineWidth: 0.8))
        )
    }

    private var incidentHoldButton: some View {
        let locked = viewModel.isLocked
        let holdTextColor: Color = {
            if usesRefinedInterface {
                return locked ? .refinedBackground : .white
            }
            return locked ? .black : .white
        }()
        return Button {
            viewModel.toggleLock()
            locked ? cameraManager.unlockExposure() : cameraManager.lockExposure()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(locked ? (usesRefinedInterface ? Color.cyan : Color.meterAccent) : (usesRefinedInterface ? Color.refinedStroke : Color.meterSecondary), lineWidth: 3)
                    .frame(width: centerActionButtonOuterSize, height: centerActionButtonOuterSize)
                Circle()
                    .fill(Color.clear)
                    .background(
                        FullscreenLiquidGlassBackground(
                            shape: Circle(),
                            tint: locked ? .cyan : .white,
                            tintStrength: locked ? 0.34 : 0.10,
                            strokeOpacity: locked ? 0.44 : 0.20
                        )
                    )
                    .frame(width: centerActionButtonInnerSize, height: centerActionButtonInnerSize)
                Text("HOLD")
                    .font(.system(size: 11, weight: .black, design: .monospaced))
                    .tracking(0.9)
                    .foregroundColor(holdTextColor)
                    .shadow(color: locked ? Color.white.opacity(0.22) : Color.black.opacity(0.82), radius: 2, x: 0, y: 1)
            }
        }
        .buttonStyle(.plain)
        .offset(y: incidentHoldButtonVerticalOffset)
    }

    private var incidentSettingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("設定")
                .font(.meterValue(11))
                .foregroundColor(usesRefinedInterface ? .refinedText : .meterSecondary)

            ExposureCompensationSlider(value: $viewModel.exposureCompensation, refined: usesRefinedInterface)

            Button {
                viewModel.isIncidentMode = false
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 13, weight: .semibold))
                    Text("反射光測定に戻る")
                        .font(.meterLabel(11))
                    Spacer()
                    Text("REFLECTIVE")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(0.6)
                }
                .foregroundColor(usesRefinedInterface ? .refinedText : .meterSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(usesRefinedInterface ? Color.refinedPanel : Color.meterSurface.opacity(0.65))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(usesRefinedInterface ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(usesRefinedInterface ? Color.refinedSurface : Color.meterCardBg.opacity(0.95))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(usesRefinedInterface ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5))
        )
    }

    // MARK: - Shutter Button — シャッター/HOLD切替ボタン
    private var shutterButton: some View {
        let isBusy = isSaving || isPreparingShotSave
        let canSaveShot = accessPolicy.allows(.shotRecords)
        let strokeColor = usesRefinedNormalUI
            ? Color.cyan.opacity(isBusy ? 0.42 : 0.95)
            : Color.meterSecondary
        let innerFillColor = usesRefinedNormalUI
            ? Color.cyan.opacity(isBusy ? 0.18 : 0.62)
            : (isBusy ? Color.meterSecondary.opacity(0.18) : Color.meterSecondary.opacity(0.46))

        return Button {
            guard !isBusy else { return }
            if canSaveShot {
                beginShotSaveFlow()
            } else {
                presentShotMemoUpsell()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .background(
                        FullscreenLiquidGlassBackground(
                            shape: Circle(),
                            tint: .cyan,
                            tintStrength: isBusy ? 0.10 : 0.18,
                            strokeOpacity: isBusy ? 0.18 : 0.28
                        )
                    )
                    .frame(width: centerActionButtonOuterSize, height: centerActionButtonOuterSize)
                Circle()
                    .strokeBorder(strokeColor, lineWidth: usesRefinedNormalUI ? 3.4 : 3)
                    .frame(width: centerActionButtonOuterSize, height: centerActionButtonOuterSize)
                Circle()
                    .fill(innerFillColor)
                    .frame(width: centerActionButtonInnerSize, height: centerActionButtonInnerSize)
                    .overlay {
                        if !canSaveShot {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.7))
                        } else if usesRefinedNormalUI {
                            Circle()
                                .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                        }
                    }
                    .shadow(
                        color: usesRefinedNormalUI ? Color.cyan.opacity(isBusy ? 0.0 : 0.24) : .clear,
                        radius: 10,
                        x: 0,
                        y: 4
                    )
            }
        }
        .buttonStyle(.plain)
        .offset(y: shutterButtonVerticalOffset)
    }

    private func presentShotMemoUpsell() {
        if viewModel.enableHaptics {
            HapticManager.shared.lightTap()
        }
        showSpotTapGuidancePopup = false
        selectedSpotWarningGuide = nil
        showThreePointMeteringGuide = false
        withAnimation(.easeInOut(duration: 0.18)) {
            showShotMemoUpsellPopup = true
        }
    }

    private func dismissShotMemoUpsell() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showShotMemoUpsellPopup = false
        }
    }

    // MARK: - Capture & Save — コラージュ画像生成→写真ライブラリ保存
    private func beginShotSaveFlow() {
        guard accessPolicy.allows(.shotRecords) else { return }
        isPreparingShotSave = true
        cameraManager.captureCurrentPreviewImage { previewImage in
            defer { isPreparingShotSave = false }
            guard let previewImage else { return }
            pendingShotSaveDraft = makePendingShotSaveDraft(previewImage: previewImage)
            shotSaveNote = ""
            presentShotMemoWindow()
        }
    }

    private func makePendingShotSaveDraft(previewImage: CGImage) -> PendingShotSaveDraft {
        let focalLengthText = activePresetFocalLengthText
        return PendingShotSaveDraft(
            previewImage: previewImage,
            capturedAt: Date(),
            aperture: currentAperture.displayString,
            shutterSpeed: currentShutterDisplayValue,
            iso: viewModel.iso.rawValue,
            ev: viewModel.measuredEV,
            evDifference: viewModel.evDifference,
            exposureMode: viewModel.exposureMode.shortName,
            meteringMode: viewModel.meteringMode.displayName,
            exposureCompensation: viewModel.exposureCompensation,
            isIncident: viewModel.isIncidentMode,
            zoneValue: viewModel.currentZone,
            exposureStatus: viewModel.exposureStatus,
            focalLengthText: focalLengthText,
            previewCropMultiplier: focalLengthText == nil ? 1 : visibleFocalLengthMultiplier
        )
    }

    private func discardPendingShotSaveComposer() {
        dismissShotMemoWindow()
        pendingShotSaveDraft = nil
        shotSaveNote = ""
    }

    private func presentShotMemoWindow() {
        guard pendingShotSaveDraft != nil else { return }

        dismissShotMemoWindow()

        let controller = AppOverlayWindowController()
        shotMemoOverlayWindow = controller
        controller.present(windowLevel: .normal + 2) {
            ShotSaveComposerOverlay(
                note: Binding(
                    get: { shotSaveNote },
                    set: { shotSaveNote = $0 }
                ),
                refined: usesRefinedInterface,
                isSaving: Binding(
                    get: { isSaving },
                    set: { isSaving = $0 }
                ),
                onCancel: discardPendingShotSaveComposer,
                onSave: commitPendingShotSave
            )
        }
    }

    private func dismissShotMemoWindow() {
        shotMemoOverlayWindow?.dismiss()
        shotMemoOverlayWindow = nil
    }

    private func commitPendingShotSave() {
        guard let draft = pendingShotSaveDraft, !isSaving else { return }

        let normalizedNote = shotSaveNote.trimmingCharacters(in: .whitespacesAndNewlines)

        isSaving = true

        let record = ShotRecord(
            aperture: draft.aperture,
            shutterSpeed: draft.shutterSpeed,
            iso: draft.iso,
            ev: draft.ev,
            evDifference: draft.evDifference,
            exposureMode: draft.exposureMode,
            meteringMode: draft.meteringMode,
            exposureCompensation: draft.exposureCompensation,
            isIncident: draft.isIncident,
            zoneValue: draft.zoneValue,
            focalLength: draft.focalLengthText,
            note: normalizedNote,
            date: draft.capturedAt
        )
        shotRecordStore.add(record)
        if viewModel.enableHaptics { HapticManager.shared.mediumTap() }

        let collageImage = generateCollage(for: draft, note: normalizedNote)
        record.saveCollageImage(collageImage)

        pendingShotSaveDraft = nil
        shotSaveNote = ""
        dismissShotMemoWindow()

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { isSaving = false }
                return
            }

            var createdPhotoAssetLocalIdentifier: String?

            PHPhotoLibrary.shared().performChanges {
                if let data = collageImage.pngData() {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, data: data, options: nil)
                    createdPhotoAssetLocalIdentifier = request.placeholderForCreatedAsset?.localIdentifier
                }
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    isSaving = false
                    if success {
                        if let createdPhotoAssetLocalIdentifier {
                            shotRecordStore.updatePhotoAssetLocalIdentifier(createdPhotoAssetLocalIdentifier, for: record.id)
                        }
                        withAnimation { showSaveConfirmation = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { showSaveConfirmation = false }
                        }
                    }
                }
            }
        }
    }

    private var activePresetFocalLengthText: String? {
        guard activePreset != nil else {
            return nil
        }
        return cameraManager.currentLensDisplay
    }

    // MARK: - Collage Generator — プレビュー+露出情報のコラージュ画像描画
    private func generateCollage(for draft: PendingShotSaveDraft, note: String) -> UIImage {
        let totalWidth: CGFloat = 800
        let totalHeight: CGFloat = 600

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: totalWidth, height: totalHeight))
        return renderer.image { ctx in
            let context = ctx.cgContext

            UIColor(white: 0.12, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

            let rotatedImage = UIImage(
                cgImage: draft.previewImage,
                scale: 1.0,
                orientation: viewModel.isIncidentMode ? .rightMirrored : .right
            )
            let collagePreviewImage = cropPreviewImageForShotMemo(
                rotatedImage,
                multiplier: draft.previewCropMultiplier
            )

            let outerPadding: CGFloat = 28
            let panelGap: CGFloat = 24
            let photoCardWidth: CGFloat = 300
            let photoCardHeight: CGFloat = photoCardWidth * 3 / 2
            let photoCardRect = CGRect(
                x: outerPadding,
                y: (totalHeight - photoCardHeight) / 2,
                width: photoCardWidth,
                height: photoCardHeight
            )
            let photoRect = photoCardRect.insetBy(dx: 8, dy: 8)
            let rightPanelX = photoCardRect.maxX + panelGap
            let rightPanelWidth = totalWidth - rightPanelX - outerPadding

            let photoCardPath = UIBezierPath(roundedRect: photoCardRect, cornerRadius: 20)
            context.setFillColor(UIColor(white: 0.09, alpha: 1).cgColor)
            context.addPath(photoCardPath.cgPath)
            context.fillPath()
            context.addPath(photoCardPath.cgPath)
            context.setStrokeColor(UIColor(white: 0.20, alpha: 1).cgColor)
            context.setLineWidth(1)
            context.strokePath()

            let imgSize = collagePreviewImage.size
            let scaleX = photoRect.width / imgSize.width
            let scaleY = photoRect.height / imgSize.height
            let fillScale = max(scaleX, scaleY)
            let drawW = imgSize.width * fillScale
            let drawH = imgSize.height * fillScale
            let drawX = photoRect.minX + (photoRect.width - drawW) / 2
            let drawY = photoRect.minY + (photoRect.height - drawH) / 2

            context.saveGState()
            let photoClipPath = UIBezierPath(roundedRect: photoRect, cornerRadius: 16)
            context.addPath(photoClipPath.cgPath)
            context.clip()
            collagePreviewImage.draw(in: CGRect(x: drawX, y: drawY, width: drawW, height: drawH))
            context.restoreGState()

            let valueFont = UIFont.monospacedSystemFont(ofSize: draft.focalLengthText == nil ? 24 : 20, weight: .bold)
            let detailFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
            let metaFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .medium)
            let focalLengthFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .bold)
            let noteTitleFont = UIFont.monospacedSystemFont(ofSize: 11, weight: .bold)
            let noteFont = UIFont.systemFont(ofSize: 14, weight: .medium)
            let footerFont = UIFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let accentColor = UIColor(red: 0.95, green: 0.36, blue: 0.14, alpha: 1)
            let shutterColor = UIColor(red: 0.56, green: 0.84, blue: 0.94, alpha: 1)
            let isoColor = UIColor(red: 0.95, green: 0.89, blue: 0.70, alpha: 1)
            let grayColor = UIColor(white: 0.70, alpha: 1)
            let subduedColor = UIColor(white: 0.52, alpha: 1)
            let noteColor = UIColor(white: 0.92, alpha: 1)
            let noteBoxStroke = UIColor(white: 0.22, alpha: 1)
            let noteBoxFill = UIColor(white: 0.11, alpha: 1)

            let sidePadding: CGFloat = rightPanelX
            let columnGap: CGFloat = 12
            let tripleColumnWidth = (rightPanelWidth - columnGap * 2) / 3
            let dualColumnWidth = (rightPanelWidth - columnGap) / 2
            let topMetricWidth = draft.focalLengthText == nil
                ? tripleColumnWidth
                : (rightPanelWidth - columnGap * 3) / 4

            let y1: CGFloat = outerPadding + 6
            let y2: CGFloat = y1 + 38
            let dividerY: CGFloat = y2 + 28
            let y3: CGFloat = dividerY + 16
            let noteHeaderY: CGFloat = y3 + 28
            let noteBoxY: CGFloat = noteHeaderY + 22
            let y4: CGFloat = totalHeight - outerPadding - 14
            let noteBoxHeight = y4 - noteBoxY - 22

            drawText(
                draft.aperture,
                in: CGRect(x: sidePadding, y: y1, width: topMetricWidth, height: 34),
                font: valueFont,
                color: accentColor,
                in: context
            )
            drawText(
                draft.shutterSpeed,
                in: CGRect(x: sidePadding + topMetricWidth + columnGap, y: y1, width: topMetricWidth, height: 34),
                font: valueFont,
                color: shutterColor,
                in: context
            )
            drawText(
                "ISO \(draft.iso)",
                in: CGRect(x: sidePadding + (topMetricWidth + columnGap) * 2, y: y1, width: topMetricWidth, height: 34),
                font: valueFont,
                color: isoColor,
                in: context
            )
            if let focalLengthText = draft.focalLengthText {
                drawText(
                    focalLengthText,
                    in: CGRect(x: sidePadding + (topMetricWidth + columnGap) * 3, y: y1 + 5, width: topMetricWidth, height: 24),
                    font: focalLengthFont,
                    color: grayColor,
                    alignment: .right,
                    in: context
                )
            }

            drawText(
                "EV \(String(format: "%.1f", draft.ev))",
                in: CGRect(x: sidePadding, y: y2, width: tripleColumnWidth, height: 18),
                font: detailFont,
                color: accentColor,
                in: context
            )
            drawText(
                draft.exposureStatus.displayName,
                in: CGRect(x: sidePadding + tripleColumnWidth + columnGap, y: y2, width: tripleColumnWidth, height: 18),
                font: detailFont,
                color: collageExposureStatusColor(for: draft.exposureStatus),
                in: context
            )
            drawText(
                "Zone \(draft.zoneValue)",
                in: CGRect(x: sidePadding + (tripleColumnWidth + columnGap) * 2, y: y2, width: tripleColumnWidth, height: 18),
                font: detailFont,
                color: grayColor,
                in: context
            )

            context.setStrokeColor(UIColor(white: 0.18, alpha: 1).cgColor)
            context.setLineWidth(1)
            context.move(to: CGPoint(x: sidePadding, y: dividerY))
            context.addLine(to: CGPoint(x: sidePadding + rightPanelWidth, y: dividerY))
            context.strokePath()

            let compStr = draft.exposureCompensation == 0
                ? "±0 EV"
                : String(format: "%+.1f EV", draft.exposureCompensation)
            drawText(
                "\(draft.exposureMode) / \(draft.meteringMode)",
                in: CGRect(x: sidePadding, y: y3, width: dualColumnWidth, height: 14),
                font: metaFont,
                color: grayColor,
                in: context
            )
            drawText(
                compStr,
                in: CGRect(x: sidePadding + dualColumnWidth + columnGap, y: y3, width: dualColumnWidth, height: 14),
                font: metaFont,
                color: grayColor,
                alignment: .right,
                in: context
            )

            drawText(
                "NOTE",
                in: CGRect(x: sidePadding, y: noteHeaderY, width: dualColumnWidth, height: 14),
                font: noteTitleFont,
                color: grayColor,
                in: context
            )

            let noteRect = CGRect(x: sidePadding, y: noteBoxY, width: rightPanelWidth, height: noteBoxHeight)
            let notePath = UIBezierPath(roundedRect: noteRect, cornerRadius: 14)
            context.setFillColor(noteBoxFill.cgColor)
            context.addPath(notePath.cgPath)
            context.fillPath()
            context.addPath(notePath.cgPath)
            context.setStrokeColor(noteBoxStroke.cgColor)
            context.setLineWidth(1)
            context.strokePath()

            let noteContentRect = noteRect.insetBy(dx: 14, dy: 12)
            let renderedNote = note.isEmpty
                ? "記録メモなし"
                : fittedCollageNote(note, in: noteContentRect, font: noteFont, lineSpacing: 4)

            drawParagraphText(
                renderedNote,
                in: noteContentRect,
                font: noteFont,
                color: note.isEmpty ? subduedColor : noteColor,
                lineSpacing: 4,
                in: context
            )

            drawText(
                "Solis film meter",
                in: CGRect(x: sidePadding, y: y4, width: dualColumnWidth, height: 12),
                font: footerFont,
                color: subduedColor,
                in: context
            )

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy.MM.dd HH:mm"
            let dateStr = formatter.string(from: draft.capturedAt)
            drawText(
                dateStr,
                in: CGRect(x: sidePadding + dualColumnWidth + columnGap, y: y4, width: dualColumnWidth, height: 12),
                font: footerFont,
                color: subduedColor,
                alignment: .right,
                in: context
            )
        }
    }

    private func cropPreviewImageForShotMemo(_ image: UIImage, multiplier: Double) -> UIImage {
        let cropMultiplier = CGFloat(max(1, multiplier))
        guard cropMultiplier > 1.001, image.size.width > 1, image.size.height > 1 else {
            return image
        }

        let cropWidth = max(1, image.size.width / cropMultiplier)
        let cropRect = CGRect(
            x: (image.size.width - cropWidth) / 2,
            y: 0,
            width: cropWidth,
            height: image.size.height
        )

        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        return renderer.image { _ in
            image.draw(
                in: CGRect(
                    x: -cropRect.minX,
                    y: -cropRect.minY,
                    width: image.size.width,
                    height: image.size.height
                )
            )
        }
    }

    private func drawText(_ text: String, at point: CGPoint, font: UIFont, color: UIColor, in context: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        in context: CGContext
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }

    private func drawParagraphText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment = .left,
        lineSpacing: CGFloat = 0,
        in context: CGContext
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = lineSpacing

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        attributed.draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
    }

    private func fittedCollageNote(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        lineSpacing: CGFloat
    ) -> String {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return "" }

        if paragraphTextHeight(for: trimmedText, width: rect.width, font: font, lineSpacing: lineSpacing) <= rect.height {
            return trimmedText
        }

        let characters = Array(trimmedText)
        var low = 0
        var high = characters.count

        while low < high {
            let mid = (low + high + 1) / 2
            let candidate = String(characters.prefix(mid)).trimmingCharacters(in: .whitespacesAndNewlines)
            if paragraphTextHeight(for: candidate, width: rect.width, font: font, lineSpacing: lineSpacing) <= rect.height {
                low = mid
            } else {
                high = mid - 1
            }
        }

        return String(characters.prefix(low)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func paragraphTextHeight(
        for text: String,
        width: CGFloat,
        font: UIFont,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.lineSpacing = lineSpacing

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let bounds = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return ceil(bounds.height)
    }

    private func collageExposureStatusColor(for status: ExposureStatus) -> UIColor {
        switch status {
        case .severeUnderexposure:
            return UIColor(red: 0.34, green: 0.58, blue: 0.96, alpha: 1)
        case .underexposure:
            return UIColor(red: 0.44, green: 0.82, blue: 0.95, alpha: 1)
        case .slightUnderexposure:
            return UIColor(red: 0.43, green: 0.84, blue: 0.73, alpha: 1)
        case .proper:
            return UIColor(red: 0.55, green: 0.84, blue: 0.48, alpha: 1)
        case .slightOverexposure:
            return UIColor(red: 0.95, green: 0.82, blue: 0.42, alpha: 1)
        case .overexposure:
            return UIColor(red: 0.95, green: 0.57, blue: 0.22, alpha: 1)
        case .severeOverexposure:
            return UIColor(red: 0.94, green: 0.33, blue: 0.25, alpha: 1)
        }
    }

    // MARK: - Helpers — 露出シミュレーション計算/スポット位置変換
    private var currentAperture: Aperture {
        viewModel.effectiveAperture
    }

    private var currentShutterSpeed: ShutterSpeed {
        viewModel.effectiveShutterSpeed
    }

    private var currentShutterDisplayValue: String {
        viewModel.effectiveShutterDisplayString
    }

    private var fullscreenZoomGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                guard cameraManager.allowsFullscreenZoom else { return }
                if zoomGestureStartFocalLength == nil {
                    zoomGestureStartFocalLength = cameraManager.currentEquivalentFocalLength
                }
                guard let zoomGestureStartFocalLength else { return }
                cameraManager.setEquivalentFocalLength(zoomGestureStartFocalLength * Double(scale))
            }
            .onEnded { _ in
                zoomGestureStartFocalLength = nil
            }
    }

    private func adjustISO(by direction: Int, emitHaptics: Bool = true) {
        viewModel.adjustISO(by: direction, emitHaptics: emitHaptics)
    }

    private var currentLensStatusText: String {
        if cameraManager.isZoomLensPreset {
            return viewModel.showAuxiliaryLabels ? "ズーム \(cameraManager.currentLensDisplay)" : cameraManager.currentLensDisplay
        }
        return cameraManager.currentLensDisplay
    }

    private var usesRefinedNormalUI: Bool {
        !viewModel.showAuxiliaryLabels && !viewModel.isIncidentMode
    }

    private func fullscreenGlassControlBackground(cornerRadius: CGFloat) -> some View {
        FullscreenLiquidGlassBackground(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: .white,
            tintStrength: 0.08,
            strokeOpacity: 0.18
        )
    }

    private var fullscreenSelectedControlTextColor: Color {
        usesRefinedInterface ? .refinedText : .white.opacity(0.96)
    }

    private var fullscreenUnselectedControlTextColor: Color {
        usesRefinedInterface ? .refinedTextOnDark : .white.opacity(0.82)
    }

    private var incidentStatusText: String {
        viewModel.isLocked ? "HOLD" : cameraManager.measurementStateText
    }

    private var incidentStateColor: Color {
        if viewModel.isLocked {
            return usesRefinedInterface ? .cyan : .meterAccent
        }
        if cameraManager.measurementStability >= 0.82 {
            return .meterGreen
        }
        return .cyan
    }

    // MARK: - Tap Handling — タップ位置→スポット測光ポイント設定
    private func handleTap(location: CGPoint, relativeX: CGFloat, relativeY: CGFloat, previewSize: CGSize) {
        if showSpotTapGuidancePopup {
            dismissSpotTapGuidance()
        }

        guard isInsideCenterMeteringMask(location, previewSize: previewSize) else { return }

        if viewModel.meteringMode == .threePoint {
            guard cameraManager.threePointPendingKind != nil else { return }

            if viewModel.isLocked {
                viewModel.setLock(false)
                cameraManager.unlockExposure()
            }

            cameraManager.setThreePointSelectionPoint(
                CGPoint(x: 0.5, y: 0.5)
            ) { completed in
                if completed {
                    viewModel.updateMeasuredEV(cameraManager.currentEV, force: true)
                    viewModel.setLock(true, withHaptics: viewModel.enableHaptics)
                } else if viewModel.enableHaptics {
                    HapticManager.shared.lightTap()
                }
            }
            return
        }

        guard viewModel.allowsMeteringMode(.spot, for: accessPolicy) else { return }
        if viewModel.isLocked {
            viewModel.setLock(false)
            cameraManager.unlockExposure()
        }
        viewModel.meteringMode = .spot
        let sensorPoint = cameraManager.sensorPoint(
            forVisiblePreviewPoint:
            CGPoint(x: relativeX, y: relativeY),
            mirrored: viewModel.isIncidentMode
        )
        cameraManager.setSpotMeteringPoint(x: sensorPoint.x, y: sensorPoint.y)
        tapPoint = CGPoint(x: relativeX, y: relativeY)

        withAnimation(.easeOut(duration: 0.1)) { tapPointOpacity = 1.0 }
        if viewModel.enableHaptics { HapticManager.shared.lightTap() }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.easeOut(duration: 0.5)) { tapPointOpacity = 0.3 }
        }
    }

    private func selectReflectiveMeteringMode(_ mode: MeteringMode) {
        guard viewModel.allowsMeteringMode(mode, for: accessPolicy) else { return }
        if viewModel.isLocked {
            viewModel.setLock(false)
            cameraManager.unlockExposure()
        }
        viewModel.meteringMode = mode
        if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
        if mode == .spot {
            presentSpotTapGuidanceIfNeeded(force: true)
        }
    }

    private func handleMeteringModeSelection(_ mode: MeteringMode) {
        if viewModel.meteringMode == mode {
            if mode == .spot {
                if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
                presentSpotTapGuidanceIfNeeded(force: true)
            } else if mode == .threePoint {
                if viewModel.isLocked {
                    viewModel.setLock(false)
                    cameraManager.unlockExposure()
                }
                cameraManager.restartThreePointSelection()
                if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
            } else {
                triggerReflectiveMeasurement(withHaptics: true)
            }
        } else {
            selectReflectiveMeteringMode(mode)
        }
    }

    private func resetThreePointMetering() {
        guard viewModel.meteringMode == .threePoint else { return }
        if viewModel.isLocked {
            viewModel.setLock(false)
            cameraManager.unlockExposure()
        }
        cameraManager.restartThreePointSelection()
        if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
    }

    private func triggerReflectiveMeasurement(withHaptics: Bool) {
        guard !viewModel.isIncidentMode, !cameraManager.isReflectiveMeasurementInProgress else { return }
        viewModel.setLock(false)
        cameraManager.requestReflectiveMeasurement { ev in
            viewModel.updateMeasuredEV(ev)
            if viewModel.meteringMode == .threePoint {
                viewModel.setLock(true, withHaptics: withHaptics)
            }
        }
    }

    private var isReflectiveFullscreenVisible: Bool {
        controlPanelOffset > 0.5 && !viewModel.isIncidentMode
    }

    private func presentSpotTapGuidanceIfNeeded(force: Bool = false) {
        guard isReflectiveFullscreenVisible, viewModel.meteringMode == .spot else {
            if !viewModel.isIncidentMode {
                showSpotTapGuidancePopup = false
            }
            return
        }
        guard force || !hasShownSpotTapGuidanceForCurrentSpotSelection else { return }
        hasShownSpotTapGuidanceForCurrentSpotSelection = true
        withAnimation(.easeInOut(duration: 0.18)) {
            showSpotTapGuidancePopup = true
        }
    }

    private func dismissSpotTapGuidance() {
        withAnimation(.easeInOut(duration: 0.18)) {
            showSpotTapGuidancePopup = false
        }
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
}

private struct IncidentSensorTitleGlow: View {
    let refined: Bool

    private var glowColor: Color {
        refined ? .cyan : .meterAccent
    }

    var body: some View {
        ZStack {
            Capsule(style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [
                            glowColor.opacity(0.36),
                            glowColor.opacity(0.11),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 92
                    )
                )
                .blur(radius: 13)

            Capsule(style: .continuous)
                .fill(glowColor.opacity(0.16))
                .blur(radius: 5)
        }
        .frame(width: 204, height: 48)
        .blendMode(.screen)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct FullScreenPreviewGuideFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct PendingShotSaveDraft: Identifiable {
    let id = UUID()
    let previewImage: CGImage
    let capturedAt: Date
    let aperture: String
    let shutterSpeed: String
    let iso: Int
    let ev: Double
    let evDifference: Double
    let exposureMode: String
    let meteringMode: String
    let exposureCompensation: Double
    let isIncident: Bool
    let zoneValue: Int
    let exposureStatus: ExposureStatus
    let focalLengthText: String?
    let previewCropMultiplier: Double
}

private struct ShotMemoUpsellPopup: View {
    let refined: Bool
    let isProcessing: Bool
    let activePurchasePlan: FullVersionPurchasePlan?
    let statusMessage: String?
    let onPurchaseMonthly: () -> Void
    let onPurchaseLifetime: () -> Void
    let onRestore: () -> Void
    let onDismiss: () -> Void

    private var panelColor: Color {
        refined ? .refinedSurface : .meterCardBg.opacity(0.98)
    }

    private var primaryTextColor: Color {
        refined ? .refinedText : .meterSecondary
    }

    private var secondaryTextColor: Color {
        refined ? .refinedTextSoft : .meterSecondary.opacity(0.74)
    }

    private var accentColor: Color {
        refined ? .cyan : .meterAccent
    }

    var body: some View {
        ZStack {
            Color.black.opacity(refined ? 0.46 : 0.34)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(refined ? 0.18 : 0.16))
                            .frame(width: 44, height: 44)
                        Image(systemName: "note.text.badge.plus")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundColor(accentColor)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("撮影メモは完全版で使えます")
                            .font(.meterValue(15))
                            .foregroundColor(primaryTextColor)
                        Text("露出を決めた理由まで、あとから見返せる記録にできます。")
                            .font(.meterLabel(10))
                            .foregroundColor(secondaryTextColor)
                            .lineSpacing(3)
                    }

                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 9) {
                    featureRow(icon: "camera.metering.center.weighted", text: "プレビュー画像、絞り、シャッター、ISO、EVを自動で保存")
                    featureRow(icon: "text.bubble", text: "被写体、場所、フィルム、現像メモなどをその場で追記")
                    featureRow(icon: "rectangle.stack.badge.plus", text: "撮影後に見返せるコラージュ画像として残せます")
                }

                Text("完全版はアプリ内課金で解放できます。")
                    .font(.meterLabel(10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 9) {
                    purchaseButton(
                        title: activePurchasePlan == .monthly ? "処理中..." : "月額で解放",
                        action: onPurchaseMonthly
                    )

                    purchaseButton(
                        title: activePurchasePlan == .lifetime ? "処理中..." : "買い切りで解放",
                        action: onPurchaseLifetime
                    )

                    Button(action: onRestore) {
                        Text("購入を復元")
                            .font(.meterLabel(12))
                            .foregroundColor(secondaryTextColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.meterLabel(10))
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 2)
                    }

                    Button(action: onDismiss) {
                        Text("閉じる")
                            .font(.meterLabel(12))
                            .foregroundColor(secondaryTextColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(18)
            .frame(maxWidth: 356)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(panelColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(refined ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.8)
                    )
                    .shadow(color: Color.black.opacity(0.28), radius: 28, x: 0, y: 14)
            )
            .padding(.horizontal, 22)
        }
        .preferredColorScheme(refined ? .dark : .light)
    }

    private func purchaseButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.meterValue(13))
                .foregroundColor(refined ? .black : .meterBackground)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accentColor)
                )
        }
        .buttonStyle(.plain)
        .disabled(isProcessing)
    }

    private func featureRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(accentColor)
                .frame(width: 18, height: 18)
            Text(text)
                .font(.meterLabel(10))
                .foregroundColor(secondaryTextColor)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ShotSaveComposerOverlay: View {
    @Binding var note: String
    let refined: Bool
    @Binding var isSaving: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isEditorFocused: Bool
    @State private var isFinishingAfterKeyboardDismissal: Bool = false
    @State private var initialFocusWorkItem: DispatchWorkItem?
    @State private var keyboardEndFrame: CGRect = .zero
    @State private var editorText: String = ""

    private let editorBoxHeight: CGFloat = 86
    private let keyboardPanelGap: CGFloat = 6
    private let bottomRestPadding: CGFloat = 14
    private let editorTextFont: Font = .system(size: 15, weight: .medium)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.black.opacity(refined ? 0.42 : 0.30)
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismissKeyboardFocus()
                    }

                composerPanel
                    .padding(.horizontal, 12)
                    .padding(.bottom, panelBottomPadding(in: proxy))
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .preferredColorScheme(refined ? .dark : .light)
        .ignoresSafeArea(.container)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            editorText = note
            scheduleInitialFocusAfterPresentation()
        }
        .onDisappear {
            initialFocusWorkItem?.cancel()
            initialFocusWorkItem = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            updateKeyboardFrame(from: notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { notification in
            updateKeyboardFrame(from: notification, forceHidden: true)
        }
        .onChange(of: editorText) { _, newValue in
            note = newValue
        }
    }

    private var composerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("撮影記録を保存")
                        .font(.meterValue(14))
                        .foregroundColor(refined ? .refinedText : .meterSecondary)
                    Text("撮影時の状況や意図、フィルム名などを残せます。")
                        .font(.meterLabel(9))
                        .foregroundColor(refined ? .refinedTextSoft : .meterSecondary.opacity(0.72))
                }

                Spacer()

                Button("キャンセル") {
                    finishAfterKeyboardDismissal(onCancel)
                }
                .font(.meterLabel(11))
                .foregroundColor(refined ? .refinedTextSoft : .meterSecondary.opacity(0.72))
                .disabled(isSaving || isFinishingAfterKeyboardDismissal)

                Button(isSaving ? "保存中..." : "保存") {
                    finishAfterKeyboardDismissal(onSave)
                }
                .font(.meterValue(12))
                .foregroundColor(refined ? .cyan : .meterAccent)
                .disabled(isSaving || isFinishingAfterKeyboardDismissal)
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(refined ? Color.refinedSurface : Color.meterCardBg.opacity(0.95))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(refined ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.6)
                    )

                if editorText.isEmpty {
                    Text("被写体、場所、フィルム、補足メモなど")
                        .font(editorTextFont)
                        .foregroundColor(refined ? .refinedTextSoft.opacity(0.7) : .meterSecondary.opacity(0.4))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $editorText)
                    .font(editorTextFont)
                    .foregroundColor(refined ? .refinedText : .meterSecondary)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxHeight: .infinity)
                    .focused($isEditorFocused)
            }
            .frame(height: editorBoxHeight)

            HStack {
                Text("コラージュ枠に反映")
                    .font(.meterLabel(9))
                    .foregroundColor(refined ? .refinedTextSoft.opacity(0.78) : .meterSecondary.opacity(0.6))
                Spacer()
                Text("\(editorText.count)文字")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(refined ? .cyan : .meterAccent)
            }
        }
        .padding(14)
        .frame(maxWidth: 400)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(refined ? Color.refinedPanel.opacity(0.98) : Color.meterBackground.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(refined ? Color.white.opacity(0.14) : Color.black.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.36), radius: 26, x: 0, y: 10)
        )
    }

    private func finishAfterKeyboardDismissal(_ action: @escaping () -> Void) {
        guard !isFinishingAfterKeyboardDismissal else { return }

        isFinishingAfterKeyboardDismissal = true
        initialFocusWorkItem?.cancel()
        initialFocusWorkItem = nil
        dismissKeyboardFocus()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            action()
        }
    }

    private func scheduleInitialFocusAfterPresentation() {
        initialFocusWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            guard !isFinishingAfterKeyboardDismissal else { return }
            isEditorFocused = true
        }
        initialFocusWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }

    private func panelBottomPadding(in proxy: GeometryProxy) -> CGFloat {
        let restingPadding = max(bottomRestPadding, proxy.safeAreaInsets.bottom + bottomRestPadding)
        let overlap = keyboardOverlap(in: proxy)
        guard overlap > 0 else { return restingPadding }
        return overlap + keyboardPanelGap
    }

    private func keyboardOverlap(in proxy: GeometryProxy) -> CGFloat {
        guard keyboardEndFrame != .zero else { return 0 }
        guard keyboardEndFrame.minY < proxy.size.height else { return 0 }
        return min(proxy.size.height, max(0, proxy.size.height - keyboardEndFrame.minY))
    }

    private func dismissKeyboardFocus() {
        isEditorFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func updateKeyboardFrame(from notification: Notification, forceHidden: Bool = false) {
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
        let nextFrame = forceHidden ? CGRect.zero : endFrame
        guard keyboardEndFrame != nextFrame else { return }

        withAnimation(.easeOut(duration: duration)) {
            keyboardEndFrame = nextFrame
        }
    }
}

private struct PreviewOutsideOverlayShape: Shape {
    let cutout: CGRect
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: cutout,
            cornerSize: CGSize(width: cornerRadius, height: cornerRadius)
        )
        return path
    }
}

private struct PreviewEllipseCutoutShape: Shape {
    let cutout: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: cutout)
        return path
    }
}

private struct FullscreenLiquidGlassBackground<S: Shape>: View {
    let shape: S
    var tint: Color? = .white
    var tintStrength: Double = 0.08
    var strokeOpacity: Double = 0.18
    var fallbackFill: Color = Color.black.opacity(0.18)
    var fallbackStroke: Color = Color.white.opacity(0.16)
    var fallbackLineWidth: CGFloat = 0.8

    var body: some View {
        if #available(iOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.001))
                .glassEffect(
                    .regular
                        .tint(tint?.opacity(tintStrength))
                        .interactive(),
                    in: shape
                )
                .overlay(
                    shape.fill(Color.black.opacity(0.16))
                )
                .overlay(
                    shape.stroke(Color.white.opacity(strokeOpacity), lineWidth: fallbackLineWidth)
                )
        } else {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(fallbackFill.opacity(0.88)))
                .overlay(shape.stroke(fallbackStroke, lineWidth: fallbackLineWidth))
        }
    }
}

// MARK: - Metering Guide Overlay — 測光範囲のCanvas描画オーバーレイ
struct MeteringGuideOverlay: View {
    let mode: MeteringMode
    let width: CGFloat
    let height: CGFloat
    let spotPoint: CGPoint
    let spotOpacity: Double
    let threePointMetering: ThreePointMeteringDisplay?
    let threePointSelectionMarkers: [ThreePointSelectionMarker]

    var body: some View {
        ZStack {
            Canvas { context, size in
                switch mode {
                case .spot:
                    let x = width * spotPoint.x
                    let y = height * spotPoint.y
                    let color = Color.cyan.opacity(spotOpacity)
                    let outerCircle = Path(ellipseIn: CGRect(x: x - 18, y: y - 18, width: 36, height: 36))
                    context.stroke(outerCircle, with: .color(color), lineWidth: 1.5)
                    let innerCircle = Path(ellipseIn: CGRect(x: x - 8, y: y - 8, width: 16, height: 16))
                    context.stroke(innerCircle, with: .color(color.opacity(0.6)), lineWidth: 0.5)
                    var hLine = Path()
                    hLine.move(to: CGPoint(x: x - 6, y: y))
                    hLine.addLine(to: CGPoint(x: x + 6, y: y))
                    context.stroke(hLine, with: .color(color), lineWidth: 1)
                    var vLine = Path()
                    vLine.move(to: CGPoint(x: x, y: y - 6))
                    vLine.addLine(to: CGPoint(x: x, y: y + 6))
                    context.stroke(vLine, with: .color(color), lineWidth: 1)

                case .centerWeighted:
                    let centerX = width / 2
                    let centerY = height / 2
                    let color = Color.white.opacity(0.2)
                    let coreSize = width * 0.2
                    let coreCircle = Path(ellipseIn: CGRect(x: centerX - coreSize / 2, y: centerY - coreSize / 2, width: coreSize, height: coreSize))
                    context.stroke(coreCircle, with: .color(color), lineWidth: 0.5)
                    let midSize = width * 0.6
                    let midCircle = Path(ellipseIn: CGRect(x: centerX - midSize / 2, y: centerY - midSize / 2, width: midSize, height: midSize))
                    context.stroke(midCircle, with: .color(color.opacity(0.7)), lineWidth: 0.5)

                case .matrix:
                    let color = Color.white.opacity(0.24)
                    let cellWidth = width / 3
                    let cellHeight = height / 3
                    for i in 1..<3 {
                        var line = Path()
                        line.move(to: CGPoint(x: cellWidth * CGFloat(i), y: 0))
                        line.addLine(to: CGPoint(x: cellWidth * CGFloat(i), y: height))
                        context.stroke(line, with: .color(color), lineWidth: 0.8)
                    }
                    for i in 1..<3 {
                        var line = Path()
                        line.move(to: CGPoint(x: 0, y: cellHeight * CGFloat(i)))
                        line.addLine(to: CGPoint(x: width, y: cellHeight * CGFloat(i)))
                        context.stroke(line, with: .color(color), lineWidth: 0.8)
                    }
                    let centerRect = CGRect(x: cellWidth, y: cellHeight, width: cellWidth, height: cellHeight)
                    context.stroke(Path(centerRect), with: .color(Color.white.opacity(0.32)), lineWidth: 0.8)

                case .average:
                    let rect = CGRect(x: 2, y: 2, width: width - 4, height: height - 4)
                    context.stroke(Path(rect), with: .color(Color.white.opacity(0.1)), lineWidth: 0.5)

                case .threePoint:
                    break
                }
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}

// MARK: - Compact Value Control — フルスクリーン用コンパクト値調整UI
struct CompactValueControl: View {
    enum Presentation {
        case fullscreen
        case panel
    }

    let title: String
    let value: String
    var subtitle: String? = nil
    var showTitle: Bool = true
    var refined: Bool = false
    var presentation: Presentation = .panel
    var isAuto: Bool = false
    var autoTint: Color = .meterAccent
    var autoBorderLineWidth: CGFloat = 1
    let isEnabled: Bool
    let isCalculated: Bool
    let onIncrement: () -> Void
    let onDecrement: () -> Void
    @State private var swipeStepIndex: Int = 0
    @State private var isSwipeActive: Bool = false

    private let swipeStepWidth: CGFloat = 20

    private var tintColor: Color {
        if refined && !showTitle {
            if isAuto { return autoTint == .meterRed ? .meterRed : .refinedText }
            if isEnabled { return .refinedText }
            return .refinedTextSoft
        }
        if isAuto { return autoTint }
        if isEnabled { return .meterBlue }
        return .white.opacity(0.84)
    }

    private var valueFontSize: CGFloat {
        let baseSize: CGFloat = {
            switch presentation {
            case .fullscreen:
                if refined && !showTitle {
                    return title == "SS" ? 23 : 24
                }
                return title == "SS" ? 19 : 20
            case .panel:
                if refined && !showTitle {
                    return title == "SS" ? 19 : 20
                }
                return title == "SS" ? 16 : 17
            }
        }()

        switch value.count {
        case 7...:
            return baseSize - 4
        case 5...6:
            return baseSize - 2.5
        case 4:
            return baseSize - 1
        default:
            return baseSize
        }
    }

    private var valueMinimumScaleFactor: CGFloat {
        title == "SS" ? 0.52 : 0.58
    }

    private var cardContentHeight: CGFloat {
        switch presentation {
        case .fullscreen:
            return refined && !showTitle ? 58 : 64
        case .panel:
            return refined && !showTitle ? 56 : 62
        }
    }

    private var cardVerticalPadding: CGFloat {
        presentation == .fullscreen ? 5 : 4
    }

    var body: some View {
        VStack(spacing: 3) {
            if refined && !showTitle {
                Capsule()
                    .fill(tintColor.opacity(isAuto ? 0.92 : 0.68))
                    .frame(width: 16, height: 3)
                    .padding(.bottom, 1)
            }
            if showTitle {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.meterLabel(8))
                        .tracking(1.5)
                        .foregroundColor(refined && !showTitle ? .refinedTextSoft : (isAuto ? autoTint.opacity(0.82) : isEnabled ? .meterBlue.opacity(0.82) : .white.opacity(0.68)))
                        .shadow(color: Color.black.opacity(0.46), radius: 1.4, x: 0, y: 1)
                        .textCase(.uppercase)
                }
            }
            VStack(spacing: 2) {
                VStack(spacing: 1) {
                    Text(value)
                        .font(.meterValue(valueFontSize))
                        .foregroundColor(tintColor)
                        .shadow(color: Color.black.opacity(refined ? 0.62 : 0.35), radius: 2.2, x: 0, y: 1)
                        .frame(maxWidth: .infinity)
                        .lineLimit(1)
                        .allowsTightening(true)
                        .minimumScaleFactor(valueMinimumScaleFactor)
                        .monospacedDigit()
                        .layoutPriority(1)
                    if let subtitle = subtitle ?? ((refined && !showTitle && isAuto) ? " " : nil) {
                        Text(subtitle)
                            .font(.meterValue(10))
                            .foregroundColor(self.subtitle != nil ? tintColor : .clear)
                            .shadow(color: Color.black.opacity(refined ? 0.52 : 0.26), radius: 1.6, x: 0, y: 1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                            .frame(height: refined && !showTitle ? 10 : nil)
                    } else if !(refined && !showTitle) {
                        Text(" ")
                            .font(.meterValue(10))
                            .foregroundColor(.clear)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity)
                    }
                }

                SwipeArrowRail(
                    tint: tintColor,
                    refined: refined && !showTitle,
                    active: isSwipeActive
                )
                .opacity(isEnabled ? 1 : 0)
            }
        }
        .frame(height: cardContentHeight)
        .padding(.vertical, cardVerticalPadding)
        .padding(.horizontal, 6)
        .background(
            FullscreenLiquidGlassBackground(
                shape: RoundedRectangle(cornerRadius: MeterShape.box, style: .continuous),
                tint: isAuto ? autoTint : .white,
                tintStrength: isAuto ? 0.24 : 0.08,
                strokeOpacity: isAuto ? 0.42 : 0.18,
                fallbackFill: refined && !showTitle ? refinedBackground : defaultBackground,
                fallbackStroke: refined && !showTitle ? refinedBorder : defaultBorder,
                fallbackLineWidth: refined && !showTitle ? (isAuto ? autoBorderLineWidth : 0.9) : (isAuto ? autoBorderLineWidth : (isEnabled ? 1 : 0.5))
            )
        )
        .contentShape(RoundedRectangle(cornerRadius: MeterShape.box))
        .gesture(valueSwipeGesture)
        .animation(.easeInOut(duration: 0.2), value: isEnabled)
        .animation(.easeInOut(duration: 0.2), value: isAuto)
    }

    private var valueSwipeGesture: some Gesture {
        DragGesture(minimumDistance: isEnabled ? 6 : .infinity)
            .onChanged { gesture in
                guard isEnabled else { return }
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
                onIncrement()
                HapticManager.shared.selectionChanged()
            }
        } else {
            for _ in 0..<(-delta) {
                onDecrement()
                HapticManager.shared.selectionChanged()
            }
        }
    }

    private var defaultBackground: Color {
        isAuto ? autoTint.opacity(0.08) : isEnabled ? Color.meterBlue.opacity(0.06) : Color.meterButtonBg.opacity(0.5)
    }

    private var defaultBorder: Color {
        isAuto ? autoTint : isEnabled ? Color.meterBlue.opacity(0.25) : Color.black.opacity(0.1)
    }

    private var refinedBackground: Color {
        if isAuto { return autoTint == .meterRed ? autoTint.opacity(0.16) : .refinedSurface }
        if isEnabled { return .refinedSurface }
        return .refinedBackground
    }

    private var refinedBorder: Color {
        if isAuto { return autoTint == .meterRed ? autoTint.opacity(0.95) : Color.white.opacity(0.82) }
        if isEnabled { return .refinedStroke }
        return .refinedStroke.opacity(0.36)
    }
}
