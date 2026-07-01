//
//  LightMeterCameraManager.swift
//  Solis film meter
//

// MARK: - 役割: カメラ制御と測光入力を管理するマネージャー
// MARK: - 目次
// 1. 明暗2点測光サンプル/状態モデル
// 2. カメラセッション、権限、デバイス設定
// 3. 露出ロック、ズーム、フォーカス、プレビュー矩形
// 4. 反射光/入射光モードと各測光入力処理
// 5. スポット/明暗2点測光の選択、リセット、AEL
// 6. プレビュー画像解析、安定判定、EV更新
// 7. レンズプリセット、警告、キャリブレーション、設定同期
// 8. VideoDataOutputデリゲートとCameraError

import AVFoundation
import CoreImage
import UIKit
import Combine

enum ThreePointSampleKind: String, CaseIterable {
    case highlight
    case midtone
    case shadow

    var label: String {
        switch self {
        case .highlight: return "明"
        case .midtone: return "中"
        case .shadow: return "暗"
        }
    }
}

struct ThreePointMeteringSampleDisplay: Identifiable, Equatable {
    let kind: ThreePointSampleKind
    let point: CGPoint
    let ev: Double

    var id: String { kind.rawValue }
}

struct ThreePointMeteringDisplay: Equatable {
    let highlight: ThreePointMeteringSampleDisplay
    let midtone: ThreePointMeteringSampleDisplay
    let shadow: ThreePointMeteringSampleDisplay
    let dynamicRangeEV: Double
    let exposureBiasEV: Double

    var samples: [ThreePointMeteringSampleDisplay] {
        [highlight, midtone, shadow]
    }
}

struct ThreePointSelectionMarker: Identifiable, Equatable {
    let kind: ThreePointSampleKind
    let point: CGPoint

    var id: String { kind.rawValue }
}

enum ThreePointMeteringState: Equatable {
    case inactive
    case analyzing
    case locked
}

private struct ThreePointCapturedSample {
    let ev: Double
    let spotLuminance: Double
}

private enum ReflectiveMeasurementState: Equatable {
    case idle
    case measuring
}

class LightMeterCameraManager: NSObject, ObservableObject {

    @Published var isRunning = false
    @Published var currentEV: Double = 0
    @Published var isAuthorized = false
    @Published var error: CameraError?
    @Published var previewImage: CGImage?
    @Published var isIncidentMode: Bool = false
    @Published private(set) var measurementStability: Double = 0
    @Published private(set) var measurementStateText: String = "準備中"
    @Published private(set) var currentEquivalentFocalLength: Double = 35
    @Published private(set) var currentLensDisplay: String = "35mm"
    @Published private(set) var isZoomLensPreset: Bool = false
    @Published private(set) var allowsFullscreenZoom: Bool = false
    @Published private(set) var isCameraSwitching: Bool = false
    @Published private(set) var isReflectiveMeasurementInProgress: Bool = false
    @Published private(set) var threePointMetering: ThreePointMeteringDisplay?
    @Published private(set) var threePointMeteringState: ThreePointMeteringState = .inactive
    @Published private(set) var threePointSelectionMarkers: [ThreePointSelectionMarker] = []
    @Published private(set) var threePointPendingKind: ThreePointSampleKind?
    @Published private(set) var spotMeteringWarning: SpotMeteringWarning = .none

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.filmlightmeter.camera")
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let lightMeter = LightMeterEngine()
    // sessionQueue 上でのみアクセス
    private var meteringMode: MeteringMode = .spot
    private var spotMeteringPoint = CGPoint(x: 0.5, y: 0.5)
    private var evHistory: [Double] = []
    private var currentCamera: AVCaptureDevice?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var skipLuminanceCorrection: Bool = false
    private var frameCounter: Int = 0
    private var latestPreviewPixelBuffer: CVPixelBuffer?
    private var latestPreviewFrameSize: CGSize?
    private var lastPublishedEV: Double?
    private var filteredEV: Double?
    private var lastPublishedMeasurementStability: Double?
    private var lastPublishedMeasurementStateText: String?
    private var settlingFramesRemaining = 0
    private let defaultEquivalentFocalLength = LensFocalLengthGuide.wideEndRequestEquivalentFocalLength
    private let previewLandscapeAspectRatio = 3.0 / 2.0
    private let spotAEAssistZoomRatio = 0.42
    private let spotExposureRectSize = CGSize(width: 0.16, height: 0.16)
    private let threePointExposureRectSize = CGSize(width: 0.14, height: 0.14)
    private let reflectedCalibrationKey = "reflectedMeterCalibrationOffset"
    private let incidentCalibrationKey = "incidentMeterCalibrationOffset"
    private let reflectedCalibrationBaselineMigrationKey = "reflectedMeterCalibrationBaselineMigration_v1"
    private let defaultReflectedCalibrationOffset = -1.0 / 3.0
    private let reflectiveMeasurementMinimumSamples = 3
    private let defaultExposurePointOfInterest = CGPoint(x: 0.5, y: 0.5)
    private var hasConfiguredSession = false
    private var spotBrightAreaWarningEnabled = SavedSettings.defaultSettings.spotBrightAreaWarningEnabled
    private var spotOffTargetWarningEnabled = SavedSettings.defaultSettings.spotOffTargetWarningEnabled
    private var spotMeteringReferenceTarget = SavedSettings.defaultSettings.spotMeteringReferenceTarget
    private var spotExposureBoostPreset = SavedSettings.defaultSettings.spotExposureBoostPreset
    private var lockedThreePointDisplay: ThreePointMeteringDisplay?
    private var manualThreePointSamples: [ThreePointSampleKind: ThreePointCapturedSample] = [:]
    private var reflectiveMeasurementState: ReflectiveMeasurementState = .idle
    private var reflectiveMeasurementCompletion: ((Double) -> Void)?
    private var activePreviewMeasurementRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @MainActor private weak var activePreviewLayer: AVCaptureVideoPreviewLayer?
    @MainActor private var activePreviewVisibleRect: CGRect = .zero
    private var reflectedMeterCalibrationOffset: Double {
        get {
            if let value = UserDefaults.standard.object(forKey: reflectedCalibrationKey) as? Double {
                return value
            }
            return defaultReflectedCalibrationOffset
        }
        set { UserDefaults.standard.set(newValue, forKey: reflectedCalibrationKey) }
    }
    private var incidentMeterCalibrationOffset: Double {
        get { UserDefaults.standard.double(forKey: incidentCalibrationKey) }
        set { UserDefaults.standard.set(newValue, forKey: incidentCalibrationKey) }
    }

    @Published var calibrationOffset: Double = 0

    var session: AVCaptureSession {
        captureSession
    }

