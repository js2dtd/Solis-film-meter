//
//  CameraValues.swift
//  Solis film meter
//

// MARK: - 役割: 露出計算に使うカメラ値、測光設定、保存設定の定義
// MARK: - 目次
// 1. 露光時間フォーマットとシャッタースピード
// 2. 通常/ピンホール用絞り値
// 3. 通常/ピンホール用ISO感度
// 4. 測光モード、スポット基準、補正プリセット
// 5. 露出モードと露出状態
// 6. 焦点距離ガイドと全画面広角端
// 7. SavedSettingsと初期保存値

import Foundation
import AVFoundation
import SwiftUI
import UIKit

enum ExposureDurationFormatter {
    static func displayString(for seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "---" }

        if seconds < 1.0 {
            let denominator = 1.0 / seconds
            let roundedDenominator = denominator.rounded()
            if abs(denominator - roundedDenominator) < 0.1 {
                return "1/\(Int(roundedDenominator))"
            }
            return String(format: "%.1f\"", seconds)
        }

        let totalSeconds = max(1, Int(seconds.rounded()))
        if totalSeconds < 60 {
            return "\(totalSeconds)\""
        }

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60

        if hours > 0 {
            var parts = ["\(hours)時間"]
            if minutes > 0 {
                parts.append("\(minutes)分")
            }
            if remainingSeconds > 0 {
                parts.append("\(remainingSeconds)秒")
            }
            return parts.joined()
        }

        return remainingSeconds > 0 ? "\(minutes)分\(remainingSeconds)秒" : "\(minutes)分"
    }
}

// MARK: - シャッタースピード — 通常1/8000〜30秒、ピンホールは最大60分まで
enum ShutterSpeed: Double, CaseIterable, Identifiable {
    // 高速側（1/N秒）
    case s8000 = 0.000125       // 1/8000
    case s6400 = 0.00015625     // 1/6400
    case s5000 = 0.0002         // 1/5000
    case s4000 = 0.00025        // 1/4000
    case s3200 = 0.0003125      // 1/3200
    case s2500 = 0.0004         // 1/2500
    case s2000 = 0.0005         // 1/2000
    case s1600 = 0.000625       // 1/1600
    case s1250 = 0.0008         // 1/1250
    case s1000 = 0.001          // 1/1000
    case s800 = 0.00125         // 1/800
    case s640 = 0.0015625       // 1/640
    case s500 = 0.002           // 1/500
    case s400 = 0.0025          // 1/400
    case s320 = 0.003125        // 1/320
    case s250 = 0.004           // 1/250
    case s200 = 0.005           // 1/200
    case s160 = 0.00625         // 1/160
    case s125 = 0.008           // 1/125
    case s100 = 0.01            // 1/100
    case s80 = 0.0125           // 1/80
    case s60 = 0.01667          // 1/60
    case s50 = 0.02             // 1/50
    case s40 = 0.025            // 1/40
    case s30 = 0.03333          // 1/30
    case s25 = 0.04             // 1/25
    case s20 = 0.05             // 1/20
    case s15 = 0.06667          // 1/15
    case s13 = 0.07692          // 1/13
    case s10 = 0.1              // 1/10
    case s8 = 0.125             // 1/8
    case s6 = 0.16667           // 1/6
    case s5 = 0.2               // 1/5
    case s4 = 0.25              // 1/4
    case s2 = 0.5               // 1/2
    // 長秒側
    case sec1 = 1.0             // 1"
    case sec2 = 2.0             // 2"
    case sec4 = 4.0             // 4"
    case sec8 = 8.0             // 8"
    case sec15 = 15.0           // 15"
    case sec30 = 30.0           // 30"
    case min1 = 60.0            // 1分
    case min2 = 120.0           // 2分
    case min4 = 240.0           // 4分
    case min8 = 480.0           // 8分
    case min15 = 900.0          // 15分
    case min20 = 1200.0         // 20分
    case min30 = 1800.0         // 30分
    case min45 = 2700.0         // 45分
    case min60 = 3600.0         // 60分

    var id: Double { rawValue }

    var displayString: String {
        ExposureDurationFormatter.displayString(for: rawValue)
    }

    var tvValue: Double {
        return log2(1.0 / rawValue)
    }

    static var standardValues: [ShutterSpeed] {
        allCases.filter { $0.rawValue <= ShutterSpeed.sec30.rawValue }
    }

    static var pinholeValues: [ShutterSpeed] {
        allCases
    }
}

