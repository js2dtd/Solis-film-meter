// MARK: - 役割: 通常画面・全画面・共有プレビュー・外部オーバーレイを束ねるメインコンテナ
// MARK: - 目次
// 1. 共有プレビュー位置Preference/Reporter
// 2. MeterContainerViewの状態管理とサイズ計算
// 3. ライフサイクル、アクセス制御、測光設定同期
// 4. 通常/全画面メーターと共有プレビュー遷移
// 5. 設定/撮影記録/初回ガイドの外部オーバーレイ
// 6. キーボード復帰、明暗2点リセット、全画面遷移制御
// 7. 共有プレビュー外側の測光ガイド拡張

import SwiftUI
import UIKit

enum SharedPreviewSurfaceID: Hashable {
    case panel
    case fullscreen
}

struct SharedPreviewSurfacePreferenceKey: PreferenceKey {
    static var defaultValue: [SharedPreviewSurfaceID: CGRect] = [:]

    static func reduce(value: inout [SharedPreviewSurfaceID: CGRect], nextValue: () -> [SharedPreviewSurfaceID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct SharedPreviewSurfaceReporter: View {
    let id: SharedPreviewSurfaceID

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .preference(
                    key: SharedPreviewSurfacePreferenceKey.self,
                    value: [id: proxy.frame(in: .named("meterContainer"))]
                )
        }
    }
}

struct MeterContainerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var sessionStore: AppSessionStore
    @ObservedObject var accessStore: PurchaseAccessStore

    @StateObject private var viewModel = ExposureViewModel()
    @StateObject private var cameraManager = LightMeterCameraManager()
    @StateObject private var shotRecordStore = ShotRecordStore()

    @State private var controlPanelOffset: CGFloat = 400
    @State private var showSettings = false
    @State private var showShotHistory = false
    @State private var settingsOverlayWindow: AppOverlayWindowController?
    @State private var shotHistoryOverlayWindow: AppOverlayWindowController?
    @State private var showInitialDisplayGuide = false
    @State private var containerSize: CGSize = .zero
    @State private var stableContainerSize: CGSize = .zero
    @State private var sharedPreviewFrames: [SharedPreviewSurfaceID: CGRect] = [:]
    @State private var deferredSharedPreviewFrames: [SharedPreviewSurfaceID: CGRect]?
    @State private var hasStartedMeterFlow = false
    @State private var isKeyboardVisible = false
    @State private var isInputOverlayWindowActive = false
    @State private var pendingFullscreenTransitionAfterKeyboard = false
    @State private var pendingFullscreenTransitionWorkItem: DispatchWorkItem?