    func setCalibrationOffset(_ offset: Double, forIncident: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if forIncident {
                self.incidentMeterCalibrationOffset = offset
            } else {
                self.reflectedMeterCalibrationOffset = offset
            }
            DispatchQueue.main.async {
                self.calibrationOffset = offset
            }
        }
    }

    func loadCalibrationOffset(forIncident: Bool) {
        let offset = forIncident ? incidentMeterCalibrationOffset : reflectedMeterCalibrationOffset
        DispatchQueue.main.async { [weak self] in
            self?.calibrationOffset = offset
        }
    }

    func updateSpotMeteringPreferences(
        brightAreaWarningEnabled: Bool,
        offTargetWarningEnabled: Bool,
        referenceTarget: SpotMeteringReferenceTarget,
        exposureBoostPreset: SpotMeteringExposureBoostPreset
    ) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.spotBrightAreaWarningEnabled = brightAreaWarningEnabled
            self.spotOffTargetWarningEnabled = offTargetWarningEnabled
            self.spotMeteringReferenceTarget = referenceTarget
            self.spotExposureBoostPreset = exposureBoostPreset
            if !brightAreaWarningEnabled && !offTargetWarningEnabled {
                self.publishSpotWarning(.none)
            }
            if self.meteringMode == .spot {
                self.resetMeteringState(settleFrames: 1)
            }
        }
    }

    private var desiredEquivalentFocalLength = LensFocalLengthGuide.wideEndRequestEquivalentFocalLength
    private var zoomLensPresetEnabled = false
    private var visibleFocalLengthMultiplier = 1.0

    override init() {
        super.init()
        applyCalibrationBaselineIfNeeded()
        applySavedSpotMeteringPreferences()
        calibrationOffset = reflectedMeterCalibrationOffset
        checkAuthorization()
    }

    private func applyCalibrationBaselineIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: reflectedCalibrationBaselineMigrationKey) else { return }

        if let storedOffset = defaults.object(forKey: reflectedCalibrationKey) as? Double,
           abs(storedOffset) < 0.001 {
            defaults.set(defaultReflectedCalibrationOffset, forKey: reflectedCalibrationKey)
        }

        defaults.set(true, forKey: reflectedCalibrationBaselineMigrationKey)
    }

    private func applySavedSpotMeteringPreferences() {
        let settings = UserDefaults.standard.savedSettings ?? .defaultSettings
        spotBrightAreaWarningEnabled = settings.spotBrightAreaWarningEnabled
        spotOffTargetWarningEnabled = settings.spotOffTargetWarningEnabled
        spotMeteringReferenceTarget = settings.spotMeteringReferenceTarget
        spotExposureBoostPreset = settings.spotExposureBoostPreset
    }

    private func checkAuthorization() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.isAuthorized = true
                self.error = nil
            }
            setupSession()
        case .notDetermined:
            requestVideoAccess(startRunningAfterGrant: false)
        case .denied:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.error = .notAuthorized
                self.isRunning = false
            }
            stopSession()
        case .restricted:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.error = .restricted
                self.isRunning = false
            }
            stopSession()
        @unknown default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.isRunning = false
            }
        }
    }

    private func requestVideoAccess(startRunningAfterGrant: Bool) {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                self?.isAuthorized = granted
                self?.error = granted ? nil : .notAuthorized
                if !granted {
                    self?.isRunning = false
                }
            }

            guard let self else { return }
            if granted {
                if startRunningAfterGrant {
                    self.sessionQueue.async { [weak self] in
                        self?.configureSession(startRunning: true)
                    }
                } else {
                    self.setupSession()
                }
            } else {
                self.stopSession()
            }
        }
    }

    func refreshAuthorizationStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async {
                self.isAuthorized = true
                self.error = nil
            }
            sessionQueue.async { [weak self] in
                self?.configureSession(startRunning: true)
            }
        case .notDetermined:
            break
        case .denied:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.error = .notAuthorized
                self.isRunning = false
            }
            stopSession()
        case .restricted:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.error = .restricted
                self.isRunning = false
            }
            stopSession()
        @unknown default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.isRunning = false
            }
        }
    }

    private func setupSession() {
        sessionQueue.async { [weak self] in
            self?.configureSession(startRunning: false)
        }
    }

    private func configureSession(startRunning: Bool) {
        guard !hasConfiguredSession else {
            if startRunning {
                startCaptureSessionIfNeeded()
            }
            return
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            captureSession.commitConfiguration()
            DispatchQueue.main.async { self.error = .cameraUnavailable }
            return
        }

        do {
            try configureCameraForMetering(camera)
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]

            if captureSession.canAddOutput(videoOutput) {
                captureSession.addOutput(videoOutput)
            }

            currentCamera = camera
            currentPosition = .back
            applyCurrentLensConfiguration(to: camera)
            hasConfiguredSession = true
            captureSession.commitConfiguration()
            DispatchQueue.main.async { self.error = nil }
            if startRunning {
                startCaptureSessionIfNeeded()
            }
        } catch {
            hasConfiguredSession = false
            captureSession.commitConfiguration()
            DispatchQueue.main.async { self.error = .configurationFailed }
        }
    }

    func startSession() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            sessionQueue.async { [weak self] in
                self?.configureSession(startRunning: true)
            }
        case .notDetermined:
            requestVideoAccess(startRunningAfterGrant: true)
        case .denied:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.error = .notAuthorized
                self.isRunning = false
            }
        case .restricted:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.error = .restricted
                self.isRunning = false
            }
        @unknown default:
            DispatchQueue.main.async {
                self.isAuthorized = false
                self.isRunning = false
            }
        }
    }

    private func startCaptureSessionIfNeeded() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        guard !captureSession.isRunning else {
            DispatchQueue.main.async {
                self.isRunning = true
                self.error = nil
            }
            return
        }

        captureSession.startRunning()
        DispatchQueue.main.async {
            self.isRunning = true
            self.error = nil
        }
        if !skipLuminanceCorrection {
            publishIdleReflectiveFeedback()
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
            }
            DispatchQueue.main.async { self.isRunning = false }
        }
    }

    func setMeteringMode(_ mode: MeteringMode) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.meteringMode != mode else { return }
            self.meteringMode = mode
            if mode != .spot {
                self.spotMeteringPoint = self.defaultExposurePointOfInterest
            }
            self.updateExposurePointOfInterest(to: self.activeExposurePointOfInterest())
            self.resetMeteringState(settleFrames: 2)
            self.reflectiveMeasurementCompletion = nil
            self.reflectiveMeasurementState = .idle
            DispatchQueue.main.async { [weak self] in
                self?.isReflectiveMeasurementInProgress = false
            }
            if !self.skipLuminanceCorrection {
                if mode == .threePoint {
                    self.beginThreePointSelection()
                } else {
                    self.clearThreePointState()
                    self.publishIdleReflectiveFeedback()
                }
            }
        }
    }

    func requestReflectiveMeasurement(completion: @escaping (Double) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.skipLuminanceCorrection else { return }
            guard self.meteringMode != .threePoint else {
                let hasCompletedSelection = self.hasCompletedThreePointSelection
                self.publishMeasurementFeedback(
                    stability: hasCompletedSelection ? 1.0 : 0.12,
                    status: hasCompletedSelection ? "測光完了" : self.threePointPromptText()
                )
                guard hasCompletedSelection,
                      let lockedThreePointDisplay = self.lockedThreePointDisplay else {
                    return
                }
                let lockedEV = lockedThreePointDisplay.midtone.ev + lockedThreePointDisplay.exposureBiasEV
                DispatchQueue.main.async {
                    completion(lockedEV)
                }
                return
            }

            self.reflectiveMeasurementCompletion = completion
            self.reflectiveMeasurementState = .measuring
            self.setExposureLock(enabled: false)
            self.updateExposurePointOfInterest(to: self.activeExposurePointOfInterest())
            self.resetMeteringState(settleFrames: self.meteringMode == .spot ? 6 : 4)
            DispatchQueue.main.async { [weak self] in
                self?.isReflectiveMeasurementInProgress = true
            }

            self.clearThreePointState()

            self.publishMeasurementFeedback(stability: 0.12, status: "測光中")
        }
    }

    func setThreePointSelectionPoint(_ point: CGPoint, completion: @escaping (Bool) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.meteringMode == .threePoint, !self.skipLuminanceCorrection else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            _ = point

            if let camera = self.currentCamera {
                let exposureTargetOffset = Double(camera.exposureTargetOffset)
                let isAdjustingScene = camera.isAdjustingExposure || camera.isAdjustingWhiteBalance || camera.isLowLightBoostEnabled
                let requiresAutoExposureStability = camera.exposureMode != .locked
                if isAdjustingScene || (requiresAutoExposureStability && abs(exposureTargetOffset) > 0.28) {
                    self.publishMeasurementFeedback(stability: 0.12, status: "安定してからタップ")
                    DispatchQueue.main.async { completion(false) }
                    return
                }
            }

            let kind = self.threePointPendingKindInternal ?? .highlight
            guard let sample = self.captureCurrentThreePointSample() else {
                self.publishMeasurementFeedback(stability: 0.12, status: self.threePointPromptText())
                DispatchQueue.main.async { completion(false) }
                return
            }

            self.manualThreePointSamples[kind] = sample
            self.reflectiveMeasurementCompletion = nil
            self.reflectiveMeasurementState = .idle

            guard self.hasCompletedThreePointSelection,
                  let highlightSample = self.manualThreePointSamples[.highlight],
                  let shadowSample = self.manualThreePointSamples[.shadow] else {
                self.publishThreePointSelectionState()
                DispatchQueue.main.async {
                    completion(false)
                }
                return
            }

            let result = self.lightMeter.deriveThreePointEVResult(
                highlightEV: highlightSample.ev,
                shadowEV: shadowSample.ev
            )
            let currentDisplay = self.buildThreePointDisplay(from: result)
            self.setExposureLock(enabled: true)
            self.lockedThreePointDisplay = currentDisplay
            self.evHistory.removeAll()
            self.filteredEV = nil
            self.lastPublishedEV = result.meteredEV
            self.publishMeasurementFeedback(stability: 1.0, status: "AEL")

            let markers = self.threePointSelectionOrder.map {
                ThreePointSelectionMarker(kind: $0, point: self.threePointDisplayAnchor(for: $0))
            }

            DispatchQueue.main.async { [weak self] in
                self?.isReflectiveMeasurementInProgress = false
                self?.currentEV = result.meteredEV
                self?.threePointMetering = currentDisplay
                self?.threePointMeteringState = .locked
                self?.threePointSelectionMarkers = markers
                self?.threePointPendingKind = nil
                completion(true)
            }
        }
    }

    func restartThreePointSelection() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.meteringMode == .threePoint, !self.skipLuminanceCorrection else { return }
            self.beginThreePointSelection()
        }
    }

    func setSpotMeteringPoint(x: CGFloat, y: CGFloat) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.spotMeteringPoint = CGPoint(
                x: min(max(x, 0), 1),
                y: min(max(y, 0), 1)
            )
            self.meteringMode = .spot
            self.updateExposurePointOfInterest(to: self.activeExposurePointOfInterest())
            self.resetMeteringState(settleFrames: 4)
            if !self.skipLuminanceCorrection {
                self.reflectiveMeasurementCompletion = nil
                self.reflectiveMeasurementState = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.isReflectiveMeasurementInProgress = false
                }
                self.clearThreePointState()
                self.publishIdleReflectiveFeedback()
            }
        }
    }

    func setLensPreset(_ preset: CameraFilmPreset?, visibleFocalLengthMultiplier: Double = 1) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.visibleFocalLengthMultiplier = max(1, visibleFocalLengthMultiplier)
            self.zoomLensPresetEnabled = preset?.allowsInteractiveZoom ?? false
            self.desiredEquivalentFocalLength = preset?.requestedEquivalentFocalLength(
                visibleFocalLengthMultiplier: visibleFocalLengthMultiplier
            ) ?? self.defaultEquivalentFocalLength
            self.applyCurrentLensConfiguration()
            self.resetMeteringState(settleFrames: 2)
            if !self.skipLuminanceCorrection {
                self.reflectiveMeasurementCompletion = nil
                self.reflectiveMeasurementState = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.isReflectiveMeasurementInProgress = false
                }
                self.clearThreePointState()
                self.publishIdleReflectiveFeedback()
            }
        }
    }

    func setEquivalentFocalLength(_ focalLength35mm: Double) {
        sessionQueue.async { [weak self] in
            guard let self = self, self.zoomLensPresetEnabled else { return }
            self.desiredEquivalentFocalLength = focalLength35mm
            self.applyCurrentLensConfiguration()
            self.resetMeteringState(settleFrames: 2)
            if !self.skipLuminanceCorrection {
                self.reflectiveMeasurementCompletion = nil
                self.reflectiveMeasurementState = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.isReflectiveMeasurementInProgress = false
                }
                self.clearThreePointState()
                self.publishIdleReflectiveFeedback()
            }
        }
    }

    @MainActor
    func sensorPoint(forVisiblePreviewPoint point: CGPoint, mirrored: Bool) -> CGPoint {
        let convertedPoint = previewLayerSensorPoint(forVisiblePreviewPoint: point)

        if let convertedPoint {
            return convertedPoint
        }

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )

        let landscapePoint: CGPoint
        if mirrored {
            landscapePoint = CGPoint(x: clampedPoint.y, y: clampedPoint.x)
        } else {
            landscapePoint = CGPoint(x: clampedPoint.y, y: 1 - clampedPoint.x)
        }

        let frameRect: CGRect
        if let latestPreviewFrameSize {
            frameRect = CGRect(x: 0, y: 0, width: latestPreviewFrameSize.width, height: latestPreviewFrameSize.height)
        } else if let previewImage {
            frameRect = CGRect(x: 0, y: 0, width: previewImage.width, height: previewImage.height)
        } else {
            return landscapePoint
        }

        let visibleRect = normalizedVisiblePreviewRect(for: frameRect)

        return CGPoint(
            x: visibleRect.minX + visibleRect.width * landscapePoint.x,
            y: visibleRect.minY + visibleRect.height * landscapePoint.y
        )
    }

    @MainActor
    func setActivePreviewLayer(_ previewLayer: AVCaptureVideoPreviewLayer?, visibleRect: CGRect? = nil) {
        activePreviewLayer = previewLayer
        activePreviewVisibleRect = visibleRect ?? previewLayer?.bounds ?? .zero
        let measurementRect = previewLayer.flatMap {
            activeSensorRect(for: $0, visibleRect: activePreviewVisibleRect)
        } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        sessionQueue.async { [weak self] in
            self?.activePreviewMeasurementRect = measurementRect
        }
    }

    @MainActor
    private func previewLayerSensorPoint(forVisiblePreviewPoint point: CGPoint) -> CGPoint? {
        guard let activePreviewLayer else { return nil }
        let bounds = activePreviewLayer.bounds
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let targetRect: CGRect = {
            let rect = activePreviewVisibleRect
            guard rect.width > 1, rect.height > 1 else { return bounds }
            let clippedRect = rect.intersection(bounds)
            return clippedRect.isNull ? bounds : clippedRect
        }()

        let clampedPoint = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        let layerPoint = CGPoint(
            x: targetRect.minX + targetRect.width * clampedPoint.x,
            y: targetRect.minY + targetRect.height * clampedPoint.y
        )
        let converted = activePreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
        return CGPoint(
            x: min(max(converted.x, 0), 1),
            y: min(max(converted.y, 0), 1)
        )
    }

    @MainActor
    private func activeSensorRect(
        for previewLayer: AVCaptureVideoPreviewLayer,
        visibleRect: CGRect
    ) -> CGRect {
        let bounds = previewLayer.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let targetRect: CGRect = {
            guard visibleRect.width > 1, visibleRect.height > 1 else { return bounds }
            let clippedRect = visibleRect.intersection(bounds)
            return clippedRect.isNull ? bounds : clippedRect
        }()

        let points = [
            CGPoint(x: targetRect.minX, y: targetRect.minY),
            CGPoint(x: targetRect.maxX, y: targetRect.minY),
            CGPoint(x: targetRect.minX, y: targetRect.maxY),
            CGPoint(x: targetRect.maxX, y: targetRect.maxY)
        ]
        let convertedPoints = points.map {
            previewLayer.captureDevicePointConverted(fromLayerPoint: $0)
        }
        guard let minX = convertedPoints.map(\.x).min(),
              let maxX = convertedPoints.map(\.x).max(),
              let minY = convertedPoints.map(\.y).min(),
              let maxY = convertedPoints.map(\.y).max() else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let rect = CGRect(
            x: min(max(minX, 0), 1),
            y: min(max(minY, 0), 1),
            width: min(max(maxX, 0), 1) - min(max(minX, 0), 1),
            height: min(max(maxY, 0), 1) - min(max(minY, 0), 1)
        )

        guard rect.width > 0.001, rect.height > 0.001 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return rect
    }

    func lockExposure() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.setExposureLock(enabled: true)
            if !self.skipLuminanceCorrection {
                self.reflectiveMeasurementCompletion = nil
                self.reflectiveMeasurementState = .idle
                DispatchQueue.main.async { [weak self] in
                    self?.isReflectiveMeasurementInProgress = false
                }
                self.publishMeasurementFeedback(stability: 1.0, status: "AEL")
            }
        }
    }

    func unlockExposure() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.setExposureLock(enabled: false)
            self.updateExposurePointOfInterest(to: self.activeExposurePointOfInterest())
            self.reflectiveMeasurementCompletion = nil
            self.reflectiveMeasurementState = .idle
            self.resetMeteringState(settleFrames: 2)
            DispatchQueue.main.async { [weak self] in
                self?.isReflectiveMeasurementInProgress = false
            }
            if !self.skipLuminanceCorrection {
                self.publishIdleReflectiveFeedback()
            }
        }
    }

    // MARK: - 入射光モード — フロント/バックカメラ切替、輝度補正スキップ

    func setIncidentMode(_ enabled: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.previewImage = nil
            self?.isCameraSwitching = true
            self?.isIncidentMode = enabled
            if enabled {
                self?.threePointMetering = nil
                self?.threePointMeteringState = .inactive
            }
        }
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.latestPreviewPixelBuffer = nil
            self.latestPreviewFrameSize = nil
            self.skipLuminanceCorrection = enabled
            self.reflectiveMeasurementCompletion = nil
            self.reflectiveMeasurementState = .idle
            DispatchQueue.main.async { [weak self] in
                self?.isReflectiveMeasurementInProgress = false
            }
            self.switchCameraInternal(to: enabled ? .front : .back)
            self.resetMeteringState(settleFrames: 4)
            if enabled {
                self.clearThreePointState()
            } else {
                self.publishIdleReflectiveFeedback()
            }
            DispatchQueue.main.async { [weak self] in
                self?.isCameraSwitching = false
            }
        }
        loadCalibrationOffset(forIncident: enabled)
    }

    private func setExposureLock(enabled: Bool) {
        guard let camera = currentCamera else { return }
        do {
            try camera.lockForConfiguration()
            if enabled {
                if camera.isExposureModeSupported(.locked) {
                    camera.exposureMode = .locked
                }
            } else if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.unlockForConfiguration()
        } catch {}
    }

    func captureCurrentPreviewImage(completion: @escaping (CGImage?) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            guard let pixelBuffer = self.latestPreviewPixelBuffer else {
                DispatchQueue.main.async { completion(self.previewImage) }
                return
            }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let cgImage = self.context.createCGImage(ciImage, from: ciImage.extent)

            DispatchQueue.main.async {
                self.previewImage = cgImage
                completion(cgImage)
            }
        }
    }

    private func switchCameraInternal(to position: AVCaptureDevice.Position) {
        captureSession.beginConfiguration()
        for input in captureSession.inputs {
            captureSession.removeInput(input)
        }

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            captureSession.commitConfiguration()
            return
        }

        do {
            try configureCameraForMetering(camera)
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
        } catch {}

        captureSession.commitConfiguration()
        currentCamera = camera
        currentPosition = position
        updateExposurePointOfInterest(to: activeExposurePointOfInterest())
        applyCurrentLensConfiguration(to: camera)
    }

    private func activeExposurePointOfInterest() -> CGPoint {
        meteringMode == .spot ? spotMeteringPoint : defaultExposurePointOfInterest
    }

    private func activeExposureRectOfInterest(
        for point: CGPoint,
        camera: AVCaptureDevice
    ) -> CGRect? {
        guard camera.isExposureRectOfInterestSupported else { return nil }

        switch meteringMode {
        case .spot:
            return exposureRectOfInterest(
                centeredAt: point,
                preferredSize: spotExposureRectSize,
                camera: camera
            )
        case .threePoint where !skipLuminanceCorrection:
            return exposureRectOfInterest(
                centeredAt: defaultExposurePointOfInterest,
                preferredSize: threePointExposureRectSize,
                camera: camera
            )
        default:
            let defaultRect = camera.defaultRectForExposurePoint(ofInterest: point)
            return defaultRect.isNull ? nil : defaultRect
        }
    }

    private func exposureRectOfInterest(
        centeredAt point: CGPoint,
        preferredSize: CGSize,
        camera: AVCaptureDevice
    ) -> CGRect {
        let minimumSize = camera.minExposureRectOfInterestSize
        let width = min(max(preferredSize.width, minimumSize.width), 1.0)
        let height = min(max(preferredSize.height, minimumSize.height), 1.0)
        let originX = min(max(point.x - width * 0.5, 0), 1.0 - width)
        let originY = min(max(point.y - height * 0.5, 0), 1.0 - height)

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    private func updateExposurePointOfInterest(to point: CGPoint) {
        guard let camera = currentCamera else { return }
        do {
            try camera.lockForConfiguration()
            if camera.isExposurePointOfInterestSupported {
                camera.exposurePointOfInterest = point
            }
            if let exposureRect = activeExposureRectOfInterest(for: point, camera: camera) {
                camera.exposureRectOfInterest = exposureRect
            }
            if camera.isExposureModeSupported(.continuousAutoExposure), camera.exposureMode != .locked {
                camera.exposureMode = .continuousAutoExposure
            }
            camera.unlockForConfiguration()
        } catch {}
    }

    private func configureCameraForMetering(_ camera: AVCaptureDevice) throws {
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }

        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
        }

        // AWBをロックしてEVドリフトを防止
        // 露出計ではWBの自動調整は不要であり、輝度測定の安定性を損なう
        if camera.isWhiteBalanceModeSupported(.locked) {
            // まずD50（昼光）相当のゲインに固定してからロック
            let d50Gains = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                temperature: 5000, tint: 0
            )
            let deviceGains = camera.deviceWhiteBalanceGains(for: d50Gains)
            let clampedGains = clampWhiteBalanceGains(deviceGains, for: camera)
            camera.setWhiteBalanceModeLocked(with: clampedGains, completionHandler: nil)
        }

        if camera.isLowLightBoostSupported {
            camera.automaticallyEnablesLowLightBoostWhenAvailable = false
        }

        camera.automaticallyAdjustsVideoHDREnabled = false
        if camera.activeFormat.isVideoHDRSupported {
            camera.isVideoHDREnabled = false
        }

        if #available(iOS 15.4, *) {
            camera.automaticallyAdjustsFaceDrivenAutoExposureEnabled = false
            camera.isFaceDrivenAutoExposureEnabled = false
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func clampWhiteBalanceGains(
        _ gains: AVCaptureDevice.WhiteBalanceGains,
        for camera: AVCaptureDevice
    ) -> AVCaptureDevice.WhiteBalanceGains {
        let maxGain = camera.maxWhiteBalanceGain
        return AVCaptureDevice.WhiteBalanceGains(
            redGain: min(max(gains.redGain, 1.0), maxGain),
            greenGain: min(max(gains.greenGain, 1.0), maxGain),
            blueGain: min(max(gains.blueGain, 1.0), maxGain)
        )
    }

    private func resetMeteringState(settleFrames: Int) {
        evHistory.removeAll()
        filteredEV = nil
        lastPublishedEV = nil
        settlingFramesRemaining = max(settleFrames, 0)
        publishMeasurementFeedback(stability: 0.12, status: "安定化中")
    }

    private func publishIdleReflectiveFeedback() {
        publishMeasurementFeedback(stability: 0.12, status: "再測光待機")
    }

    private var threePointSelectionOrder: [ThreePointSampleKind] {
        [.highlight, .shadow]
    }

    private var threePointPendingKindInternal: ThreePointSampleKind? {
        threePointSelectionOrder.first { manualThreePointSamples[$0] == nil }
    }

    private var hasCompletedThreePointSelection: Bool {
        threePointSelectionOrder.allSatisfy { manualThreePointSamples[$0] != nil }
    }

    private func threePointPromptText() -> String {
        switch threePointPendingKindInternal {
        case .highlight:
            return "最明部を中央に合わせてタップ"
        case .shadow:
            return "最暗部を中央に合わせてタップ"
        case .midtone:
            return "中間調を自動計算"
        case nil:
            return "2点の測光値を保持中"
        }
    }

    private func publishThreePointSelectionState() {
        let markers = threePointSelectionOrder.compactMap { kind -> ThreePointSelectionMarker? in
            guard manualThreePointSamples[kind] != nil else { return nil }
            return ThreePointSelectionMarker(kind: kind, point: threePointDisplayAnchor(for: kind))
        }
        let pendingKind = threePointPendingKindInternal
        let completed = hasCompletedThreePointSelection
        let status = completed ? "測光完了" : threePointPromptText()

        DispatchQueue.main.async { [weak self] in
            self?.threePointSelectionMarkers = markers
            self?.threePointPendingKind = pendingKind
            self?.threePointMeteringState = completed ? .locked : .analyzing
            if !completed {
                self?.threePointMetering = nil
            }
        }
        publishMeasurementFeedback(stability: completed ? 0.36 : 0.12, status: status)
    }

    private func beginThreePointSelection() {
        setExposureLock(enabled: false)
        updateExposurePointOfInterest(to: activeExposurePointOfInterest())
        manualThreePointSamples.removeAll()
        lockedThreePointDisplay = nil
        reflectiveMeasurementCompletion = nil
        reflectiveMeasurementState = .idle
        evHistory.removeAll()
        filteredEV = nil
        lastPublishedEV = nil
        DispatchQueue.main.async { [weak self] in
            self?.isReflectiveMeasurementInProgress = false
            self?.threePointMetering = nil
        }
        publishThreePointSelectionState()
    }

    private func clearThreePointState() {
        manualThreePointSamples.removeAll()
        lockedThreePointDisplay = nil
        DispatchQueue.main.async { [weak self] in
            self?.threePointMetering = nil
            self?.threePointMeteringState = .inactive
            self?.threePointSelectionMarkers = []
            self?.threePointPendingKind = nil
        }
    }

    private func publishSpotWarning(_ warning: SpotMeteringWarning) {
        DispatchQueue.main.async { [weak self] in
            self?.spotMeteringWarning = warning
        }
    }

    private func evaluateSpotWarning(from context: SpotMeteringWarningContext) -> SpotMeteringWarning {
        let sceneSpreadEV = context.brightestLogLuminance - context.darkestLogLuminance
        guard sceneSpreadEV > 1.5 else { return .none }

        let spotLog = context.spotLogLuminance
        if spotBrightAreaWarningEnabled &&
            spotMeteringReferenceTarget != .brightest &&
            spotLog >= context.brightestLogLuminance - 0.08 &&
            spotLog - context.midtoneLogLuminance > 1.55 {
            return .brightArea
        }

        let targetLog: Double
        switch spotMeteringReferenceTarget {
        case .darkest:
            targetLog = context.darkestLogLuminance
        case .shadow:
            targetLog = context.shadowLogLuminance
        case .sunlit:
            targetLog = context.sunlitLogLuminance
        case .brightest:
            targetLog = context.brightestLogLuminance
        }

        let adaptiveTolerance = max(
            spotMeteringReferenceTarget.warningToleranceEV,
            min(3.3, sceneSpreadEV * 0.8)
        )

        if abs(spotLog - targetLog) > adaptiveTolerance {
            return .offTarget
        }
        return .none
    }

    private func shouldFinalizeReflectiveMeasurement(
        historyCount: Int,
        stability: Double,
        isAdjustingScene: Bool,
        settling: Bool
    ) -> Bool {
        guard reflectiveMeasurementState == .measuring else { return false }
        guard !settling, !isAdjustingScene else { return false }
        guard historyCount >= reflectiveMeasurementMinimumSamples else { return false }
        return stability >= 0.76
    }

    private func completeReflectiveMeasurement(with ev: Double) {
        let completion = reflectiveMeasurementCompletion
        reflectiveMeasurementCompletion = nil
        reflectiveMeasurementState = .idle
        let shouldAutoLock = meteringMode == .threePoint
        setExposureLock(enabled: shouldAutoLock)
        publishMeasurementFeedback(stability: 1.0, status: shouldAutoLock ? "AEL" : "測光完了")
        DispatchQueue.main.async { [weak self] in
            self?.isReflectiveMeasurementInProgress = false
            self?.currentEV = ev
            completion?(ev)
        }
    }

    private func historySize(for mode: MeteringMode) -> Int {
        switch mode {
        case .spot:
            return 3
        case .centerWeighted:
            return 6
        case .matrix:
            return 8
        case .average:
            return 8
        case .threePoint:
            return 6
        }
    }

    private func smoothingFactor(for mode: MeteringMode, delta: Double, isTransitioning: Bool) -> Double {
        let base: Double
        switch mode {
        case .spot:
            base = 0.58
        case .centerWeighted:
            base = 0.32
        case .matrix:
            base = 0.28
        case .average:
            base = 0.26
        case .threePoint:
            base = 0.30
        }

        var alpha = base
        if delta > 1.0 {
            alpha = min(0.75, base + 0.30)
        } else if delta > 0.5 {
            alpha = min(0.60, base + 0.20)
        } else if delta > 0.25 {
            alpha = min(0.50, base + 0.12)
        }

        // AE遷移中はさらに追従を速める
        if isTransitioning {
            alpha = min(0.85, alpha + 0.15)
        }

        return alpha
    }

    private func applyCurrentLensConfiguration() {
        applyCurrentLensConfiguration(to: currentCamera)
    }

    private func applyCurrentLensConfiguration(to camera: AVCaptureDevice?) {
        let desired = max(1, desiredEquivalentFocalLength)

        guard let camera else {
            publishLensState(focalLength: desired)
            return
        }

        let appliedFocalLength: Double

        if camera.position == .back {
            let baseEquivalentFocalLength = referenceEquivalentFocalLength(for: camera)
            let minimumEquivalentFocalLength = baseEquivalentFocalLength
            let maximumEquivalentFocalLength = max(
                minimumEquivalentFocalLength,
                baseEquivalentFocalLength * max(Double(camera.maxAvailableVideoZoomFactor), 1.0)
            )
            let clampedEquivalentFocalLength = min(max(desired, minimumEquivalentFocalLength), maximumEquivalentFocalLength)
            let requestedZoomFactor = clampedEquivalentFocalLength / baseEquivalentFocalLength
            let minimumZoomFactor = max(Double(camera.minAvailableVideoZoomFactor), 1.0)
            let maximumZoomFactor = max(minimumZoomFactor, Double(camera.maxAvailableVideoZoomFactor))
            let zoomFactor = min(max(requestedZoomFactor, minimumZoomFactor), maximumZoomFactor)

            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = CGFloat(zoomFactor)
                camera.unlockForConfiguration()
            } catch {}

            appliedFocalLength = baseEquivalentFocalLength * zoomFactor
        } else {
            do {
                try camera.lockForConfiguration()
                camera.videoZoomFactor = 1
                camera.unlockForConfiguration()
            } catch {}

            appliedFocalLength = desired
        }

        desiredEquivalentFocalLength = appliedFocalLength
        publishLensState(focalLength: appliedFocalLength)
    }

    private func publishLensState(focalLength: Double) {
        let preciseFocalLength = max(1, focalLength)
        let visibleFocalLength = max(1, (preciseFocalLength * visibleFocalLengthMultiplier).rounded())
        let display = "\(Int(visibleFocalLength))mm"
        let zoomAllowed = zoomLensPresetEnabled && currentPosition == .back && !isIncidentMode

        DispatchQueue.main.async { [weak self] in
            self?.currentEquivalentFocalLength = preciseFocalLength
            self?.currentLensDisplay = display
            self?.isZoomLensPreset = self?.zoomLensPresetEnabled ?? false
            self?.allowsFullscreenZoom = zoomAllowed
        }
    }

    private func publishMeasurementFeedback(stability: Double, status: String) {
        let clampedStability = min(max(stability, 0), 1)
        let stabilityChanged = lastPublishedMeasurementStability.map {
            abs(clampedStability - $0) > 0.02
        } ?? true
        let statusChanged = lastPublishedMeasurementStateText != status
        guard stabilityChanged || statusChanged else { return }

        lastPublishedMeasurementStability = clampedStability
        lastPublishedMeasurementStateText = status

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if abs(self.measurementStability - clampedStability) > 0.001 {
                self.measurementStability = clampedStability
            }
            if self.measurementStateText != status {
                self.measurementStateText = status
            }
        }
    }

    private func reflectiveEV(
        from measurements: MeteringLuminanceMeasurements,
        mode: MeteringMode,
        baseEV: Double,
        calibrationOffset: Double,
        useLuminanceCorrection: Bool,
        applySpotExposureBoost: Bool
    ) -> Double? {
        let regionalAdjustmentEV: Double
        if useLuminanceCorrection {
            let referenceLuminance = max(measurements.reference, 1.0e-4)
            let selectedLuminance = max(measurements.luminance(for: mode), 1.0e-4)
            let ratio = selectedLuminance / referenceLuminance
            regionalAdjustmentEV = ratio > 0 ? min(max(log2(ratio), -4), 4) : 0
        } else {
            regionalAdjustmentEV = 0
        }

        let spotExposureBoostEV = applySpotExposureBoost && mode == .spot
            ? spotExposureBoostPreset.boostEV
            : 0
        let ev = baseEV + regionalAdjustmentEV + calibrationOffset - spotExposureBoostEV
        return ev.isFinite ? ev : nil
    }

    private func threePointMeasurementVisibleRect(for imageExtent: CGRect) -> CGRect {
        let baseVisibleRect = normalizedVisiblePreviewRect(for: imageExtent)
        return spotAssistVisibleRect(
            around: defaultExposurePointOfInterest,
            within: baseVisibleRect
        )
    }

    private func captureCurrentThreePointSample() -> ThreePointCapturedSample? {
        guard let camera = currentCamera,
              let pixelBuffer = latestPreviewPixelBuffer else {
            return nil
        }

        let iso = Double(camera.iso)
        let shutterSpeed = CMTimeGetSeconds(camera.exposureDuration)
        guard shutterSpeed > 0, iso > 0 else { return nil }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let visibleRect: CGRect
        if currentPosition == .back {
            visibleRect = activeMeasurementVisibleRect(for: ciImage.extent)
        } else {
            visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let measurements = lightMeter.measureLuminances(
            from: ciImage,
            requiredMode: .spot,
            spotPoint: defaultExposurePointOfInterest,
            visibleRect: visibleRect,
            includeSpotWarningContext: false
        )
        let targetBias = Double(camera.exposureTargetBias)
        let exposureTargetOffset = Double(camera.exposureTargetOffset)
        let deviceAperture = Double(camera.lensAperture)
        let deviceEV = log2(pow(deviceAperture, 2) / shutterSpeed) - log2(iso / 100.0)
        let baseEV = deviceEV + exposureTargetOffset - targetBias
        guard let sampleEV = reflectiveEV(
            from: measurements,
            mode: .spot,
            baseEV: baseEV,
            calibrationOffset: reflectedMeterCalibrationOffset,
            useLuminanceCorrection: true,
            applySpotExposureBoost: false
        ) else {
            return nil
        }
        let spotLuminance = max(measurements.spot, 1.0e-4)
        guard sampleEV.isFinite else { return nil }
        return ThreePointCapturedSample(ev: sampleEV, spotLuminance: spotLuminance)
    }

    private func threePointDisplayAnchor(for kind: ThreePointSampleKind) -> CGPoint {
        switch kind {
        case .highlight:
            return CGPoint(x: 0.5, y: 0.34)
        case .midtone:
            return CGPoint(x: 0.5, y: 0.5)
        case .shadow:
            return CGPoint(x: 0.5, y: 0.66)
        }
    }

    private func measurementStability(for values: [Double], isAdjustingScene: Bool, settling: Bool) -> Double {
        guard let minimum = values.min(), let maximum = values.max() else {
            return settling ? 0.12 : 0.3
        }

        let range = maximum - minimum
        var stability = 1.0 - min(1.0, max(0, range - 0.04) / 0.45)

        if settling {
            stability *= 0.45
        }

        if isAdjustingScene {
            stability *= 0.7
        }

        return max(0.08, stability)
    }

    private func measurementStateText(for stability: Double, isAdjustingScene: Bool, settling: Bool) -> String {
        if settling {
            return "安定化中"
        }
        if isAdjustingScene {
            return "測定中"
        }
        return stability >= 0.82 ? "安定" : "測定中"
    }

    private func normalizedVisiblePreviewRect(for imageExtent: CGRect) -> CGRect {
        guard imageExtent.width > 0, imageExtent.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let sourceAspectRatio = imageExtent.width / imageExtent.height
        let targetAspectRatio = previewLandscapeAspectRatio

        if abs(sourceAspectRatio - targetAspectRatio) < 0.0001 {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        if sourceAspectRatio > targetAspectRatio {
            let visibleWidth = targetAspectRatio / sourceAspectRatio
            return CGRect(x: (1 - visibleWidth) * 0.5, y: 0, width: visibleWidth, height: 1)
        }

        let visibleHeight = sourceAspectRatio / targetAspectRatio
        return CGRect(x: 0, y: (1 - visibleHeight) * 0.5, width: 1, height: visibleHeight)
    }

    private func activeMeasurementVisibleRect(for imageExtent: CGRect) -> CGRect {
        let fallbackVisibleRect = normalizedVisiblePreviewRect(for: imageExtent)
        let baseVisibleRect = normalizedUnitRect(activePreviewMeasurementRect, fallback: fallbackVisibleRect)
        guard meteringMode == .spot, !skipLuminanceCorrection else {
            return baseVisibleRect
        }
        return spotAssistVisibleRect(
            around: spotMeteringPoint,
            within: baseVisibleRect
        )
    }

    private func normalizedUnitRect(_ rect: CGRect, fallback: CGRect) -> CGRect {
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, 0), 1)
        let maxY = min(max(rect.maxY, 0), 1)
        let normalized = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard normalized.width > 0.001, normalized.height > 0.001 else {
            return fallback
        }
        return normalized
    }

    private func spotAssistVisibleRect(around point: CGPoint, within baseRect: CGRect) -> CGRect {
        let clampedPoint = CGPoint(
            x: min(max(point.x, baseRect.minX), baseRect.maxX),
            y: min(max(point.y, baseRect.minY), baseRect.maxY)
        )
        let targetWidth = max(0.18, baseRect.width * spotAEAssistZoomRatio)
        let targetHeight = max(0.18, baseRect.height * spotAEAssistZoomRatio)

        let minX = min(
            max(clampedPoint.x - targetWidth * 0.5, baseRect.minX),
            max(baseRect.maxX - targetWidth, baseRect.minX)
        )
        let minY = min(
            max(clampedPoint.y - targetHeight * 0.5, baseRect.minY),
            max(baseRect.maxY - targetHeight, baseRect.minY)
        )

        return CGRect(
            x: minX,
            y: minY,
            width: min(targetWidth, baseRect.width),
            height: min(targetHeight, baseRect.height)
        )
    }

    private func referenceEquivalentFocalLength(for camera: AVCaptureDevice) -> Double {
        LensFocalLengthGuide.referenceEquivalentFocalLength(for: camera)
    }
}