// MARK: - 絞り値 — 通常f/0.95〜f/32、ピンホールf/1〜f/999は1単位
struct Aperture: RawRepresentable, CaseIterable, Identifiable, Hashable, Codable {
    let rawValue: Double

    init(rawValue: Double) {
        self.rawValue = rawValue
    }

    var id: Double { rawValue }

    var displayString: String {
        if abs(rawValue - rawValue.rounded()) < 0.0001 {
            return "f/\(Int(rawValue.rounded()))"
        }

        let digits = rawValue < 1.0 ? 2 : 1
        var formatted = String(format: "%.\(digits)f", rawValue)
        while formatted.hasSuffix("0") {
            formatted.removeLast()
        }
        if formatted.hasSuffix(".") {
            formatted.removeLast()
        }
        return "f/\(formatted)"
    }

    var avValue: Double {
        return 2.0 * log2(rawValue)
    }

    static let f0_95 = Aperture(rawValue: 0.95)
    static let f1_0 = Aperture(rawValue: 1.0)
    static let f1_1 = Aperture(rawValue: 1.1)
    static let f1_2 = Aperture(rawValue: 1.2)
    static let f1_4 = Aperture(rawValue: 1.4)
    static let f1_6 = Aperture(rawValue: 1.6)
    static let f1_8 = Aperture(rawValue: 1.8)
    static let f2_0 = Aperture(rawValue: 2.0)
    static let f2_2 = Aperture(rawValue: 2.2)
    static let f2_5 = Aperture(rawValue: 2.5)
    static let f2_8 = Aperture(rawValue: 2.8)
    static let f3_2 = Aperture(rawValue: 3.2)
    static let f3_5 = Aperture(rawValue: 3.5)
    static let f4_0 = Aperture(rawValue: 4.0)
    static let f4_5 = Aperture(rawValue: 4.5)
    static let f5_0 = Aperture(rawValue: 5.0)
    static let f5_6 = Aperture(rawValue: 5.6)
    static let f6_3 = Aperture(rawValue: 6.3)
    static let f7_1 = Aperture(rawValue: 7.1)
    static let f8_0 = Aperture(rawValue: 8.0)
    static let f9 = Aperture(rawValue: 9.0)
    static let f10 = Aperture(rawValue: 10.0)
    static let f11 = Aperture(rawValue: 11.0)
    static let f13 = Aperture(rawValue: 13.0)
    static let f14 = Aperture(rawValue: 14.0)
    static let f16 = Aperture(rawValue: 16.0)
    static let f18 = Aperture(rawValue: 18.0)
    static let f20 = Aperture(rawValue: 20.0)
    static let f22 = Aperture(rawValue: 22.0)
    static let f25 = Aperture(rawValue: 25.0)
    static let f29 = Aperture(rawValue: 29.0)
    static let f32 = Aperture(rawValue: 32.0)
    static let f36 = Aperture(rawValue: 36.0)
    static let f40 = Aperture(rawValue: 40.0)
    static let f45 = Aperture(rawValue: 45.0)
    static let f51 = Aperture(rawValue: 51.0)
    static let f57 = Aperture(rawValue: 57.0)
    static let f64 = Aperture(rawValue: 64.0)
    static let f90 = Aperture(rawValue: 90.0)
    static let f128 = Aperture(rawValue: 128.0)
    static let f180 = Aperture(rawValue: 180.0)
    static let f256 = Aperture(rawValue: 256.0)
    static let f999 = Aperture(rawValue: 999.0)

    static let regularValues: [Aperture] = [
        .f0_95, .f1_0, .f1_1, .f1_2, .f1_4, .f1_6, .f1_8,
        .f2_0, .f2_2, .f2_5, .f2_8, .f3_2, .f3_5,
        .f4_0, .f4_5, .f5_0, .f5_6, .f6_3, .f7_1,
        .f8_0, .f9, .f10, .f11, .f13, .f14, .f16,
        .f18, .f20, .f22, .f25, .f29, .f32
    ]

    static let pinholeValues: [Aperture] = (1...999).map { Aperture(rawValue: Double($0)) }

    static var allCases: [Aperture] {
        regularValues + pinholeValues.filter { !regularValues.contains($0) }
    }
}