    private var isControlPanelOpen: Bool { controlPanelOffset < 1 }
    private var accessPolicy: AppAccessPolicy { accessStore.policy }
    private var screenWidth: CGFloat { activeContainerSize.width > 0 ? activeContainerSize.width : 400 }
    private var screenHeight: CGFloat { activeContainerSize.height > 0 ? activeContainerSize.height : 800 }
    private var activeContainerSize: CGSize {
        if stableContainerSize.width > 1, stableContainerSize.height > 1 {
            return stableContainerSize
        }
        if containerSize.width > 1, containerSize.height > 1 {
            return containerSize
        }
        return normalizedScreenBoundsSize()
    }
    private var transitionProgress: CGFloat {
        let width = max(screenWidth, 1)
        return min(max(controlPanelOffset / width, 0), 1)
    }
    private var panelPreviewFrame: CGRect {
        sharedPreviewFrames[.panel] ?? .zero
    }
    private var fullscreenPreviewFrame: CGRect {
        sharedPreviewFrames[.fullscreen] ?? .zero
    }
    private var effectivePanelPreviewFrame: CGRect {
        guard panelPreviewFrame.width > 1, panelPreviewFrame.height > 1 else {
            let fallbackWidth: CGFloat = 187
            let fallbackHeight: CGFloat = 280
            return CGRect(
                x: max(0, (screenWidth - fallbackWidth) / 2),
                y: max(0, (screenHeight - fallbackHeight) * 0.18),
                width: fallbackWidth,
                height: fallbackHeight
            )
        }
        return panelPreviewFrame
    }
    private var effectiveFullscreenPreviewFrame: CGRect {
        guard fullscreenPreviewFrame.width > 1, fullscreenPreviewFrame.height > 1 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        return fullscreenPreviewFrame
    }
    private var interpolatedPreviewFrame: CGRect {
        let start = effectivePanelPreviewFrame
        let end = effectiveFullscreenPreviewFrame
        let progress = transitionProgress

        return CGRect(
            x: start.minX + ((end.minX - start.minX) * progress),
            y: start.minY + ((end.minY - start.minY) * progress),
            width: start.width + ((end.width - start.width) * progress),
            height: start.height + ((end.height - start.height) * progress)
        )
    }
    private var previewDisplayFrame: CGRect {
        let frame = interpolatedPreviewFrame
        guard containerSize.width > 1, containerSize.height > 1 else {
            return frame
        }

        let expansionProgress = min(max((transitionProgress - 0.55) / 0.45, 0), 1)
        guard expansionProgress > 0 else {
            return frame
        }

        let verticalFillFrame = verticalFillPreviewFrame
        return CGRect(
            x: frame.minX + ((verticalFillFrame.minX - frame.minX) * expansionProgress),
            y: frame.minY + ((verticalFillFrame.minY - frame.minY) * expansionProgress),
            width: frame.width + ((verticalFillFrame.width - frame.width) * expansionProgress),
            height: frame.height + ((verticalFillFrame.height - frame.height) * expansionProgress)
        )
    }
    private var verticalFillPreviewFrame: CGRect {
        guard containerSize.width > 1, containerSize.height > 1 else {
            return interpolatedPreviewFrame
        }
        let height = containerSize.height
        let width = height * 2 / 3
        return CGRect(
            x: (containerSize.width - width) / 2,
            y: 0,
            width: width,
            height: height
        )
    }
    private var fullscreenVisibleFocalLengthMultiplier: Double {
        LensFocalLengthGuide.fullscreenVisibleFocalLengthMultiplier(for: activeContainerSize)
    }
    private var activePreviewVisibleRect: CGRect {
        let displayFrame = previewDisplayFrame
        let meteringFrame = interpolatedPreviewFrame
        guard displayFrame.width > 1, displayFrame.height > 1 else { return .zero }

        let localRect = meteringFrame.offsetBy(dx: -displayFrame.minX, dy: -displayFrame.minY)
        let bounds = CGRect(origin: .zero, size: displayFrame.size)
        let clippedRect = localRect.intersection(bounds)
        return clippedRect.isNull ? bounds : clippedRect
    }
    var body: some View {
        keyboardNotificationConfiguredContainer
    }

    private var rootContainer: some View {
        ZStack {
            meterSurfaceLayer
                .zIndex(0)

            keyboardPresentationLayer
                .zIndex(10)
        }
        .ignoresSafeArea(.keyboard)
    }

    private var layoutConfiguredContainer: some View {
        rootContainer
        .coordinateSpace(name: "meterContainer")
        .onPreferenceChange(SharedPreviewSurfacePreferenceKey.self) { frames in
            updateSharedPreviewFrames(frames)
        }
        .statusBarHidden(!isControlPanelOpen)
    }

    private var lifecycleConfiguredContainer: some View {
        layoutConfiguredContainer
        .onAppear {
            applyAccessPolicy()
            if !showInitialDisplayGuide {
                startMeterFlowIfNeeded()
            }
        }
        .onDisappear {
            dismissInputOverlayWindows()
            cameraManager.stopSession()
            hasStartedMeterFlow = false
        }
    }

