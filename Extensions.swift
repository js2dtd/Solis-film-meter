//
//  Extensions.swift
//  Solis film meter
//

// MARK: - 役割: 色・フォント・保存設定などの共通拡張
// MARK: - 目次
// 1. Color Extensions（KO II/Refinedパレット）
// 2. 共通形状定数
// 3. Double EV文字列フォーマット
// 4. Font/Animation定義
// 5. HapticManager
// 6. UserDefaults Codable保存補助

import SwiftUI

// MARK: - Color Extensions — KO II inspired カラーパレット
extension Color {
    static let meterBackground = Color(red: 0.75, green: 0.73, blue: 0.70)  // メイン背景（KO IIボディ色）
    static let meterAccent = Color(red: 0.95, green: 0.36, blue: 0.14)      // TEオレンジ（選択中モード、AUTO値）
    static let meterSecondary = Color(red: 0.22, green: 0.21, blue: 0.20)   // ダークチャコール（テキスト全般）
    static let meterRed = Color(red: 0.95, green: 0.30, blue: 0.18)         // 露出アンダー警告
    static let meterGreen = Color(red: 0.40, green: 0.75, blue: 0.42)       // 適正露出表示
    static let meterSurface = Color(red: 0.65, green: 0.63, blue: 0.60)     // カード・トラック背景
    static let meterButtonBg = Color(red: 0.55, green: 0.53, blue: 0.50)    // ボタン背景
    static let meterCardBg = Color(red: 0.68, green: 0.66, blue: 0.63)      // カード背景
    static let meterBlue = Color(red: 0.08, green: 0.28, blue: 0.92)        // ユーザー調整可能な値（±ボタン付き）

    static let refinedBackground = Color(red: 0.05, green: 0.06, blue: 0.07)
    static let refinedSurface = Color(red: 0.09, green: 0.10, blue: 0.12)
    static let refinedPanel = Color(red: 0.15, green: 0.16, blue: 0.18)
    static let refinedPanelSoft = Color(red: 0.22, green: 0.23, blue: 0.26)
    static let refinedText = Color.white.opacity(0.96)
    static let refinedTextSoft = Color.white.opacity(0.78)
    static let refinedTextOnDark = Color.white.opacity(0.94)
    static let refinedTextMutedOnDark = Color.white.opacity(0.72)
    static let refinedStroke = Color.white.opacity(0.12)
}

enum MeterShape {
    static let preview: CGFloat = 6
    static let control: CGFloat = 6
    static let box: CGFloat = 8
    static let card: CGFloat = 10
}

// MARK: - Double Extensions — EV値フォーマット（"+1.3" / "-0.7"）
extension Double {
    var evString: String {
        if self >= 0 {
            return String(format: "+%.1f", self)
        } else {
            return String(format: "%.1f", self)
        }
    }
}

// MARK: - Font Extensions — モノスペースフォント定義
extension Font {
    static func meterDisplay(_ size: CGFloat) -> Font {  // 大きな表示用（medium）
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func meterLabel(_ size: CGFloat) -> Font {    // ラベル用（medium）
        .system(size: size, weight: .medium, design: .monospaced)
    }

    static func meterValue(_ size: CGFloat) -> Font {    // 値表示用（bold）
        .system(size: size, weight: .bold, design: .monospaced)
    }
}

// MARK: - Animation Extensions — UI遷移アニメーション
extension Animation {
    static let valueChange = Animation.easeInOut(duration: 0.2)  // 値変更時の0.2秒イージング
}

// MARK: - Haptic Manager — 触覚フィードバック（タップ/選択変更/成功通知）
struct HapticManager {
    static let shared = HapticManager()
    static var isEnabled = true
    
    private let lightImpact = UIImpactFeedbackGenerator(style: .medium)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let selectionImpact = UIImpactFeedbackGenerator(style: .rigid)
    private let notification = UINotificationFeedbackGenerator()
    
    private init() {
        lightImpact.prepare()
        mediumImpact.prepare()
        selectionImpact.prepare()
        notification.prepare()
    }
    
    func lightTap() {
        guard Self.isEnabled else { return }
        lightImpact.impactOccurred(intensity: 0.82)
        lightImpact.prepare()
    }

    func mediumTap() {
        guard Self.isEnabled else { return }
        mediumImpact.impactOccurred(intensity: 1.0)
        mediumImpact.prepare()
    }

    func selectionChanged() {
        guard Self.isEnabled else { return }
        selectionImpact.impactOccurred(intensity: 0.72)
        selectionImpact.prepare()
    }

    func success() {
        guard Self.isEnabled else { return }
        notification.notificationOccurred(.success)
        notification.prepare()
    }
}

// MARK: - UserDefaults Extension — 設定の永続化（JSON encode/decode）
extension UserDefaults {
    private enum Keys {
        static let savedSettings = "savedSettings"
    }
    
    var savedSettings: SavedSettings? {
        get {
            guard let data = data(forKey: Keys.savedSettings) else { return nil }
            return try? JSONDecoder().decode(SavedSettings.self, from: data)
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            set(data, forKey: Keys.savedSettings)
        }
    }
}
