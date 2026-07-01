//
//  SettingsView.swift
//  Solis film meter
//

// MARK: - 役割: 露出計アプリの各種設定画面
// MARK: - 目次
// 1. SettingsView本体とRefined/通常設定テーマ
// 2. 完全版購入/復元とデバッグアクセス確認
// 3. プリセット管理、注文ページ、スポット測光設定
// 4. 表示/デフォルト/ピンホール/フィードバック設定
// 5. キャリブレーション設定
// 6. プライバシーポリシー/情報表示
// 7. 設定用共通行コンポーネント

import SwiftUI
import UIKit

struct SettingsView: View {
    @ObservedObject var viewModel: ExposureViewModel
    @ObservedObject var cameraManager: LightMeterCameraManager
    @ObservedObject var sessionStore: AppSessionStore
    @ObservedObject var accessStore: PurchaseAccessStore
    var onDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var showPresetManager = false
    @State private var copiedPresetID: UUID?
    @State private var referenceEV: String = ""
    @State private var isFinishingDismissal = false
    @State private var showPinholeFNumberHelp = false

    private var pinholeModeBinding: Binding<Bool> {
        Binding(
            get: { viewModel.isPinholeMode },
            set: { viewModel.setPinholeMode($0) }
        )
    }

    private var usesRefinedSettingsUI: Bool { !viewModel.showAuxiliaryLabels }
    private var availableMeteringModes: [MeteringMode] { viewModel.availableMeteringModes(for: accessPolicy) }
    private var settingsBackgroundColor: Color { usesRefinedSettingsUI ? .refinedBackground : .meterBackground }
    private var settingsCardColor: Color { usesRefinedSettingsUI ? .refinedSurface : .meterCardBg }
    private var settingsTextColor: Color { usesRefinedSettingsUI ? .refinedText : .meterSecondary }
    private var settingsSecondaryTextColor: Color { usesRefinedSettingsUI ? .refinedTextSoft : .meterSecondary.opacity(0.75) }
    private var settingsDividerColor: Color { usesRefinedSettingsUI ? .refinedStroke.opacity(0.8) : Color.black.opacity(0.12) }
    private var settingsTintColor: Color { usesRefinedSettingsUI ? .cyan : .meterAccent }
    private var settingsPrimaryButtonFill: Color { usesRefinedSettingsUI ? .refinedPanel : .meterAccent }
    private var settingsPrimaryButtonText: Color { usesRefinedSettingsUI ? .refinedTextOnDark : .black }
    private var settingsStrokeColor: Color { usesRefinedSettingsUI ? .refinedStroke : Color.black.opacity(0.12) }
    private var accessPolicy: AppAccessPolicy { accessStore.policy }
    