    private var meteringConfiguredContainer: some View {
        lifecycleConfiguredContainer
        .onChange(of: cameraManager.currentEV) { _, newValue in
            let shouldForceUpdate = viewModel.meteringMode == .threePoint && cameraManager.threePointMetering != nil
            viewModel.updateMeasuredEV(newValue, force: shouldForceUpdate)
        }
        .onChange(of: viewModel.meteringMode) { _, newValue in
            guard viewModel.allowsMeteringMode(newValue, for: accessPolicy) else {
                viewModel.meteringMode = viewModel.defaultMeteringMode(for: accessPolicy)
                return
            }
            if !viewModel.isIncidentMode && viewModel.isLocked {
                viewModel.setLock(false)
                cameraManager.unlockExposure()
            }
            cameraManager.setMeteringMode(newValue)
        }
        .onChange(of: viewModel.exposureMode) { _, _ in
            guard !viewModel.isIncidentMode, viewModel.meteringMode == .threePoint else { return }
            if viewModel.isLocked {
                viewModel.setLock(false)
                cameraManager.unlockExposure()
            }
            cameraManager.restartThreePointSelection()
        }
        .onChange(of: viewModel.isIncidentMode) { _, newValue in
            guard !newValue || accessPolicy.allows(.incidentMetering) else {
                viewModel.isIncidentMode = false
                return
            }
            if newValue {
                let defaultMeteringMode = viewModel.defaultMeteringMode(for: accessPolicy)
                if viewModel.meteringMode != defaultMeteringMode {
                    viewModel.meteringMode = defaultMeteringMode
                }
                requestFullscreenTransition()
            } else {
                let defaultMeteringMode = viewModel.defaultMeteringMode(for: accessPolicy)
                if viewModel.meteringMode != defaultMeteringMode {
                    viewModel.meteringMode = defaultMeteringMode
                }
            }
            cameraManager.setIncidentMode(newValue)
        }
        .onChange(of: sessionStore.selectedPresetID) { _, _ in
            syncLensPreset()
        }
        .onChange(of: sessionStore.presets) { _, _ in
            syncLensPreset()
        }
        .onChange(of: accessStore.accessLevel) { _, _ in
            applyAccessPolicy()
            syncLensPreset()
            cameraManager.setMeteringMode(viewModel.meteringMode)
            cameraManager.setIncidentMode(viewModel.isIncidentMode)
        }
        .onChange(of: viewModel.spotBrightAreaWarningEnabled) { _, _ in
            syncSpotMeteringPreferences()
        }
        .onChange(of: viewModel.spotOffTargetWarningEnabled) { _, _ in
            syncSpotMeteringPreferences()
        }
        .onChange(of: viewModel.spotMeteringReferenceTarget) { _, _ in
            syncSpotMeteringPreferences()
        }
        .onChange(of: viewModel.spotExposureBoostPreset) { _, _ in
            syncSpotMeteringPreferences()
        }
    }