// MARK: - ISO感度 — 通常ISO 50〜25600、ピンホールISO 3〜25600
struct ISOValue: RawRepresentable, CaseIterable, Identifiable, Hashable, Codable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = min(max(3, rawValue), 25600)
    }

    var id: Int { rawValue }

    var displayString: String { "ISO \(rawValue)" }

    var svValue: Double {
        return log2(Double(rawValue) / 100.0)
    }

    static let iso3 = ISOValue(rawValue: 3)
    static let iso4 = ISOValue(rawValue: 4)
    static let iso5 = ISOValue(rawValue: 5)
    static let iso6 = ISOValue(rawValue: 6)
    static let iso8 = ISOValue(rawValue: 8)
    static let iso10 = ISOValue(rawValue: 10)
    static let iso12 = ISOValue(rawValue: 12)
    static let iso16 = ISOValue(rawValue: 16)
    static let iso20 = ISOValue(rawValue: 20)
    static let iso25 = ISOValue(rawValue: 25)
    static let iso32 = ISOValue(rawValue: 32)
    static let iso40 = ISOValue(rawValue: 40)
    static let iso50 = ISOValue(rawValue: 50)
    static let iso64 = ISOValue(rawValue: 64)
    static let iso80 = ISOValue(rawValue: 80)
    static let iso100 = ISOValue(rawValue: 100)
    static let iso125 = ISOValue(rawValue: 125)
    static let iso160 = ISOValue(rawValue: 160)
    static let iso200 = ISOValue(rawValue: 200)
    static let iso250 = ISOValue(rawValue: 250)
    static let iso320 = ISOValue(rawValue: 320)
    static let iso400 = ISOValue(rawValue: 400)
    static let iso500 = ISOValue(rawValue: 500)
    static let iso640 = ISOValue(rawValue: 640)
    static let iso800 = ISOValue(rawValue: 800)
    static let iso1000 = ISOValue(rawValue: 1000)
    static let iso1250 = ISOValue(rawValue: 1250)
    static let iso1600 = ISOValue(rawValue: 1600)
    static let iso2000 = ISOValue(rawValue: 2000)
    static let iso2500 = ISOValue(rawValue: 2500)
    static let iso3200 = ISOValue(rawValue: 3200)
    static let iso4000 = ISOValue(rawValue: 4000)
    static let iso5000 = ISOValue(rawValue: 5000)
    static let iso6400 = ISOValue(rawValue: 6400)
    static let iso8000 = ISOValue(rawValue: 8000)
    static let iso10000 = ISOValue(rawValue: 10000)
    static let iso12800 = ISOValue(rawValue: 12800)
    static let iso16000 = ISOValue(rawValue: 16000)
    static let iso20000 = ISOValue(rawValue: 20000)
    static let iso25600 = ISOValue(rawValue: 25600)

    static let allCases: [ISOValue] = [
        .iso3, .iso4, .iso5, .iso6, .iso8, .iso10, .iso12, .iso16,
        .iso20, .iso25, .iso32, .iso40, .iso50, .iso64, .iso80,
        .iso100, .iso125, .iso160, .iso200, .iso250, .iso320,
        .iso400, .iso500, .iso640, .iso800, .iso1000, .iso1250,
        .iso1600, .iso2000, .iso2500, .iso3200, .iso4000, .iso5000,
        .iso6400, .iso8000, .iso10000, .iso12800, .iso16000,
        .iso20000, .iso25600
    ]

    static var commonFilmValues: [ISOValue] {
        normalValues
    }

    static var normalValues: [ISOValue] {
        allCases.filter { $0.rawValue >= 50 }
    }

    static var pinholeValues: [ISOValue] {
        allCases
    }
}

// MARK: - 測光モード — スポット/中央重点/マルチ/平均/2点（アイコン+表示名）
enum MeteringMode: String, CaseIterable, Identifiable {
    case spot = "spot"
    case centerWeighted = "center"
    case matrix = "matrix"
    case average = "average"
    case threePoint = "threePoint"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spot: return "スポット"
        case .centerWeighted: return "中央重点"
        case .matrix: return "マルチ"
        case .average: return "平均"
        case .threePoint: return "2点"
        }
    }

    var compactLabel: String {
        switch self {
        case .spot: return "スポット"
        case .centerWeighted: return "中央"
        case .matrix: return "マルチ"
        case .average: return "平均"
        case .threePoint: return "2点"
        }
    }

    var shortDescription: String {
        switch self {
        case .spot: return "狭い範囲を測る"
        case .centerWeighted: return "中央を優先"
        case .matrix: return "全体を見て判断"
        case .average: return "全体を均等に測る"
        case .threePoint: return "中央で明暗2点を測る"
        }
    }

    var detailDescription: String {
        switch self {
        case .spot: return "小さい範囲を重点的に測ります"
        case .centerWeighted: return "中央付近を優先して測ります"
        case .matrix: return "全体を見て偏りを抑えて測ります"
        case .average: return "画面全体を均等に測ります"
        case .threePoint: return "最明部と最暗部を中央に置いて順に測ります"
        }
    }

    var icon: String {
        switch self {
        case .spot: return "circle.circle"
        case .centerWeighted: return "circle.dashed"
        case .matrix: return "rectangle.split.3x3"
        case .average: return "square.fill"
        case .threePoint: return "triangle"
        }
    }
}