    var body: some View {
        NavigationStack {
            ZStack {
                settingsBackgroundColor.ignoresSafeArea()
                
                ScrollView {
                    VStack(spacing: 24) {
                        #if DEBUG || SOLIS_ENABLE_TEST_ACCESS_UI
                        debugAccessSection
                        #endif

                        purchaseSection

                        if accessPolicy.allows(.presets) {
                            presetSection
                        }

                        orderSection

                        if availableMeteringModes.contains(.spot) || accessPolicy.availableReflectiveMeteringModes.contains(.spot) {
                            SettingsSection(title: "スポット測光", refined: usesRefinedSettingsUI) {
                                SettingsRow(title: "基準にする場所", refined: usesRefinedSettingsUI) {
                                    Picker("測光基準", selection: $viewModel.spotMeteringReferenceTarget) {
                                        ForEach(SpotMeteringReferenceTarget.allCases) { target in
                                            Text(target.shortTitle).tag(target)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(settingsTintColor)
                                }

                                Text(viewModel.spotMeteringReferenceTarget.detailText)
                                    .font(.meterLabel(11))
                                    .foregroundColor(settingsSecondaryTextColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.bottom, 10)

                                Divider().background(settingsDividerColor)

                                SettingsToggle(title: "強い反射面で警告", isOn: $viewModel.spotBrightAreaWarningEnabled, refined: usesRefinedSettingsUI)

                                Text("ONのときは、水面、ガラス、金属、乱反射などの強い反射面を測った場合に警告します。")
                                    .font(.meterLabel(11))
                                    .foregroundColor(settingsSecondaryTextColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                                    .padding(.bottom, 10)

                                Divider().background(settingsDividerColor)

                                SettingsToggle(title: "基準外れを点で表示", isOn: $viewModel.spotOffTargetWarningEnabled, refined: usesRefinedSettingsUI)

                                Text("ONのときは左上の点で、OFFのときは小さなテキストで知らせます。")
                                    .font(.meterLabel(11))
                                    .foregroundColor(settingsSecondaryTextColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                                    .padding(.bottom, 10)

                                Divider().background(settingsDividerColor)

                                SettingsRow(title: "スポット補正", refined: usesRefinedSettingsUI) {
                                    Picker("スポット補正", selection: $viewModel.spotExposureBoostPreset) {
                                        ForEach(SpotMeteringExposureBoostPreset.allCases) { preset in
                                            Text(preset.shortLabel).tag(preset)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(settingsTintColor)
                                }

                                Text("スポット測光だけに適用します。現在: \(viewModel.spotExposureBoostPreset.detailText)")
                                    .font(.meterLabel(11))
                                    .foregroundColor(settingsSecondaryTextColor)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
                        }

                        SettingsSection(title: "表示設定", refined: usesRefinedSettingsUI) {
                            SettingsToggle(title: "EV値を表示", isOn: $viewModel.showEVValue, refined: usesRefinedSettingsUI)

                            Divider().background(settingsDividerColor)

                            SettingsRow(title: "UIモード", refined: usesRefinedSettingsUI) {
                                Text(accessPolicy.isFullVersion ? "通常版" : "補助テキスト版")
                                    .font(.meterValue(12))
                                    .foregroundColor(settingsSecondaryTextColor)
                            }

                            Text("ズーム表記、値カードの名称、測光モード名、詳細コントロール案内などを表示します。")
                                .font(.meterLabel(11))
                                .foregroundColor(settingsSecondaryTextColor)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)
                        }

                        SettingsSection(title: "デフォルト設定", refined: usesRefinedSettingsUI) {
                            SettingsRow(title: "ISO感度", refined: usesRefinedSettingsUI) {
                                Picker("ISO", selection: $viewModel.iso) {
                                    ForEach(viewModel.availableISOValues) { iso in
                                        Text("\(iso.rawValue)").tag(iso)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(settingsTintColor)
                            }

                            Divider().background(settingsDividerColor)

                            SettingsRow(title: "露出モード", refined: usesRefinedSettingsUI) {
                                SegmentedModePicker(
                                    selectedMode: $viewModel.exposureMode,
                                    refined: usesRefinedSettingsUI,
                                    forceLiquidGlass: true,
                                    compactLiquidGlass: true,
                                    colorlessLiquidGlass: true,
                                    prismaticLiquidGlass: true,
                                    availableModes: viewModel.availableExposureModes
                                )
                                .frame(width: 190)
                            }

                            Divider().background(settingsDividerColor)

                            SettingsRow(title: "測光モード", refined: usesRefinedSettingsUI) {
                                if availableMeteringModes.count > 1 {
                                    Picker("測光", selection: $viewModel.meteringMode) {
                                        ForEach(availableMeteringModes) { mode in
                                            Text(mode.displayName).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .tint(settingsTintColor)
                                } else {
                                    Text(viewModel.defaultMeteringMode(for: accessPolicy).displayName)
                                        .font(.meterValue(12))
                                        .foregroundColor(settingsSecondaryTextColor)
                                }
                            }
                        }
                        
                        if accessPolicy.allows(.pinholeMode) {
                            SettingsSection(title: "撮影設定", refined: usesRefinedSettingsUI) {
                                SettingsToggle(title: "ピンホール撮影", isOn: pinholeModeBinding, refined: usesRefinedSettingsUI)

                                HStack(alignment: .top, spacing: 8) {
                                    Text("ONにすると f/200・ISO 6 から開始します。F値はメイン画面で1単位調整できます。")
                                        .font(.meterLabel(11))
                                        .foregroundColor(settingsSecondaryTextColor)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Button {
                                        showPinholeFNumberHelp = true
                                    } label: {
                                        Image(systemName: "questionmark.circle.fill")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(settingsTintColor)
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Fナンバーの確認方法")
                                }
                                .padding(.top, 4)
                            }
                        }

                        SettingsSection(title: "フィードバック", refined: usesRefinedSettingsUI) {
                            SettingsToggle(title: "触覚フィードバック", isOn: $viewModel.enableHaptics, refined: usesRefinedSettingsUI)
                        }

                        calibrationSection
                        informationSection

                        Spacer(minLength: 40)
                    }
                    .padding()
                }

            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完了") {
                        finishSettingsAfterKeyboardDismissal()
                    }
                    .disabled(isFinishingDismissal)
                    .foregroundColor(settingsTextColor)
                }
            }
            .toolbarBackground(settingsBackgroundColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(usesRefinedSettingsUI ? .dark : .light, for: .navigationBar)
        }
        .preferredColorScheme(usesRefinedSettingsUI ? .dark : .light)
        .presentationBackground(settingsBackgroundColor)
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $showPresetManager) {
            presetManagerSheet
        }
        .alert("Fナンバーの確認方法", isPresented: $showPinholeFNumberHelp) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Fナンバーは「焦点距離 ÷ ピンホール径」で求めます。焦点距離は針穴からフィルム面までの距離、ピンホール径は穴の直径です。例: 焦点距離50mm、穴径0.3mmなら 50 ÷ 0.3 = f/167。径が小さいほどF値は大きくなり、露光時間は長くなります。")
        }
        .onChange(of: accessStore.accessLevel) { _, _ in
            viewModel.applyAccessPolicy(accessPolicy)
        }
    }

    #if DEBUG || SOLIS_ENABLE_TEST_ACCESS_UI
    private var debugAccessSection: some View {
        SettingsSection(title: "テスト確認用", refined: usesRefinedSettingsUI) {
            SettingsRow(title: "表示状態", refined: usesRefinedSettingsUI) {
                Picker("表示状態", selection: $accessStore.accessLevel) {
                    ForEach(AppAccessLevel.allCases) { level in
                        Text(level.displayName).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 176)
            }

            Text(accessStore.accessLevel.debugDescription)
                .font(.meterLabel(11))
                .foregroundColor(settingsSecondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
    }
    #endif

    private var presetManagerSheet: some View {
        PresetManagementView(
            sessionStore: sessionStore,
            refined: usesRefinedSettingsUI,
            onDismiss: {
                dismissKeyboard()
                showPresetManager = false
            }
        )
        .presentationDetents([.fraction(0.74), .large])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.clear)
        .preferredColorScheme(usesRefinedSettingsUI ? .dark : .light)
        .ignoresSafeArea(.keyboard)
    }

    private func finishSettingsAfterKeyboardDismissal() {
        guard !isFinishingDismissal else { return }

        isFinishingDismissal = true
        dismissKeyboard()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            viewModel.saveSettings()
            if let onDismiss {
                onDismiss()
            } else {
                dismiss()
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - キャリブレーション — 基準EV入力による自動補正 + 手動±調整

    private var calibrationSection: some View {
        let isIncident = viewModel.isIncidentMode
        let currentOffset = cameraManager.calibrationOffset
        let modeLabel = isIncident ? "入射光" : "反射光"

        return SettingsSection(title: "キャリブレーション（\(modeLabel)）", refined: usesRefinedSettingsUI) {
            VStack(alignment: .leading, spacing: 14) {
                // 現在の測定値
                HStack {
                    Text("現在の測定EV")
                        .font(.meterLabel(12))
                        .foregroundColor(settingsTextColor)
                    Spacer()
                    Text(String(format: "%.1f", viewModel.measuredEV))
                        .font(.meterValue(14))
                        .foregroundColor(settingsTextColor)
                        .monospacedDigit()
                }

                Divider().background(settingsDividerColor)

                // 基準値入力 → 自動オフセット計算
                VStack(alignment: .leading, spacing: 8) {
                    Text("基準露出計のEV値を入力")
                        .font(.meterLabel(11))
                        .foregroundColor(settingsSecondaryTextColor)

                    HStack(spacing: 10) {
                        TextField("EV", text: $referenceEV)
                            .font(.meterValue(14))
                            .foregroundColor(settingsTextColor)
                            .keyboardType(.decimalPad)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(settingsCardColor)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(settingsStrokeColor, lineWidth: 0.5))
                            )
                            .frame(width: 90)

                        Button {
                            applyReferenceCalibration()
                        } label: {
                            Text("適用")
                                .font(.meterValue(11))
                                .foregroundColor(settingsPrimaryButtonText)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 3).fill(settingsPrimaryButtonFill))
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }

                Divider().background(settingsDividerColor)

                // 手動微調整
                VStack(alignment: .leading, spacing: 8) {
                    Text("手動調整")
                        .font(.meterLabel(11))
                        .foregroundColor(settingsSecondaryTextColor)

                    HStack {
                        Text("オフセット")
                            .font(.meterLabel(12))
                            .foregroundColor(settingsTextColor)
                        Spacer()
                        Text(String(format: "%+.2f EV", currentOffset))
                            .font(.meterValue(14))
                            .foregroundColor(settingsTextColor)
                            .monospacedDigit()
                    }

                    HStack(spacing: 8) {
                        calibrationButton(label: "-1", delta: -1.0)
                        calibrationButton(label: "-⅓", delta: -1.0 / 3.0)
                        calibrationButton(label: "+⅓", delta: 1.0 / 3.0)
                        calibrationButton(label: "+1", delta: 1.0)
                        Spacer()
                        Button {
                            cameraManager.setCalibrationOffset(0, forIncident: isIncident)
                        } label: {
                            Text("リセット")
                                .font(.meterLabel(10))
                                .foregroundColor(.meterRed)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.meterRed.opacity(0.1))
                                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.meterRed.opacity(0.3), lineWidth: 0.5))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func calibrationButton(label: String, delta: Double) -> some View {
        let isIncident = viewModel.isIncidentMode
        return Button {
            let newOffset = cameraManager.calibrationOffset + delta
            cameraManager.setCalibrationOffset(newOffset, forIncident: isIncident)
            if viewModel.enableHaptics { HapticManager.shared.selectionChanged() }
        } label: {
            Text(label)
                .font(.meterValue(11))
                .foregroundColor(settingsTextColor)
                .frame(width: 44, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(usesRefinedSettingsUI ? Color.refinedPanel : Color.meterButtonBg)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(settingsStrokeColor, lineWidth: 0.5))
                )
        }
        .buttonStyle(.plain)
    }

    private func applyReferenceCalibration() {
        guard let referenceValue = Double(referenceEV) else { return }
        let isIncident = viewModel.isIncidentMode
        let currentMeasured = viewModel.measuredEV
        let currentOffset = cameraManager.calibrationOffset
        // 基準値と現在の測定値の差分をオフセットに加算
        // 現在のEV = 真のEV + currentOffset なので、
        // 新しいオフセット = currentOffset + (referenceValue - currentMeasured)
        let newOffset = currentOffset + (referenceValue - currentMeasured)
        cameraManager.setCalibrationOffset(newOffset, forIncident: isIncident)
        referenceEV = ""
        if viewModel.enableHaptics { HapticManager.shared.success() }
    }

    private var informationSection: some View {
        SettingsSection(title: "情報", refined: usesRefinedSettingsUI) {
            NavigationLink {
                PrivacyPolicyView(refined: usesRefinedSettingsUI)
            } label: {
                HStack(spacing: 12) {
                    Text("プライバシーポリシー")
                        .font(.meterLabel(13))
                        .foregroundColor(settingsTextColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(settingsSecondaryTextColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .buttonStyle(.plain)
        }
    }

    private var purchaseSection: some View {
        SettingsSection(title: "完全版", refined: usesRefinedSettingsUI) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: accessPolicy.isFullVersion ? "checkmark.seal.fill" : "lock.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(accessPolicy.isFullVersion ? .meterGreen : settingsTintColor)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(accessPolicy.isFullVersion ? "完全版が有効です" : "無料版で利用中")
                            .font(.meterValue(13))
                            .foregroundColor(settingsTextColor)
                        Text(accessPolicy.isFullVersion ? "すべての測光機能と撮影記録が使えます。" : "完全版で高度な測光、入射光測定、撮影記録を解放できます。")
                            .font(.meterLabel(10))
                            .foregroundColor(settingsSecondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 0)
                }

                if !accessPolicy.isFullVersion {
                    purchaseButton(for: .monthly, systemImage: "calendar")
                    purchaseButton(for: .lifetime, systemImage: "sparkles")
                }

                Button {
                    if viewModel.enableHaptics { HapticManager.shared.lightTap() }
                    accessStore.restorePurchases()
                } label: {
                    Label("購入を復元", systemImage: "arrow.clockwise")
                        .font(.meterLabel(12))
                        .foregroundColor(settingsTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.clear)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(settingsStrokeColor, lineWidth: 1))
                        )
                }
                .buttonStyle(.plain)
                .disabled(accessStore.isPurchaseActionInProgress)

                if accessStore.isPurchaseActionInProgress {
                    HStack(spacing: 8) {
                        ProgressView()
                            .tint(settingsTintColor)
                        Text("RevenueCatで購入状態を確認しています")
                            .font(.meterLabel(10))
                            .foregroundColor(settingsSecondaryTextColor)
                    }
                    .padding(.top, 2)
                }

                if let message = accessStore.purchaseStatusMessage {
                    Text(message)
                        .font(.meterLabel(10))
                        .foregroundColor(settingsSecondaryTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func purchaseButton(for plan: FullVersionPurchasePlan, systemImage: String) -> some View {
        Button {
            if viewModel.enableHaptics { HapticManager.shared.lightTap() }
            accessStore.purchaseFullVersion(plan: plan)
        } label: {
            Label(accessStore.activePurchasePlan == plan ? "処理中..." : plan.buttonTitle, systemImage: systemImage)
                .font(.meterValue(12))
                .foregroundColor(settingsPrimaryButtonText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(settingsPrimaryButtonFill))
        }
        .buttonStyle(.plain)
        .disabled(accessStore.isPurchaseActionInProgress)
    }

    private var presetSection: some View {
        SettingsSection(title: "プリセット", refined: usesRefinedSettingsUI) {
            VStack(alignment: .leading, spacing: 12) {
                if let activePreset = sessionStore.activePreset {
                    HStack(spacing: 8) {
                        Text("使用中")
                            .font(.meterLabel(10))
                            .foregroundColor(settingsPrimaryButtonText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(settingsPrimaryButtonFill))
                        presetTextBlock(
                            for: activePreset,
                            index: sessionStore.presets.firstIndex(of: activePreset).map { $0 + 1 } ?? 1,
                            textSize: 11,
                            numberSize: 16
                        )
                    }
                } else {
                    Text("使用中のプリセット: なし")
                        .font(.meterLabel(11))
                        .foregroundColor(settingsSecondaryTextColor)
                }

                presetListCard

                Button("プリセットを管理") {
                    showPresetManager = true
                }
                .font(.meterLabel(12))
                .foregroundColor(settingsTextColor)

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private var orderSection: some View {
        VStack(spacing: 0) {
            if let planURL = sessionStore.orderPageURL {
                Link(destination: planURL) {
                    Text("ナツソマレフォトグラフ現像データ化の注文ページ")
                        .font(.meterValue(13))
                        .foregroundColor(settingsPrimaryButtonText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 12).fill(settingsPrimaryButtonFill))
                }
            }
        }
    }

    private var presetListCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if sessionStore.presets.isEmpty {
                Text("登録済みプリセットはありません")
                    .font(.meterLabel(12))
                    .foregroundColor(settingsSecondaryTextColor)
            } else {
                ForEach(Array(sessionStore.presets.enumerated()), id: \.element.id) { index, preset in
                    let isActive = sessionStore.selectedPresetID == preset.id
                    VStack(spacing: 0) {
                        HStack(alignment: .top, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(isActive ? (usesRefinedSettingsUI ? Color.refinedText : Color.meterSecondary) : Color.clear)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 4)

                                VStack(alignment: .leading, spacing: 4) {
                                    presetTextBlock(
                                        for: preset,
                                        index: index + 1,
                                        textSize: 11,
                                        numberSize: 15
                                    )
                                    Text(preset.formattedDate)
                                        .font(.meterLabel(10))
                                        .foregroundColor(settingsSecondaryTextColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            VStack(alignment: .trailing, spacing: 6) {
                                Button {
                                    sessionStore.selectPreset(id: preset.id)
                                } label: {
                                    presetActionChip(
                                        title: isActive ? "選択済み" : "使用する",
                                        systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle",
                                        foregroundColor: usesRefinedSettingsUI ? .refinedText : .meterSecondary,
                                        backgroundColor: isActive ? settingsPrimaryButtonFill : Color.clear,
                                        borderColor: settingsStrokeColor,
                                        borderLineWidth: isActive ? 0 : 1
                                    )
                                }
                                .disabled(isActive)

                                Button {
                                    preset.copyToClipboard(index: index + 1)
                                    withAnimation { copiedPresetID = preset.id }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        withAnimation { if copiedPresetID == preset.id { copiedPresetID = nil } }
                                    }
                                } label: {
                                    let isCopied = copiedPresetID == preset.id
                                    presetActionChip(
                                        title: isCopied ? "コピー済み" : "コピー",
                                        systemImage: isCopied ? "checkmark" : "doc.on.doc",
                                        foregroundColor: usesRefinedSettingsUI ? .refinedText : .meterSecondary,
                                        backgroundColor: isCopied ? Color.meterGreen : Color.clear,
                                        borderColor: isCopied ? Color.white.opacity(0.2) : settingsStrokeColor,
                                        borderLineWidth: isCopied ? 0 : 1
                                    )
                                }
                            }
                            .frame(width: 104, alignment: .trailing)
                        }
                        .padding(.vertical, 3)

                        if index != sessionStore.presets.count - 1 {
                            Divider()
                                .background(settingsDividerColor)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(settingsCardColor)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(settingsStrokeColor, lineWidth: 0.5))
        )
    }

    private func presetActionChip(
        title: String,
        systemImage: String,
        foregroundColor: Color,
        backgroundColor: Color,
        borderColor: Color,
        borderLineWidth: CGFloat
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.meterLabel(10))
            .foregroundColor(foregroundColor)
            .frame(width: 104)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(borderColor, lineWidth: borderLineWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private func presetTextBlock(
        for preset: CameraFilmPreset,
        index: Int,
        textSize: CGFloat,
        numberSize: CGFloat
    ) -> some View {
        let lines = preset.displayLines
        let symbol = preset.displayIndexSymbol(index: index)
        let numberColumnWidth = numberSize + 4

        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(symbol)
                    .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                    .foregroundColor(settingsTextColor)
                    .frame(width: numberColumnWidth, alignment: .leading)

                Text(lines[0])
                    .font(.system(size: textSize, weight: .medium, design: .monospaced))
                    .foregroundColor(settingsTextColor)
            }

            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: textSize, weight: .medium, design: .monospaced))
                    .foregroundColor(settingsTextColor)
                    .padding(.leading, numberColumnWidth + 8)
            }
        }
    }
}

private struct PrivacyPolicyView: View {
    let refined: Bool
    private let document = PrivacyPolicyDocument.current

    private var backgroundColor: Color {
        refined ? .refinedBackground : .meterBackground
    }

    private var textColor: Color {
        refined ? .refinedText : .meterSecondary
    }

    private var secondaryTextColor: Color {
        refined ? .refinedTextSoft : .meterSecondary.opacity(0.78)
    }

    private var accentColor: Color {
        refined ? .cyan : .meterAccent
    }

    private var cardColor: Color {
        refined ? .refinedSurface : .meterCardBg
    }

    private var strokeColor: Color {
        refined ? .refinedStroke.opacity(0.8) : Color.black.opacity(0.12)
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(document.title)
                            .font(.meterValue(18))
                            .foregroundColor(textColor)

                        Text(document.intro)
                            .font(.meterLabel(12))
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(document.updatedDate)
                            .font(.meterLabel(10))
                            .foregroundColor(accentColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .fill(accentColor.opacity(refined ? 0.18 : 0.12))
                            )
                    }

                    ForEach(Array(document.sections.enumerated()), id: \.offset) { index, section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.title)
                                .font(.meterValue(13))
                                .foregroundColor(textColor)

                            ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                                Text(paragraph)
                                    .font(.meterLabel(12))
                                    .foregroundColor(section.usesSecondaryTone ? secondaryTextColor : textColor)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if !section.bullets.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(section.bullets.enumerated()), id: \.offset) { _, bullet in
                                        HStack(alignment: .top, spacing: 8) {
                                            Text("・")
                                                .font(.meterLabel(12))
                                                .foregroundColor(accentColor)
                                            Text(bullet)
                                                .font(.meterLabel(12))
                                                .foregroundColor(textColor)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }

                            if let link = section.link {
                                Link(destination: link.url) {
                                    Text(link.title)
                                        .font(.meterLabel(12))
                                        .foregroundColor(accentColor)
                                        .underline()
                                }
                            }

                            if index != document.sections.count - 1 {
                                Divider()
                                    .background(strokeColor)
                                    .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 18)
                        .fill(cardColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(strokeColor, lineWidth: 0.5)
                        )
                )
                .padding(16)
            }
        }
        .navigationTitle("プライバシーポリシー")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(backgroundColor, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(refined ? .dark : .light, for: .navigationBar)
    }
}

private struct PrivacyPolicyDocument {
    let title: String
    let intro: String
    let updatedDate: String
    let sections: [PrivacyPolicySection]

    static let current = PrivacyPolicyDocument(
        title: "Solis film meter プライバシーポリシー",
        intro: "Solis film meter（以下「本アプリ」）は、利用者のプライバシーを尊重し、取得する情報、その利用目的、および管理方法を以下のとおり定めます。",
        updatedDate: "改定日: 2026年3月19日",
        sections: [
            PrivacyPolicySection(
                title: "1. 取得する情報",
                paragraphs: ["本アプリは、提供機能に応じて以下の情報を取り扱います。"],
                bullets: [
                    "カメラ情報: 露出測定のため、端末のカメラ映像を利用します。",
                    "写真ライブラリへの追加保存: 撮影記録やコラージュ画像を端末の写真ライブラリへ保存する際に利用します。",
                    "アプリ内設定情報: ISO設定、露出モード、測光モード、キャリブレーション値、各種表示設定などを端末内に保存します。",
                    "撮影補助情報: カメラボディ名、レンズ情報、フィルム名、撮影記録、保存画像の参照情報などを端末内に保存します。",
                    "利用状況情報: 初回起動済みかどうか、起動回数、案内ポップアップの表示抑制状態などを端末内に保存します。"
                ]
            ),
            PrivacyPolicySection(
                title: "2. 情報の利用目的",
                bullets: [
                    "被写体の明るさを測定し、露出値および撮影条件の目安を表示するため",
                    "利用者が入力したカメラ・レンズ・フィルムの組み合わせを保存し、次回以降の利用を容易にするため",
                    "撮影記録の保存、表示、管理を行うため",
                    "アプリ設定や案内表示の状態を保持し、継続利用時の操作性を高めるため"
                ]
            ),
            PrivacyPolicySection(
                title: "3. カメラ情報の取り扱い",
                paragraphs: [
                    "本アプリは、露出測定機能の提供のためにカメラを使用します。カメラ映像は主として端末内で処理され、露出計算およびプレビュー表示に利用されます。",
                    "カメラ映像自体を本アプリの運営者が収集・保存することはありません。"
                ]
            ),
            PrivacyPolicySection(
                title: "4. 写真ライブラリの取り扱い",
                paragraphs: [
                    "本アプリは、利用者が保存操作を行った場合に限り、撮影記録画像等を端末の写真ライブラリへ追加保存します。",
                    "本アプリは写真ライブラリから既存の写真を読み取ることを主目的としていません。"
                ]
            ),
            PrivacyPolicySection(
                title: "5. 外部サイトの利用について",
                paragraphs: [
                    "本アプリから外部サイト（注文ページ、お問い合わせ先、プライバシーポリシーに記載の関連ページ等）を開いた場合、その先のサイトにおける情報の取り扱いは各サイトの定めによります。",
                    "本アプリは、外部サイト上で利用者が入力した情報を本アプリ内へ保存しません。"
                ]
            ),
            PrivacyPolicySection(
                title: "6. 端末内保存について",
                paragraphs: [
                    "本アプリは、設定値、キャリブレーション値、プリセット、撮影記録などを、利用者の端末内に保存します。",
                    "これらは本アプリの利便性向上および継続利用のために使用されます。"
                ]
            ),
            PrivacyPolicySection(
                title: "7. 第三者提供",
                paragraphs: ["本アプリは、法令に基づく場合を除き、利用者の個人情報を第三者へ提供しません。"]
            ),
            PrivacyPolicySection(
                title: "8. 解析・広告・トラッキング",
                paragraphs: ["本アプリは、広告配信を目的としたトラッキングを行いません。また、本プライバシーポリシー制定日時点において、広告識別子を利用した行動追跡は行っていません。"]
            ),
            PrivacyPolicySection(
                title: "9. 情報の管理および削除",
                bullets: [
                    "端末内に保存された設定や撮影記録は、利用者の操作またはアプリの削除により削除されることがあります。",
                    "写真ライブラリへ保存された画像は、端末の写真アプリ等から利用者自身で削除できます。"
                ]
            ),
            PrivacyPolicySection(
                title: "10. 未成年の利用について",
                paragraphs: ["本アプリは、未成年者による利用を特に制限していませんが、必要に応じて保護者の同意のもとで利用してください。"]
            ),
            PrivacyPolicySection(
                title: "11. 改定",
                paragraphs: ["本プライバシーポリシーは、法令改正や機能変更等に応じて改定されることがあります。重要な変更がある場合は、適切な方法で周知します。"]
            ),
            PrivacyPolicySection(
                title: "12. お問い合わせ先",
                paragraphs: ["本アプリに関するお問い合わせは、以下のサイトよりご確認ください。"],
                link: PrivacyPolicyLink(title: "https://filmshop.natsusomare.jp/", url: URL(string: "https://filmshop.natsusomare.jp/")!),
                usesSecondaryTone: true
            )
        ]
    )
}

private struct PrivacyPolicySection {
    let title: String
    var paragraphs: [String] = []
    var bullets: [String] = []
    var link: PrivacyPolicyLink? = nil
    var usesSecondaryTone: Bool = false
}

private struct PrivacyPolicyLink {
    let title: String
    let url: URL
}

struct SettingsSection<Content: View>: View {
    let title: String
    var refined: Bool = true
    @ViewBuilder let content: Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.meterLabel(12)).foregroundColor(refined ? .refinedText : .meterSecondary).textCase(.uppercase)
            VStack(spacing: 0) { content }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(refined ? Color.refinedSurface : Color.meterCardBg)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(refined ? Color.refinedStroke : Color.black.opacity(0.12), lineWidth: 0.5))
                )
        }
    }
}

struct SettingsRow<Content: View>: View {
    let title: String
    var refined: Bool = true
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack {
            Text(title).font(.meterLabel(14)).foregroundColor(refined ? .refinedText : .meterSecondary)
            Spacer()
            content
        }
        .padding(.vertical, 8)
    }
}

struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var refined: Bool = true
    
    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).font(.meterLabel(14)).foregroundColor(refined ? .refinedText : .meterSecondary)
        }
        .tint(refined ? .cyan : .meterAccent)
        .padding(.vertical, 4)
    }
}
