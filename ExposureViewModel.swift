//
//  ExposureViewModel.swift
//  Solis film meter
//

// MARK: - 役割: 露出計の表示状態と計算結果を管理するViewModel
// MARK: - 目次
// 1. 露出設定、測光状態、推奨値
// 2. 表示/補助/スポット/明暗2点測光設定
// 3. 設定保存・読み込みとUserDefaults同期
// 4. アクセスポリシー適用と利用可能値の正規化
// 5. EV更新、推奨値計算、相反則不軌補正
// 6. Av/Tv/M・ISO・露出補正・AEL操作
// 7. ピンホールモードと撮影記録保存補助

import SwiftUI
import Combine

@MainActor
class ExposureViewModel: ObservableObject {

    @Published var aperture: Aperture = .f4_0
    @Published var shutterSpeed: ShutterSpeed = .s125
    @Published var iso: ISOValue = .iso400
    @Published var exposureCompensation: Double = 0

    @Published var exposureMode: ExposureMode = .aperturePriority
    @Published var meteringMode: MeteringMode = .spot

    @Published var measuredEV: Double = 0
    @Published var evDifference: Double = 0
    @Published var exposureStatus: ExposureStatus = .proper

    @Published var recommendedAperture: Aperture?
    @Published var recommendedShutterSpeed: ShutterSpeed?
    @Published var recommendedShutterDuration: Double?
    @Published var isWithinRange: Bool = true
    @Published var reciprocityCorrectedTime: Double?

    @Published var isLocked: Bool = false
    @Published var showEVValue: Bool = true
    @Published var showAuxiliaryLabels: Bool = true
    @Published var enableHaptics: Bool = true {
        didSet {
            HapticManager.isEnabled = enableHaptics
        }
    }
    @Published var spotBrightAreaWarningEnabled: Bool = true
    @Published var spotOffTargetWarningEnabled: Bool = true
    @Published var spotMeteringReferenceTarget: SpotMeteringReferenceTarget = .shadow
    @Published var spotExposureBoostPreset: SpotMeteringExposureBoostPreset = .neutral
    @Published var hasSeenDisplayModeGuide: Bool = false

    @Published var isIncidentMode: Bool = false
    @Published var isPinholeMode: Bool = false

    private let lightMeter = LightMeterEngine()
    private var cancellables = Set<AnyCancellable>()

    init() {
        loadSettings()
        setupBindings()
    }

    private func setupBindings() {
        $aperture.combineLatest($shutterSpeed, $iso, $exposureCompensation)
            .sink { [weak self] _ in self?.calculateExposure() }
            .store(in: &cancellables)

        $exposureMode
            .sink { [weak self] newMode in
                guard let self else { return }
                if self.isPinholeMode && newMode != .aperturePriority {
                    self.exposureMode = .aperturePriority
                    return
                }
                self.calculateExposure()
            }
            .store(in: &cancellables)

        $measuredEV
            .sink { [weak self] _ in self?.calculateExposure() }
            .store(in: &cancellables)
    }

    private func loadSettings() {
        let settings = UserDefaults.standard.savedSettings ?? .defaultSettings
        iso = settings.isPinholeMode ? .iso6 : .iso400
        showEVValue = settings.showEVValue
        showAuxiliaryLabels = settings.showAuxiliaryLabels
        enableHaptics = settings.enableHaptics
        HapticManager.isEnabled = enableHaptics
        spotBrightAreaWarningEnabled = settings.spotBrightAreaWarningEnabled
        spotOffTargetWarningEnabled = settings.spotOffTargetWarningEnabled
        spotMeteringReferenceTarget = settings.spotMeteringReferenceTarget
        spotExposureBoostPreset = settings.spotExposureBoostPreset
        hasSeenDisplayModeGuide = settings.hasSeenDisplayModeGuide
        setPinholeMode(settings.isPinholeMode, emitHaptics: false)
        normalizeShootingValuesForCurrentMode()
    }

    func saveSettings() {
        let settings = SavedSettings(
            defaultISO: iso.rawValue,
            showEVValue: showEVValue,
            showAuxiliaryLabels: showAuxiliaryLabels,
            enableHaptics: enableHaptics,
            enablePinholeMode: false,
            isPinholeMode: isPinholeMode,
            spotBrightAreaWarningEnabled: spotBrightAreaWarningEnabled,
            spotOffTargetWarningEnabled: spotOffTargetWarningEnabled,
            spotMeteringReferenceTarget: spotMeteringReferenceTarget,
            spotExposureBoostPreset: spotExposureBoostPreset,
            hasSeenDisplayModeGuide: hasSeenDisplayModeGuide
        )
        UserDefaults.standard.savedSettings = settings
    }