    private var overlayConfiguredContainer: some View {
        meteringConfiguredContainer
        .onChange(of: showInitialDisplayGuide) { _, isShowing in
            if !isShowing {
                startMeterFlowIfNeeded()
            }
        }
        .onChange(of: showSettings) { _, isShowing in
            if isShowing {
                presentSettingsOverlayWindow()
            } else {
                dismissSettingsOverlayWindow()
            }
        }
        .onChange(of: showShotHistory) { _, isShowing in
            if isShowing {
                presentShotHistoryOverlayWindow()
            } else {
                dismissShotHistoryOverlayWindow()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active, hasStartedMeterFlow else { return }
            cameraManager.refreshAuthorizationStatus()
        }
    }

    private var keyboardNotificationConfiguredContainer: some View {
        overlayConfiguredContainer
        .onReceive(NotificationCenter.default.publisher(for: .appOverlayWindowActivityChanged)) { notification in
            let isActive = notification.userInfo?[AppOverlayWindowActivityUserInfoKey.isActive] as? Bool ?? false
            isInputOverlayWindowActive = isActive
            isKeyboardVisible = false
            restoreStableContainerSize()

            if !isActive {
                applyDeferredSharedPreviewFramesIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            guard !isInputOverlayWindowActive else {
                isKeyboardVisible = false
                restoreStableContainerSize()
                return
            }
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            guard !isInputOverlayWindowActive else {
                isKeyboardVisible = false
                restoreStableContainerSize()
                return
            }
            isKeyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
            guard !isInputOverlayWindowActive else {
                isKeyboardVisible = false
                restoreStableContainerSize()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isKeyboardVisible = false
                if pendingFullscreenTransitionAfterKeyboard {
                    completePendingFullscreenTransitionAfterKeyboard()
                } else {
                    restoreStableContainerSize()
                }
            }
        }
    }

    private var meterSurfaceLayer: some View {
        ZStack {
            (viewModel.showAuxiliaryLabels ? Color.meterBackground : Color.refinedBackground)
                .ignoresSafeArea(.container)

            GeometryReader { geo in
                Color.clear.onAppear {
                    updateContainerSize(geo.size, initialize: true)
                }
                .onChange(of: geo.size) { _, newSize in
                    updateContainerSize(newSize)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container)
            .ignoresSafeArea(.keyboard)

            sharedPreviewOverlay
            fullscreenMeteringGuideExtensionOverlay

            FullScreenMeterView(
                cameraManager: cameraManager,
                viewModel: viewModel,
                accessStore: accessStore,
                shotRecordStore: shotRecordStore,
                activePreset: accessPolicy.allows(.presets) ? sessionStore.activePreset : nil,
                controlPanelOffset: $controlPanelOffset,
                screenWidth: screenWidth,
                screenHeight: screenHeight,
                visibleFocalLengthMultiplier: fullscreenVisibleFocalLengthMultiplier,
                showSettings: $showSettings,
                showShotHistory: $showShotHistory
            )
            .opacity(viewModel.isIncidentMode ? 1 : Double(transitionProgress))
            .allowsHitTesting(viewModel.isIncidentMode || transitionProgress > 0.5)

            ContentView(
                viewModel: viewModel,
                cameraManager: cameraManager,
                accessStore: accessStore,
                shotRecordStore: shotRecordStore,
                controlPanelOffset: $controlPanelOffset,
                screenWidth: screenWidth,
                visibleFocalLengthMultiplier: fullscreenVisibleFocalLengthMultiplier,
                showSettings: $showSettings,
                showShotHistory: $showShotHistory,
                requestFullscreenTransition: requestFullscreenTransition
            )
            .opacity(viewModel.isIncidentMode ? 0 : Double(1 - transitionProgress))
            .allowsHitTesting(!viewModel.isIncidentMode && transitionProgress <= 0.5)
            .zIndex(1)
        }
        .frame(width: screenWidth, height: screenHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard)
    }

    private var keyboardPresentationLayer: some View {
        ZStack {
            Color.clear
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fullScreenCover(isPresented: $showInitialDisplayGuide) {
            InitialDisplayModeGuideView(viewModel: viewModel, isPresented: $showInitialDisplayGuide)
        }
    }

    private func requestFullscreenTransition() {
        pendingFullscreenTransitionAfterKeyboard = true
        pendingFullscreenTransitionWorkItem?.cancel()

        dismissKeyboard()

        let waitDuration: TimeInterval = isKeyboardVisible ? 0.8 : 0.12
        let workItem = DispatchWorkItem {
            completePendingFullscreenTransitionAfterKeyboard()
        }
        pendingFullscreenTransitionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + waitDuration, execute: workItem)
    }

    private func completePendingFullscreenTransitionAfterKeyboard() {
        guard pendingFullscreenTransitionAfterKeyboard else { return }

        pendingFullscreenTransitionAfterKeyboard = false
        pendingFullscreenTransitionWorkItem?.cancel()
        pendingFullscreenTransitionWorkItem = nil
        isKeyboardVisible = false

        restoreStableContainerSize()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.easeInOut(duration: 0.18)) {
                controlPanelOffset = screenWidth
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func dismissInputOverlayWindows() {
        dismissSettingsOverlayWindow()
        dismissShotHistoryOverlayWindow()
    }

    private func presentSettingsOverlayWindow() {
        dismissSettingsOverlayWindow()
        dismissKeyboard()

        let controller = AppOverlayWindowController()
        settingsOverlayWindow = controller
        controller.present(windowLevel: .normal + 2, transition: .settings) {
            SettingsView(
                viewModel: viewModel,
                cameraManager: cameraManager,
                sessionStore: sessionStore,
                accessStore: accessStore,
                onDismiss: {
                    showSettings = false
                }
            )
            .preferredColorScheme(viewModel.showAuxiliaryLabels ? .light : .dark)
        }
    }

    private func dismissSettingsOverlayWindow() {
        settingsOverlayWindow?.dismiss()
        settingsOverlayWindow = nil
    }

    private func presentShotHistoryOverlayWindow() {
        guard accessPolicy.allows(.shotRecords) else {
            showShotHistory = false
            return
        }

        dismissShotHistoryOverlayWindow()
        dismissKeyboard()

        let controller = AppOverlayWindowController()
        shotHistoryOverlayWindow = controller
        controller.present(windowLevel: .normal + 2) {
            ShotHistoryView(
                store: shotRecordStore,
                refined: !viewModel.showAuxiliaryLabels,
                onDismiss: {
                    showShotHistory = false
                }
            )
        }
    }

    private func dismissShotHistoryOverlayWindow() {
        shotHistoryOverlayWindow?.dismiss()
        shotHistoryOverlayWindow = nil
    }

    private func updateContainerSize(_ newSize: CGSize, initialize: Bool = false) {
        guard newSize.width > 1, newSize.height > 1 else { return }
        let previousFocalLengthMultiplier = fullscreenVisibleFocalLengthMultiplier
        defer {
            let updatedFocalLengthMultiplier = fullscreenVisibleFocalLengthMultiplier
            if hasStartedMeterFlow, abs(updatedFocalLengthMultiplier - previousFocalLengthMultiplier) > 0.01 {
                syncLensPreset()
            }
        }

        if initialize || containerSize == .zero {
            let initialSize = stableFullscreenSize(from: newSize)
            containerSize = initialSize
            stableContainerSize = initialSize
            controlPanelOffset = initialSize.width
            return
        }

        if shouldIgnoreKeyboardCompressedSize(newSize) {
            restoreStableContainerSize()
            return
        }

        let stableSize = stableFullscreenSize(from: newSize)
        containerSize = stableSize
        stableContainerSize = stableSize
    }

    private func restoreStableContainerSize() {
        if stableContainerSize.width > 1, stableContainerSize.height > 1 {
            containerSize = stableContainerSize
        }
    }

    private func shouldIgnoreKeyboardCompressedSize(_ newSize: CGSize) -> Bool {
        if isInputOverlayWindowActive { return true }
        guard containerSize.width > 1, containerSize.height > 1 else { return false }
        guard abs(newSize.width - containerSize.width) < 1 else { return false }

        let baselineHeight = max(containerSize.height, stableContainerSize.height)
        let shrinkAmount = baselineHeight - newSize.height
        return isKeyboardVisible || shrinkAmount > 80
    }

    private func stableFullscreenSize(from proposedSize: CGSize) -> CGSize {
        let screenSize = normalizedScreenBoundsSize()
        let baselineSize = stableContainerSize.width > 1 && stableContainerSize.height > 1
            ? stableContainerSize
            : screenSize

        return CGSize(
            width: max(proposedSize.width, baselineSize.width),
            height: max(proposedSize.height, baselineSize.height)
        )
    }

    private func normalizedScreenBoundsSize() -> CGSize {
        let bounds = UIScreen.main.bounds
        let minSide = min(bounds.width, bounds.height)
        let maxSide = max(bounds.width, bounds.height)
        return CGSize(width: minSide, height: maxSide)
    }

    private func updateSharedPreviewFrames(_ frames: [SharedPreviewSurfaceID: CGRect]) {
        if isInputOverlayWindowActive {
            deferredSharedPreviewFrames = frames
            return
        }

        guard !isKeyboardVisible, !pendingFullscreenTransitionAfterKeyboard else { return }
        guard !shouldIgnoreKeyboardCompressedPreviewFrames(frames) else { return }
        sharedPreviewFrames = frames
    }

    private func applyDeferredSharedPreviewFramesIfNeeded() {
        guard let frames = deferredSharedPreviewFrames else { return }
        deferredSharedPreviewFrames = nil

        guard !shouldIgnoreKeyboardCompressedPreviewFrames(frames) else { return }
        sharedPreviewFrames = frames
    }

    private func shouldIgnoreKeyboardCompressedPreviewFrames(_ frames: [SharedPreviewSurfaceID: CGRect]) -> Bool {
        if isInputOverlayWindowActive { return true }
        guard let currentFullscreenFrame = sharedPreviewFrames[.fullscreen],
              let nextFullscreenFrame = frames[.fullscreen],
              currentFullscreenFrame.width > 1,
              nextFullscreenFrame.width > 1 else {
            return false
        }

        let hasSameWidth = abs(currentFullscreenFrame.width - nextFullscreenFrame.width) < 1
        let movedUpOrShrank = nextFullscreenFrame.maxY < currentFullscreenFrame.maxY - 80
            || nextFullscreenFrame.height < currentFullscreenFrame.height - 80

        return hasSameWidth && movedUpOrShrank && (isKeyboardVisible || shouldShowFullscreenPreviewEffects)
    }

    private func syncSpotMeteringPreferences() {
        cameraManager.updateSpotMeteringPreferences(
            brightAreaWarningEnabled: viewModel.spotBrightAreaWarningEnabled,
            offTargetWarningEnabled: viewModel.spotOffTargetWarningEnabled,
            referenceTarget: viewModel.spotMeteringReferenceTarget,
            exposureBoostPreset: viewModel.spotExposureBoostPreset
        )
    }

    private func startMeterFlowIfNeeded() {
        guard !hasStartedMeterFlow else { return }
        hasStartedMeterFlow = true

        applyAccessPolicy()
        cameraManager.startSession()
        cameraManager.setMeteringMode(viewModel.meteringMode)
        cameraManager.updateSpotMeteringPreferences(
            brightAreaWarningEnabled: viewModel.spotBrightAreaWarningEnabled,
            offTargetWarningEnabled: viewModel.spotOffTargetWarningEnabled,
            referenceTarget: viewModel.spotMeteringReferenceTarget,
            exposureBoostPreset: viewModel.spotExposureBoostPreset
        )
        syncLensPreset()
    }

    private func applyAccessPolicy() {
        viewModel.applyAccessPolicy(accessPolicy)
        if !accessPolicy.allows(.autoExposureLock), viewModel.isLocked {
            viewModel.setLock(false)
            cameraManager.unlockExposure()
        }
    }

    private func syncLensPreset() {
        cameraManager.setLensPreset(
            accessPolicy.allows(.presets) ? sessionStore.activePreset : nil,
            visibleFocalLengthMultiplier: fullscreenVisibleFocalLengthMultiplier
        )
    }

    private var shouldShowFullscreenPreviewEffects: Bool {
        !viewModel.isIncidentMode &&
        transitionProgress > 0.9 &&
        containerSize.width > 1 &&
        containerSize.height > 1
    }

    private var visibleMeteringFrame: CGRect {
        let screenRect = CGRect(origin: .zero, size: containerSize)
        let frame = interpolatedPreviewFrame.intersection(screenRect)
        return frame.isNull ? .zero : frame
    }

    private var sharedPreviewOverlay: some View {
        let frame = previewDisplayFrame
        let shouldShowPreview = !viewModel.isIncidentMode
            && cameraManager.isAuthorized
            && cameraManager.isRunning
            && !cameraManager.isCameraSwitching
            && frame.width > 1
            && frame.height > 1

        return Group {
            if shouldShowPreview {
                CameraPreviewView(
                    session: cameraManager.session,
                    isActive: true,
                    onPreviewLayerUpdate: { previewLayer in
                        cameraManager.setActivePreviewLayer(previewLayer, visibleRect: activePreviewVisibleRect)
                    }
                )
                .frame(width: frame.width, height: frame.height)
                .clipShape(RoundedRectangle(cornerRadius: transitionProgress > 0.55 ? 0 : MeterShape.preview))
                .position(x: frame.midX, y: frame.midY)
                .ignoresSafeArea(.container, edges: transitionProgress > 0.55 ? .all : [])
                .transaction { transaction in
                    transaction.animation = nil
                }
                .allowsHitTesting(false)
            }
        }
    }

    private var fullscreenThreePointResetButton: some View {
        let shouldShowReset = shouldShowFullscreenPreviewEffects
            && viewModel.meteringMode == .threePoint
            && cameraManager.threePointMetering != nil

        return Group {
            if shouldShowReset {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            if viewModel.isLocked {
                                viewModel.setLock(false)
                                cameraManager.unlockExposure()
                            }
                            cameraManager.restartThreePointSelection()
                            if viewModel.enableHaptics {
                                HapticManager.shared.selectionChanged()
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 12, weight: .bold))
                                Text("再測光")
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .tracking(0.7)
                            }
                            .foregroundColor(viewModel.showAuxiliaryLabels ? .white : .refinedText)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        Capsule()
                                            .fill(Color.cyan.opacity(0.12))
                                    )
                                    .overlay(
                                        Capsule()
                                            .stroke(Color.white.opacity(0.34), lineWidth: 0.9)
                                    )
                                    .shadow(color: Color.black.opacity(0.28), radius: 12, x: 0, y: 4)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.trailing, 24)
                    .padding(.bottom, 142)
                }
                .frame(width: containerSize.width, height: containerSize.height)
            }
        }
    }

    private var fullscreenMeteringGuideExtensionOverlay: some View {
        let frame = visibleMeteringFrame
        let shouldShowGuideExtension = shouldShowFullscreenPreviewEffects
            && modeUsesFullscreenGuideExtension(viewModel.meteringMode)
            && frame.width > 1
            && frame.height > 1

        return Group {
            if shouldShowGuideExtension {
                FullscreenMeteringGuideExtensionOverlay(
                    mode: viewModel.meteringMode,
                    screenSize: containerSize,
                    meteringFrame: frame,
                    refined: !viewModel.showAuxiliaryLabels
                )
                .allowsHitTesting(false)
            }
        }
    }

    private func modeUsesFullscreenGuideExtension(_ mode: MeteringMode) -> Bool {
        switch mode {
        case .spot, .threePoint, .matrix:
            return true
        case .centerWeighted, .average:
            return false
        }
    }

}