enum SpotMeteringReferenceTarget: String, CaseIterable, Identifiable, Codable {
    case darkest
    case shadow
    case sunlit
    case brightest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .darkest: return "最暗部"
        case .shadow: return "影部分"
        case .sunlit: return "日向部分"
        case .brightest: return "最明部"
        }
    }

    var shortTitle: String {
        switch self {
        case .darkest: return "最暗部"
        case .shadow: return "影部分"
        case .sunlit: return "日向部分"
        case .brightest: return "最明部"
        }
    }

    var iconName: String {
        switch self {
        case .darkest: return "moon.fill"
        case .shadow: return "cloud.fill"
        case .sunlit: return "sun.max.fill"
        case .brightest: return "sparkles"
        }
    }

    var detailText: String {
        switch self {
        case .darkest:
            return "画面内で最も暗い部分を基準に測光します。"
        case .shadow:
            return "影になっている部分を基準にして測光します。"
        case .sunlit:
            return "日が当たっている部分を基準にして測光します。"
        case .brightest:
            return "画面内で最も明るい部分を基準に測光します。"
        }
    }

    var warningToleranceEV: Double {
        switch self {
        case .darkest, .brightest:
            return 2.35
        case .shadow, .sunlit:
            return 2.6
        }
    }
}

enum SpotMeteringExposureBoostPreset: String, CaseIterable, Identifiable, Codable {
    case minusOne
    case minusTwoThirds
    case minusThird
    case neutral
    case plusThird
    case plusTwoThirds
    case plusOne

    var id: String { rawValue }

    var boostEV: Double {
        switch self {
        case .minusOne: return -1.0
        case .minusTwoThirds: return -(2.0 / 3.0)
        case .minusThird: return -(1.0 / 3.0)
        case .neutral: return 0
        case .plusThird: return 1.0 / 3.0
        case .plusTwoThirds: return 2.0 / 3.0
        case .plusOne: return 1.0
        }
    }

    var shortLabel: String {
        switch self {
        case .minusOne: return "-1EV"
        case .minusTwoThirds: return "-2/3EV"
        case .minusThird: return "-1/3EV"
        case .neutral: return "なし"
        case .plusThird: return "+1/3EV"
        case .plusTwoThirds: return "+2/3EV"
        case .plusOne: return "+1EV"
        }
    }

    var detailText: String {
        switch self {
        case .minusOne:
            return "かなり暗め"
        case .minusTwoThirds:
            return "標準より暗め"
        case .minusThird:
            return "少し暗め"
        case .neutral:
            return "補正なし"
        case .plusThird:
            return "少し明るめ"
        case .plusTwoThirds:
            return "標準より明るめ"
        case .plusOne:
            return "かなり明るめ"
        }
    }
}

// MARK: - 露出モード — 絞り優先(Av)/シャッター優先(Tv)/マニュアル(M)
enum ExposureMode: String, CaseIterable, Identifiable {
    case aperturePriority = "Av"
    case shutterPriority = "Tv"
    case manual = "M"

    var id: String { rawValue }
    var shortName: String { rawValue }

    var displayName: String {
        switch self {
        case .aperturePriority: return "絞り優先"
        case .shutterPriority: return "シャッター優先"
        case .manual: return "マニュアル"
        }
    }
}

// MARK: - 露出状態 — 7段階（大幅アンダー〜適正〜大幅オーバー）色+アイコン付き
enum ExposureStatus {
    case severeUnderexposure
    case underexposure
    case slightUnderexposure
    case proper
    case slightOverexposure
    case overexposure
    case severeOverexposure

    var displayName: String {
        switch self {
        case .severeUnderexposure: return "大幅アンダー"
        case .underexposure: return "アンダー"
        case .slightUnderexposure: return "やや暗い"
        case .proper: return "適正"
        case .slightOverexposure: return "やや明るい"
        case .overexposure: return "オーバー"
        case .severeOverexposure: return "大幅オーバー"
        }
    }