    func markDisplayModeGuideSeenIfNeeded() {
        guard !hasSeenDisplayModeGuide else { return }
        hasSeenDisplayModeGuide = true
        saveSettings()
    }

    func applyAccessPolicy(_ policy: AppAccessPolicy) {
        let shouldShowAuxiliaryLabels = policy.shouldShowAuxiliaryLabels
        if showAuxiliaryLabels != shouldShowAuxiliaryLabels {
            showAuxiliaryLabels = shouldShowAuxiliaryLabels
        }

        if !policy.isFullVersion {
            if isIncidentMode {
                isIncidentMode = false
            }
            if isLocked {
                isLocked = false
            }
            if isPinholeMode {
                setPinholeMode(false, emitHaptics: false)
            }
        }

        normalizeMeteringMode(for: policy)
    }

    func updateMeasuredEV(_ ev: Double, force: Bool = false) {
        guard force || !isLocked else { return }
        updateDoubleIfChanged(\.measuredEV, to: ev, tolerance: force ? 0 : 0.0001)
    }

    private func calculateExposure() {
        switch exposureMode {
        case .aperturePriority:
            let result = lightMeter.calculateShutterSpeed(
                forEV: measuredEV,
                aperture: aperture,
                iso: iso,
                compensation: exposureCompensation,
                availableShutterSpeeds: availableShutterSpeedValues
            )
            updateIfChanged(\.recommendedShutterSpeed, to: result.shutterSpeed)
            updateIfChanged(\.recommendedShutterDuration, to: isPinholeMode ? result.exactDuration : nil)
            updateIfChanged(\.recommendedAperture, to: nil)
            updateDoubleIfChanged(\.evDifference, to: isPinholeMode ? result.continuousEVDifference : result.evDifference)
            updateIfChanged(\.isWithinRange, to: result.isWithinRange)

        case .shutterPriority:
            let result = lightMeter.calculateAperture(
                forEV: measuredEV,
                shutterSpeed: shutterSpeed,
                iso: iso,
                compensation: exposureCompensation,
                availableApertures: isPinholeMode ? Aperture.pinholeValues : Aperture.regularValues
            )
            updateIfChanged(\.recommendedAperture, to: result.aperture)
            updateIfChanged(\.recommendedShutterSpeed, to: nil)
            updateIfChanged(\.recommendedShutterDuration, to: nil)
            updateDoubleIfChanged(\.evDifference, to: result.evDifference)
            updateIfChanged(\.isWithinRange, to: result.isWithinRange)

        case .manual:
            let difference = lightMeter.calculateEVDifference(measuredEV: measuredEV, aperture: aperture, shutterSpeed: shutterSpeed, iso: iso, compensation: exposureCompensation)
            updateDoubleIfChanged(\.evDifference, to: difference)
            updateIfChanged(\.recommendedAperture, to: nil)
            updateIfChanged(\.recommendedShutterSpeed, to: nil)
            updateIfChanged(\.recommendedShutterDuration, to: nil)
            updateIfChanged(\.isWithinRange, to: true)
        }

        // 相反則不軌補正は通常撮影だけに限定する。ピンホールの長時間露光へ一律係数を掛けると過大になる。
        let ssTime = effectiveShutterDuration
        if ssTime >= 1.0 && !isPinholeMode {
            updateIfChanged(\.reciprocityCorrectedTime, to: pow(ssTime, 1.3))
        } else {
            updateIfChanged(\.reciprocityCorrectedTime, to: nil)
        }

        updateExposureStatus()
    }

    private func updateExposureStatus() {
        let nextStatus: ExposureStatus
        if evDifference < -2.0 {
            nextStatus = .severeUnderexposure
        } else if evDifference < -1.0 {
            nextStatus = .underexposure
        } else if evDifference < -0.5 {
            nextStatus = .slightUnderexposure
        } else if evDifference <= 0.5 {
            nextStatus = .proper
        } else if evDifference <= 1.0 {
            nextStatus = .slightOverexposure
        } else if evDifference <= 2.0 {
            nextStatus = .overexposure
        } else {
            nextStatus = .severeOverexposure
        }
        updateIfChanged(\.exposureStatus, to: nextStatus)
    }