private struct FullscreenMeteringGuideExtensionOverlay: View {
    let mode: MeteringMode
    let screenSize: CGSize
    let meteringFrame: CGRect
    let refined: Bool

    var body: some View {
        ZStack {
            if mode == .spot || mode == .threePoint {
                OutsideMeteringFrameShape(cutout: meteringFrame, cornerRadius: MeterShape.preview)
                    .fill(
                        Color.black.opacity(refined ? 0.44 : 0.34),
                        style: FillStyle(eoFill: true)
                    )
            } else {
                Canvas { context, size in
                    drawExtendedGuide(in: &context, size: size)
                }
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .clipped()
    }

    private func drawExtendedGuide(in context: inout GraphicsContext, size: CGSize) {
        switch mode {
        case .matrix:
            drawMatrixGuide(in: &context, size: size)
        case .centerWeighted:
            drawCenterWeightedGuide(in: &context)
        case .average:
            drawAverageGuide(in: &context)
        case .spot, .threePoint:
            break
        }
    }

    private func drawMatrixGuide(in context: inout GraphicsContext, size: CGSize) {
        let color = Color.white.opacity(refined ? 0.24 : 0.18)
        let verticalXPositions = [
            meteringFrame.minX + meteringFrame.width / 3,
            meteringFrame.minX + meteringFrame.width * 2 / 3
        ]
        let horizontalYPositions = [
            meteringFrame.minY + meteringFrame.height / 3,
            meteringFrame.minY + meteringFrame.height * 2 / 3
        ]

        for x in verticalXPositions {
            var topLine = Path()
            topLine.move(to: CGPoint(x: x, y: 0))
            topLine.addLine(to: CGPoint(x: x, y: meteringFrame.minY))
            context.stroke(topLine, with: .color(color), lineWidth: 0.8)

            var bottomLine = Path()
            bottomLine.move(to: CGPoint(x: x, y: meteringFrame.maxY))
            bottomLine.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(bottomLine, with: .color(color), lineWidth: 0.8)
        }

        for y in horizontalYPositions {
            var leftLine = Path()
            leftLine.move(to: CGPoint(x: 0, y: y))
            leftLine.addLine(to: CGPoint(x: meteringFrame.minX, y: y))
            context.stroke(leftLine, with: .color(color), lineWidth: 0.8)

            var rightLine = Path()
            rightLine.move(to: CGPoint(x: meteringFrame.maxX, y: y))
            rightLine.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(rightLine, with: .color(color), lineWidth: 0.8)
        }
    }

    private func drawCenterWeightedGuide(in context: inout GraphicsContext) {
        let center = CGPoint(x: meteringFrame.midX, y: meteringFrame.midY)
        let color = Color.white.opacity(0.2)
        let coreSize = meteringFrame.width * 0.2
        let midSize = meteringFrame.width * 0.6

        context.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - coreSize / 2,
                y: center.y - coreSize / 2,
                width: coreSize,
                height: coreSize
            )),
            with: .color(color),
            lineWidth: 0.5
        )
        context.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - midSize / 2,
                y: center.y - midSize / 2,
                width: midSize,
                height: midSize
            )),
            with: .color(color.opacity(0.7)),
            lineWidth: 0.5
        )
    }

    private func drawAverageGuide(in context: inout GraphicsContext) {
        context.stroke(
            Path(CGRect(
                x: meteringFrame.minX + 2,
                y: meteringFrame.minY + 2,
                width: meteringFrame.width - 4,
                height: meteringFrame.height - 4
            )),
            with: .color(Color.white.opacity(0.1)),
            lineWidth: 0.5
        )
    }
}

private struct OutsideMeteringFrameShape: Shape {
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