    var color: Color {
        switch self {
        case .severeUnderexposure: return .blue
        case .underexposure: return .cyan
        case .slightUnderexposure: return .teal
        case .proper: return .green
        case .slightOverexposure: return .yellow
        case .overexposure: return .orange
        case .severeOverexposure: return .red
        }
    }

    var icon: String {
        switch self {
        case .severeUnderexposure, .underexposure, .slightUnderexposure:
            return "minus.circle.fill"
        case .proper:
            return "checkmark.circle.fill"
        case .slightOverexposure, .overexposure, .severeOverexposure:
            return "plus.circle.fill"
        }
    }
}

// MARK: - 焦点距離ガイド — 実機の広角端と全画面表示時の見かけ焦点距離
enum LensFocalLengthGuide {
    static let wideEndRequestEquivalentFocalLength = 1.0

    private static let fallbackBackWideEquivalentFocalLength = 24.0
    private static let fullFrameHorizontalMillimeters = 36.0
    private static let fullscreenPreviewWidthToHeightRatio: CGFloat = 2.0 / 3.0
    private static let cachedBackWideEquivalentFocalLength: Double = {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            return fallbackBackWideEquivalentFocalLength
        }
        return referenceEquivalentFocalLength(for: camera)
    }()

    @MainActor
    static var fullscreenWideEndEquivalentFocalLength: Int {
        let wideEnd = currentBackWideEquivalentFocalLength()
        let multiplier = fullscreenVisibleFocalLengthMultiplier(for: currentScreenSize())
        return max(1, Int((wideEnd * multiplier).rounded()))
    }

    static func referenceEquivalentFocalLength(for camera: AVCaptureDevice) -> Double {
        let horizontalFieldOfView = Double(camera.activeFormat.videoFieldOfView)
        if horizontalFieldOfView > 0, horizontalFieldOfView < 179 {
            let radians = horizontalFieldOfView * .pi / 180
            return fullFrameHorizontalMillimeters / (2 * tan(radians / 2))
        }

        switch (camera.position, camera.deviceType) {
        case (.front, _):
            return 26
        case (.back, .builtInUltraWideCamera):
            return 13
        case (.back, .builtInTelephotoCamera):
            return 77
        default:
            return fallbackBackWideEquivalentFocalLength
        }
    }

    static func fullscreenVisibleFocalLengthMultiplier(for screenSize: CGSize) -> Double {
        let width = min(screenSize.width, screenSize.height)
        let height = max(screenSize.width, screenSize.height)
        guard width > 1, height > 1 else { return 1 }

        let verticalFillWidth = height * fullscreenPreviewWidthToHeightRatio
        return max(1, Double(verticalFillWidth / width))
    }

    @MainActor
    private static func currentScreenSize() -> CGSize {
        if let screen = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.screen })
            .first {
            return screen.bounds.size
        }

        // 19.5:9系の端末を基準にした安全なフォールバック。
        return CGSize(width: 393, height: 852)
    }

    private static func currentBackWideEquivalentFocalLength() -> Double {
        cachedBackWideEquivalentFocalLength
    }
}

// MARK: - 設定保存用 — ISO/EV表示/触覚/ピンホールのCodable構造体
struct SavedSettings: Codable {
    var defaultISO: Int
    var showEVValue: Bool
    var showAuxiliaryLabels: Bool
    var enableHaptics: Bool
    var enablePinholeMode: Bool
    var isPinholeMode: Bool
    var spotBrightAreaWarningEnabled: Bool
    var spotOffTargetWarningEnabled: Bool
    var spotMeteringReferenceTarget: SpotMeteringReferenceTarget
    var spotExposureBoostPreset: SpotMeteringExposureBoostPreset
    var hasSeenDisplayModeGuide: Bool

    private enum CodingKeys: String, CodingKey {
        case defaultISO
        case showEVValue
        case showAuxiliaryLabels
        case enableHaptics
        case enablePinholeMode
        case isPinholeMode
        case spotWarningEnabled
        case spotBrightAreaWarningEnabled
        case spotOffTargetWarningEnabled
        case spotMeteringReferenceTarget
        case spotExposureBoostPreset
        case hasSeenDisplayModeGuide
        case hasCompletedMeteringSetup
    }