    private func updateIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<ExposureViewModel, Value>,
        to newValue: Value
    ) {
        guard self[keyPath: keyPath] != newValue else { return }
        self[keyPath: keyPath] = newValue
    }

    private func updateDoubleIfChanged(
        _ keyPath: ReferenceWritableKeyPath<ExposureViewModel, Double>,
        to newValue: Double,
        tolerance: Double = 0.0001
    ) {
        guard abs(self[keyPath: keyPath] - newValue) > tolerance else { return }
        self[keyPath: keyPath] = newValue
    }

    // MARK: - ゾーンシステム — EV差分からゾーン0〜X算出
    var currentZone: Int {
        let zone = 5 + Int(round(evDifference))
        return max(0, min(10, zone))
    }

    // MARK: - 有効な撮影値 — モードに応じた実際の絞り/SS（推奨値 or 手動値）
    var effectiveAperture: Aperture {
        exposureMode == .shutterPriority ? (recommendedAperture ?? aperture) : aperture
    }

    var effectiveShutterSpeed: ShutterSpeed {
        exposureMode == .aperturePriority ? (recommendedShutterSpeed ?? shutterSpeed) : shutterSpeed
    }

    var effectiveShutterDuration: Double {
        if exposureMode == .aperturePriority, isPinholeMode, let recommendedShutterDuration {
            return recommendedShutterDuration
        }
        return effectiveShutterSpeed.rawValue
    }

    var effectiveShutterDisplayString: String {
        if exposureMode == .aperturePriority, isPinholeMode, let recommendedShutterDuration {
            return ExposureDurationFormatter.displayString(for: recommendedShutterDuration)
        }
        return effectiveShutterSpeed.displayString
    }

    var recommendedShutterDisplayString: String? {
        if isPinholeMode, let recommendedShutterDuration {
            return ExposureDurationFormatter.displayString(for: recommendedShutterDuration)
        }
        return recommendedShutterSpeed?.displayString
    }

    var previewAdjustmentEV: Double {
        switch exposureMode {
        case .manual:
            return softenedPreviewDifference(from: evDifference, deadZone: 0.1, scale: 1.0)
        case .aperturePriority, .shutterPriority:
            let deadZone = isWithinRange ? 0.35 : 0.15
            let scale = isWithinRange ? 0.4 : 0.75
            return softenedPreviewDifference(from: evDifference, deadZone: deadZone, scale: scale)
        }
    }

    private func softenedPreviewDifference(from value: Double, deadZone: Double, scale: Double) -> Double {
        let magnitude = abs(value)
        guard magnitude > deadZone else { return 0 }
        return (magnitude - deadZone) * scale * (value >= 0 ? 1 : -1)
    }

    var availableApertureValues: [Aperture] {
        isPinholeMode ? Aperture.pinholeValues : Aperture.regularValues
    }

    var availableISOValues: [ISOValue] {
        isPinholeMode ? ISOValue.pinholeValues : ISOValue.normalValues
    }

    var availableShutterSpeedValues: [ShutterSpeed] {
        isPinholeMode ? ShutterSpeed.pinholeValues : ShutterSpeed.standardValues
    }

    var availableExposureModes: [ExposureMode] {
        isPinholeMode ? [.aperturePriority] : ExposureMode.allCases
    }

    func availableMeteringModes(for policy: AppAccessPolicy) -> [MeteringMode] {
        isPinholeMode ? [.spot] : policy.availableReflectiveMeteringModes
    }

    func defaultMeteringMode(for policy: AppAccessPolicy) -> MeteringMode {
        isPinholeMode ? .spot : policy.defaultReflectiveMeteringMode
    }

    func allowsMeteringMode(_ mode: MeteringMode, for policy: AppAccessPolicy) -> Bool {
        availableMeteringModes(for: policy).contains(mode)
    }

    func normalizeMeteringMode(for policy: AppAccessPolicy) {
        let normalizedMode = allowsMeteringMode(meteringMode, for: policy)
            ? meteringMode
            : defaultMeteringMode(for: policy)
        if meteringMode != normalizedMode {
            meteringMode = normalizedMode
        }
    }

    // MARK: - 絞り調整 — 通常はf/32まで、ピンホール時はf/1〜f/999を1単位
    func adjustAperture(by steps: Int, emitHaptics: Bool = true) {
        let available = availableApertureValues
        guard let currentIndex = available.firstIndex(of: aperture) else {
            aperture = available.first ?? aperture
            return
        }
        let newIndex = max(0, min(available.count - 1, currentIndex + steps))
        aperture = available[newIndex]
        if emitHaptics, enableHaptics { HapticManager.shared.selectionChanged() }
    }

    func adjustShutterSpeed(by steps: Int, emitHaptics: Bool = true) {
        let allSpeeds = availableShutterSpeedValues
        guard let currentIndex = allSpeeds.firstIndex(of: shutterSpeed) else { return }
        let newIndex = max(0, min(allSpeeds.count - 1, currentIndex - steps))
        shutterSpeed = allSpeeds[newIndex]
        if emitHaptics, enableHaptics { HapticManager.shared.selectionChanged() }
    }

    func adjustISO(by steps: Int, emitHaptics: Bool = true) {
        let values = availableISOValues
        guard let currentIndex = values.firstIndex(of: iso) else {
            iso = nearestISO(in: values, to: iso.rawValue)
            return
        }
        let newIndex = max(0, min(values.count - 1, currentIndex + steps))
        iso = values[newIndex]
        if emitHaptics, enableHaptics { HapticManager.shared.selectionChanged() }
    }

    func toggleLock() {
        isLocked.toggle()
        if enableHaptics {
            isLocked ? HapticManager.shared.mediumTap() : HapticManager.shared.lightTap()
        }
    }

    func setLock(_ locked: Bool, withHaptics: Bool = false) {
        guard isLocked != locked else { return }
        isLocked = locked
        guard withHaptics, enableHaptics else { return }
        locked ? HapticManager.shared.mediumTap() : HapticManager.shared.lightTap()
    }

    // MARK: - ピンホールモード — f/1〜f/999のピンホールカメラ用絞り値に切替
    func togglePinholeMode() {
        setPinholeMode(!isPinholeMode)
    }

    func setPinholeMode(_ enabled: Bool, emitHaptics: Bool = true) {
        guard isPinholeMode != enabled else { return }
        isPinholeMode = enabled
        if enabled {
            exposureMode = .aperturePriority
            aperture = Aperture(rawValue: 200)
            iso = .iso6
            meteringMode = .spot
        } else {
            aperture = .f4_0
            iso = .iso400
        }
        normalizeShootingValuesForCurrentMode()
        calculateExposure()
        if emitHaptics, enableHaptics { HapticManager.shared.mediumTap() }
    }

    private func normalizeShootingValuesForCurrentMode() {
        if isPinholeMode {
            if meteringMode != .spot {
                meteringMode = .spot
            }
            if !Aperture.pinholeValues.contains(aperture) || aperture.rawValue < Aperture.f90.rawValue {
                aperture = Aperture(rawValue: 200)
            }
        } else {
            if !Aperture.regularValues.contains(aperture) {
                aperture = .f4_0
            }
            if !ShutterSpeed.standardValues.contains(shutterSpeed) {
                shutterSpeed = .sec30
            }
            if !ISOValue.normalValues.contains(iso) {
                iso = nearestISO(in: ISOValue.normalValues, to: iso.rawValue)
            }
        }
    }

    private func nearestISO(in values: [ISOValue], to rawValue: Int) -> ISOValue {
        values.min { lhs, rhs in
            abs(lhs.rawValue - rawValue) < abs(rhs.rawValue - rawValue)
        } ?? .iso50
    }

    func disablePinholeIfNeeded() {
        setPinholeMode(false, emitHaptics: false)
    }

    // MARK: - 撮影記録保存 — 現在の露出設定をShotRecordとして記録
    func saveShot(to store: ShotRecordStore, note: String = "") {
        let record = ShotRecord(
            aperture: effectiveAperture.displayString,
            shutterSpeed: effectiveShutterDisplayString,
            iso: iso.rawValue,
            ev: measuredEV,
            evDifference: evDifference,
            exposureMode: exposureMode.shortName,
            meteringMode: meteringMode.displayName,
            exposureCompensation: exposureCompensation,
            isIncident: isIncidentMode,
            zoneValue: currentZone,
            note: note
        )
        store.add(record)
        if enableHaptics { HapticManager.shared.mediumTap() }
    }
}
