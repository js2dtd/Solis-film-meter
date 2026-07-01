# Solis film meter - プロジェクト引き継ぎドキュメント

## プロジェクト概要

フィルムカメラ用の露出計iOSアプリ。iPhoneのカメラセンサーを利用してシーンのEV値を測定し、フィルム撮影に必要な絞り・シャッタースピード・ISO設定を提示する。

### ターゲットユーザー
- フィルムカメラを使用する写真愛好家
- マニュアル露出制御が必要な撮影者

### 技術スタック
- Swift / SwiftUI
- AVFoundation（カメラアクセス）
- CoreImage（画像輝度分析）
- Xcode（ビルド・実行）

---

## ファイル構成（10ファイル）

| ファイル | 行数 | 役割 |
|---------|------|------|
| `SolisFilmMeterApp.swift` | 31 | アプリエントリポイント、UIAppearance設定 |
| `ContentView.swift` | 679 | メイン画面UI、カメラプレビュー、露出コントロール、キャリブレーションView |
| `Fullscreenmeterview.swift` | 457 | フルスクリーン測光モード、タップ測光、測光ガイドオーバーレイ |
| `ExposureViewModel.swift` | 148 | 露出計算のViewModel、状態管理、設定保存 |
| `LightMeterCameraManager.swift` | 218 | カメラセッション管理、EV算出、キャリブレーション |
| `LightMeterEngine.swift` | 200 | 露出計算エンジン（Av/Tv/M各モード）、輝度測定 |
| `CameraValues.swift` | 190 | シャッタースピード・絞り・ISO・各種enumの定義 |
| `UIComponents.swift` | 294 | 共有UIコンポーネント（ValueStepper, QuickISOPicker等） |
| `Extensions.swift` | 93 | Color/Font/Animation拡張、HapticManager、UserDefaults |
| `SettingsView.swift` | 210 | 設定画面 |

---

## アーキテクチャ

### データフロー
```
iPhone Camera (Auto Exposure)
    ↓
LightMeterCameraManager（AVCaptureVideoDataOutput）
    ↓ deviceISO, deviceShutterSpeed, exposureDuration
    ↓ + LightMeterEngine.measureLuminance()
    ↓
EV計算: deviceEV + luminanceCorrection + calibrationOffset - targetBias
    ↓
smoothedEV（移動平均・外れ値除外）
    ↓ → cameraManager.currentEV
ExposureViewModel.updateMeasuredEV()
    ↓
calculateExposure()（モード別計算）
    ↓
UI更新（推奨値・露出ステータス）
```

### EV計算式（LightMeterCameraManager内）
```swift
let deviceEV = log2(pow(deviceAperture, 2) / shutterSpeed) - log2(iso / 100.0)
let luminanceCorrection = log2(imageLuminance / 0.18) * 0.5
let calculatedEV = deviceEV + luminanceCorrection + calibrationOffset - targetBias
```

**重要な知見**: iPhoneカメラは生のシーン値ではなく自動露出補正済みの値を返す。そのため、ISO補正は `+ log2(ISO/100)` ではなく `- log2(ISO/100)` が正しい。

### 露出モード
- **絞り優先（Av）**: 測定EVと設定絞りから推奨シャッタースピードを算出
- **シャッター優先（Tv）**: 測定EVと設定SSから推奨絞りを算出
- **マニュアル（M）**: 測定EVと設定値の差分を表示

### 測光モード
- **スポット**: 画像の3%範囲（タップ位置指定可能）
- **中央重点**: コア50% + 中央30% + 全体20%の加重平均
- **マトリクス**: 3×3グリッド、中央セルに高い重み（40%）
- **平均**: 画面全体の均一平均

---

## カラーパレット（KO II inspired）

Teenage Engineering KO IIサンプラーのデザインをベースにした配色。

```swift
// 明るいシルバーグレー背景
meterBackground: (0.75, 0.73, 0.70)  // KO IIボディカラー
meterAccent:     (0.95, 0.36, 0.14)  // TEオレンジ
meterSecondary:  (0.22, 0.21, 0.20)  // ダークチャコール（テキスト）
meterRed:        (0.95, 0.30, 0.18)  // RECORDボタン色
meterGreen:      (0.40, 0.75, 0.42)  // 適正露出表示

// 追加色（UI要素用）
meterSurface:    (0.65, 0.63, 0.60)  // 中間グレー
meterButtonBg:   (0.55, 0.53, 0.50)  // ボタン背景
meterCardBg:     (0.68, 0.66, 0.63)  // カード背景
```

**配色注意点**: 明るい背景のため、暗い要素とのコントラストに注意が必要。ボタンアイコン（meterSecondary: 0.22）がボタン背景（meterButtonBg）の上で十分なコントラストを持つこと。

---

## キャリブレーション機能

### 構造
`calibrationOffset`（Double）が全EV計算に加算される単一のオフセット値。

### なぜ単一オフセットで十分か
EV値は対数スケール。リニア空間での乗算的な系統誤差（T-stop差、センサー感度差）は、対数空間では加算的なオフセットになる。したがって単一の定数で補正可能。

### キャリブレーションView（ContentView.swift内）
3セクション構成:
1. **現在のアプリ測定値** — リアルタイムEV表示
2. **基準値入力 → 自動オフセット計算** — 別の露出計のEV値を入力、差分を自動計算してApply
3. **手動微調整** — ±1/±⅓ボタンとリセット

---

## UI設計の決定事項

### メイン画面（ContentView）
- カメラプレビュー: 187×280px（3:2アスペクト比近似）
- プレビュー下部にコンパクトな露出状態カプセル（ステータスドット + 名前）
- ExposureBarIndicatorは削除済み（不要と判断）
- タップジェスチャーはプレビュー画像領域のみに制限（`.contentShape`使用）
- 左スワイプでフルスクリーンモードへ遷移

### フルスクリーン画面（FullScreenMeterView）
- タップで任意の位置をスポット測光
- 下部にコンパクトなコントロール（Av/Tv/M切替、測光モード、値調整）
- スワイプで戻る
- 測光ガイドオーバーレイ（Canvas描画）

### プレビュー画像処理
- 90°回転（iPhoneカメラの出力方向補正）
- EV差分に応じたbrightness/contrast/saturation調整で露出シミュレーション

---

## 安定性に関する設計

### EV値の安定化
- 移動平均（履歴サイズ10）
- 外れ値除外（ソート後に上下10%をトリム）
- モード変更時・露出アンロック時に履歴クリア

### 境界チェック
- スポット測光の矩形が画像範囲内に収まるよう`.intersection(extent)`
- シャッタースピード/絞りの推奨値が設定範囲外の場合`isWithinRange = false`で警告表示

---

## 既知の課題・今後の検討事項

- ステップサイズ設定（1/3, 1/2, 1段）が定義されているが、UI上での値ステップには未完全適用
- 露出補正の範囲が±5EVだが、UIスライダーの操作感改善の余地あり
- previewImageの回転処理がハードコードされている（デバイス向き対応なし）
- `.preferredColorScheme(.dark)`がSolisFilmMeterApp.swiftにあるが、KO IIの明るい配色と矛盾する可能性あり（要確認）

---

## コーディング規約

- 日本語コメント使用（UIテキストも日本語）
- UTF-8エンコーディング厳守（二重エンコード問題を過去に修正済み）
- SwiftUI宣言的パターン
- `@Published` + Combine で状態管理
- カメラ操作は`sessionQueue`（バックグラウンドDispatchQueue）で実行
- UI更新は`DispatchQueue.main.async`で確実にメインスレッドへ