extension LightMeterCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        latestPreviewPixelBuffer = pixelBuffer
        latestPreviewFrameSize = CGSize(
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )

        frameCounter += 1
        let phase = frameCounter % 4

        guard phase == 2 else { return }

        autoreleasepool {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

            guard let camera = currentCamera else { return }

            if !skipLuminanceCorrection && meteringMode == .threePoint && reflectiveMeasurementState != .measuring {
                return
            }

            let iso = Double(camera.iso)
            let shutterSpeed = CMTimeGetSeconds(camera.exposureDuration)
            let targetBias = Double(camera.exposureTargetBias)
            let exposureTargetOffset = Double(camera.exposureTargetOffset)
            let isAdjustingScene = camera.isAdjustingExposure || camera.isAdjustingWhiteBalance || camera.isLowLightBoostEnabled

            guard shutterSpeed > 0, iso > 0 else { return }

            if settlingFramesRemaining > 0 {
                if isAdjustingScene || abs(exposureTargetOffset) > 0.12 {
                    settlingFramesRemaining -= 1
                    publishMeasurementFeedback(stability: 0.12, status: "安定化中")
                    return
                }
                settlingFramesRemaining -= 1
            }

            let isTransitioning = isAdjustingScene || abs(exposureTargetOffset) > 0.28

            let visibleRect: CGRect
            if currentPosition == .back && !skipLuminanceCorrection {
                visibleRect = activeMeasurementVisibleRect(for: ciImage.extent)
            } else {
                visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            }

            let measurements = lightMeter.measureLuminances(
                from: ciImage,
                requiredMode: meteringMode,
                spotPoint: spotMeteringPoint,
                visibleRect: visibleRect,
                includeSpotWarningContext: !skipLuminanceCorrection && meteringMode == .spot
            )
            let currentSpotWarning = !skipLuminanceCorrection && meteringMode == .spot
                ? evaluateSpotWarning(from: measurements.spotWarningContext)
                : .none
            publishSpotWarning(currentSpotWarning)

            let deviceAperture = Double(camera.lensAperture)
            let deviceEV = log2(pow(deviceAperture, 2) / shutterSpeed) - log2(iso / 100.0)
            let baseEV = deviceEV + exposureTargetOffset - targetBias
            let calibrationOffset = skipLuminanceCorrection
                ? incidentMeterCalibrationOffset
                : reflectedMeterCalibrationOffset

            let calculatedEV: Double
            if skipLuminanceCorrection || meteringMode != .threePoint {
                guard let liveCalculatedEV = reflectiveEV(
                    from: measurements,
                    mode: meteringMode,
                    baseEV: baseEV,
                    calibrationOffset: calibrationOffset,
                    useLuminanceCorrection: !skipLuminanceCorrection,
                    applySpotExposureBoost: true
                ) else { return }
                if lockedThreePointDisplay != nil || !manualThreePointSamples.isEmpty {
                    clearThreePointState()
                }
                calculatedEV = liveCalculatedEV
            } else {
                guard let lockedThreePointDisplay else {
                    publishMeasurementFeedback(stability: 0.12, status: threePointPromptText())
                    return
                }
                calculatedEV = lockedThreePointDisplay.midtone.ev + lockedThreePointDisplay.exposureBiasEV
            }

            // シーン変化検出: 新しいEVが履歴平均と大きくずれた場合、履歴をリセット
            if let currentFiltered = filteredEV, abs(calculatedEV - currentFiltered) > 1.5 {
                evHistory.removeAll()
                filteredEV = nil
                lastPublishedEV = nil
            }

            evHistory.append(calculatedEV)
            let historyLimit = historySize(for: meteringMode)
            if evHistory.count > historyLimit {
                evHistory.removeFirst()
            }

            let sortedHistory = evHistory.sorted()
            let trimmedHistory: [Double]
            if sortedHistory.count >= 4 {
                let trimCount = max(1, sortedHistory.count / 10)
                trimmedHistory = Array(sortedHistory.dropFirst(trimCount).dropLast(trimCount))
            } else {
                trimmedHistory = sortedHistory
            }
            let historyAverage = trimmedHistory.isEmpty ? calculatedEV : trimmedHistory.reduce(0, +) / Double(trimmedHistory.count)
            let delta = abs(historyAverage - (filteredEV ?? historyAverage))
            let alpha = smoothingFactor(for: meteringMode, delta: delta, isTransitioning: isTransitioning)
            let smoothedEV = filteredEV.map { $0 + (historyAverage - $0) * alpha } ?? historyAverage
            filteredEV = smoothedEV

            let settling = settlingFramesRemaining > 0
            let stability = measurementStability(
                for: trimmedHistory.isEmpty ? [calculatedEV] : trimmedHistory,
                isAdjustingScene: isAdjustingScene,
                settling: settling
            )
            let stateText = measurementStateText(
                for: stability,
                isAdjustingScene: isAdjustingScene,
                settling: settling
            )
            if skipLuminanceCorrection {
                publishMeasurementFeedback(stability: stability, status: stateText)
            } else if meteringMode == .threePoint {
                if reflectiveMeasurementState == .measuring {
                    publishMeasurementFeedback(stability: stability, status: "測光中")
                }
            } else {
                publishMeasurementFeedback(stability: stability, status: stateText)
            }

            // EV値が十分変化した場合のみUI更新（不要な再描画を抑制）
            if lastPublishedEV == nil || abs(smoothedEV - (lastPublishedEV ?? smoothedEV)) > 0.03 {
                lastPublishedEV = smoothedEV
                if skipLuminanceCorrection || meteringMode != .threePoint {
                    DispatchQueue.main.async { [weak self] in
                        self?.currentEV = smoothedEV
                    }
                }
            }

            if shouldFinalizeReflectiveMeasurement(
                historyCount: evHistory.count,
                stability: stability,
                isAdjustingScene: isAdjustingScene,
                settling: settling
            ) {
                completeReflectiveMeasurement(with: smoothedEV)
            }
        }
    }

    private func buildThreePointDisplay(
        from result: ThreePointDerivedEVResult
    ) -> ThreePointMeteringDisplay {
        return ThreePointMeteringDisplay(
            highlight: ThreePointMeteringSampleDisplay(
                kind: .highlight,
                point: threePointDisplayAnchor(for: .highlight),
                ev: result.highlightEV
            ),
            midtone: ThreePointMeteringSampleDisplay(
                kind: .midtone,
                point: threePointDisplayAnchor(for: .midtone),
                ev: result.midtoneEV
            ),
            shadow: ThreePointMeteringSampleDisplay(
                kind: .shadow,
                point: threePointDisplayAnchor(for: .shadow),
                ev: result.shadowEV
            ),
            dynamicRangeEV: result.dynamicRangeEV,
            exposureBiasEV: result.exposureBiasEV
        )
    }
}