    static let defaultSettings = SavedSettings(
        defaultISO: 400,
        showEVValue: true,
        showAuxiliaryLabels: true,
        enableHaptics: true,
        enablePinholeMode: false,
        isPinholeMode: false,
        spotBrightAreaWarningEnabled: true,
        spotOffTargetWarningEnabled: true,
        spotMeteringReferenceTarget: .shadow,
        spotExposureBoostPreset: .neutral,
        hasSeenDisplayModeGuide: false
    )

    init(
        defaultISO: Int,
        showEVValue: Bool,
        showAuxiliaryLabels: Bool = true,
        enableHaptics: Bool,
        enablePinholeMode: Bool = false,
        isPinholeMode: Bool = false,
        spotBrightAreaWarningEnabled: Bool = true,
        spotOffTargetWarningEnabled: Bool = true,
        spotMeteringReferenceTarget: SpotMeteringReferenceTarget = .shadow,
        spotExposureBoostPreset: SpotMeteringExposureBoostPreset = .neutral,
        hasSeenDisplayModeGuide: Bool = false
    ) {
        self.defaultISO = defaultISO
        self.showEVValue = showEVValue
        self.showAuxiliaryLabels = showAuxiliaryLabels
        self.enableHaptics = enableHaptics
        self.enablePinholeMode = enablePinholeMode
        self.isPinholeMode = isPinholeMode
        self.spotBrightAreaWarningEnabled = spotBrightAreaWarningEnabled
        self.spotOffTargetWarningEnabled = spotOffTargetWarningEnabled
        self.spotMeteringReferenceTarget = spotMeteringReferenceTarget
        self.spotExposureBoostPreset = spotExposureBoostPreset
        self.hasSeenDisplayModeGuide = hasSeenDisplayModeGuide
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultISO = try container.decodeIfPresent(Int.self, forKey: .defaultISO) ?? 400
        showEVValue = try container.decodeIfPresent(Bool.self, forKey: .showEVValue) ?? true
        showAuxiliaryLabels = try container.decodeIfPresent(Bool.self, forKey: .showAuxiliaryLabels) ?? true
        enableHaptics = try container.decodeIfPresent(Bool.self, forKey: .enableHaptics) ?? true
        enablePinholeMode = try container.decodeIfPresent(Bool.self, forKey: .enablePinholeMode) ?? false
        isPinholeMode = try container.decodeIfPresent(Bool.self, forKey: .isPinholeMode) ?? false
        let legacyWarningEnabled = try container.decodeIfPresent(Bool.self, forKey: .spotWarningEnabled) ?? true
        spotBrightAreaWarningEnabled = try container.decodeIfPresent(Bool.self, forKey: .spotBrightAreaWarningEnabled) ?? legacyWarningEnabled
        spotOffTargetWarningEnabled = try container.decodeIfPresent(Bool.self, forKey: .spotOffTargetWarningEnabled) ?? legacyWarningEnabled
        spotMeteringReferenceTarget = try container.decodeIfPresent(SpotMeteringReferenceTarget.self, forKey: .spotMeteringReferenceTarget) ?? .shadow
        spotExposureBoostPreset = try container.decodeIfPresent(SpotMeteringExposureBoostPreset.self, forKey: .spotExposureBoostPreset) ?? .neutral
        hasSeenDisplayModeGuide =
            try container.decodeIfPresent(Bool.self, forKey: .hasSeenDisplayModeGuide)
            ?? (try container.decodeIfPresent(Bool.self, forKey: .hasCompletedMeteringSetup) ?? false)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(defaultISO, forKey: .defaultISO)
        try container.encode(showEVValue, forKey: .showEVValue)
        try container.encode(showAuxiliaryLabels, forKey: .showAuxiliaryLabels)
        try container.encode(enableHaptics, forKey: .enableHaptics)
        try container.encode(enablePinholeMode, forKey: .enablePinholeMode)
        try container.encode(isPinholeMode, forKey: .isPinholeMode)
        try container.encode(spotBrightAreaWarningEnabled, forKey: .spotBrightAreaWarningEnabled)
        try container.encode(spotOffTargetWarningEnabled, forKey: .spotOffTargetWarningEnabled)
        try container.encode(spotMeteringReferenceTarget, forKey: .spotMeteringReferenceTarget)
        try container.encode(spotExposureBoostPreset, forKey: .spotExposureBoostPreset)
        try container.encode(hasSeenDisplayModeGuide, forKey: .hasSeenDisplayModeGuide)
    }
}