enum CameraError: Error, LocalizedError {
    case notAuthorized
    case restricted
    case cameraUnavailable
    case configurationFailed

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "カメラへのアクセスが許可されていません"
        case .restricted: return "カメラの使用が制限されています"
        case .cameraUnavailable: return "カメラが利用できません"
        case .configurationFailed: return "カメラの設定に失敗しました"
        }
    }

    var promptTitle: String {
        switch self {
        case .notAuthorized:
            return "カメラへのアクセスが必要です"
        case .restricted:
            return "カメラの使用が制限されています"
        case .cameraUnavailable:
            return "カメラを利用できません"
        case .configurationFailed:
            return "カメラを起動できません"
        }
    }

    var promptMessage: String {
        switch self {
        case .notAuthorized:
            return "Solis film meter はカメラを光センサーとして使って露出を計測します。現在はカメラへのアクセスがオフのため、測光できません。"
        case .restricted:
            return "このiPhoneではカメラの使用が制限されています。スクリーンタイムや構成プロファイルの設定を確認してください。"
        case .cameraUnavailable:
            return "このiPhoneではカメラを利用できないため、現在は測光できません。"
        case .configurationFailed:
            return "カメラの初期化に失敗したため、現在は測光できません。アプリを再度開いても改善しない場合は、端末を再起動してお試しください。"
        }
    }

    var supportingMessage: String? {
        switch self {
        case .notAuthorized, .restricted, .cameraUnavailable, .configurationFailed:
            return nil
        }
    }

    var showsOpenSettingsButton: Bool {
        switch self {
        case .notAuthorized:
            return true
        case .restricted, .cameraUnavailable, .configurationFailed:
            return false
        }
    }

    var symbolName: String {
        switch self {
        case .notAuthorized, .restricted:
            return "camera.fill"
        case .cameraUnavailable, .configurationFailed:
            return "exclamationmark.triangle.fill"
        }
    }
}
