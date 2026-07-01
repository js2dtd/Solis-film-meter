// MARK: - 役割: レンズ・フィルムのプリセット管理画面
// MARK: - 目次
// 1. PresetManagementViewのシートレイアウト
// 2. カメラ/レンズ/フィルム入力フォーム
// 3. 単焦点/ズーム設定と焦点距離ガイド
// 4. 登録済みプリセット一覧とアクションチップ
// 5. 選択・編集・コピー・削除・完了時保存

import SwiftUI

struct PresetManagementView: View {
    @ObservedObject var sessionStore: AppSessionStore
    var refined: Bool = true
    var onDismiss: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var editingPresetID: UUID?
    @State private var cameraBody: String = ""
    @State private var lensDetails: String = ""
    @State private var isZoomLens: Bool = false
    @State private var primeFocalLengthText: String = ""
    @State private var film: String = ""
    @State private var date: Date = Date()
    @State private var copiedPresetID: UUID?
    @State private var isFinishingDismissal = false

    private let title = "プリセット管理"
    private let description = "新規登録または変更があれば更新してください。"
    private let windowContentInset: CGFloat = 10
    private var backgroundColor: Color { refined ? .refinedBackground : .meterBackground }
    private var surfaceColor: Color { refined ? .refinedSurface : .meterCardBg }
    private var panelColor: Color { refined ? .refinedPanel : .meterAccent }
    private var primaryTextColor: Color { refined ? .refinedText : .meterSecondary }
    private var secondaryTextColor: Color { refined ? .refinedTextSoft : .meterSecondary.opacity(0.72) }
    private var strokeColor: Color { refined ? .refinedStroke : Color.black.opacity(0.12) }
    private var toggleTintColor: Color { refined ? .cyan : .meterAccent }
    private var pickerTintColor: Color { refined ? .refinedText : .meterSecondary }
    private var activeIndicatorColor: Color { refined ? .refinedText : .meterSecondary }
    private var chipForegroundColor: Color { refined ? .refinedText : .meterSecondary }
    private var copiedChipBorderColor: Color { refined ? Color.white.opacity(0.2) : Color.black.opacity(0.08) }
    private var windowShadowColor: Color { Color.black.opacity(refined ? 0.46 : 0.24) }
    private var windowStrokeColor: Color { refined ? Color.white.opacity(0.13) : Color.black.opacity(0.10) }
    private var fullscreenWideEndGuideText: String {
        "全画面時の最広角は約\(LensFocalLengthGuide.fullscreenWideEndEquivalentFocalLength)mm相当です"
    }

    var body: some View {
        manageBody
        .preferredColorScheme(refined ? .dark : .light)
    }

    private var manageBody: some View {
        ZStack {
            Color.clear.ignoresSafeArea()

            VStack(spacing: 0) {
                customDragIndicator

                manageHeader

                Divider()
                    .background(strokeColor)

                GeometryReader { geometry in
                    ScrollView {
                        contentStack
                            .padding()
                            .frame(width: geometry.size.width)
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(backgroundColor)
                    .shadow(color: windowShadowColor, radius: 30, x: 0, y: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(windowStrokeColor, lineWidth: 0.8)
            )
            .padding(windowContentInset)
        }
    }

    private var customDragIndicator: some View {
        Capsule(style: .continuous)
            .fill(refined ? Color.white.opacity(0.28) : Color.black.opacity(0.22))
            .frame(width: 54, height: 6)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var manageHeader: some View {
        HStack(spacing: 16) {
            Spacer(minLength: 72)

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(primaryTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Spacer(minLength: 12)

            Button("完了") {
                handleDismiss()
            }
            .disabled(isFinishingDismissal)
            .font(.meterValue(14))
            .foregroundColor(primaryTextColor)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background {
                Capsule(style: .continuous)
                    .fill(refined ? Color.refinedPanelSoft.opacity(0.82) : Color.meterSurface)
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(refined ? Color.white.opacity(0.16) : Color.black.opacity(0.12), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .background(backgroundColor)
    }

    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(description)
                .font(.meterLabel(12))
                .foregroundColor(secondaryTextColor)

            formCard
            presetListCard
        }
    }

    private var formCard: some View {
        VStack(spacing: 10) {
            TextField("カメラボディ", text: $cameraBody)
                .textInputAutocapitalization(.words)
                .textFieldStyle(.roundedBorder)

            TextField("レンズ詳細（メーカー・型番など）", text: $lensDetails)
                .textInputAutocapitalization(.words)
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $isZoomLens) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ズームレンズ")
                        .font(.meterLabel(12))
                        .foregroundColor(primaryTextColor)
                    Text("オンでワイド端から全画面ピンチズーム、オフで単焦点画角に固定")
                        .font(.meterLabel(10))
                        .foregroundColor(secondaryTextColor)
                }
            }
            .toggleStyle(.switch)
            .tint(toggleTintColor)

            Text("\(fullscreenWideEndGuideText)。これより広角の焦点距離には設定できません。プリセット未選択時とズームプリセットは、この画角から起動します。")
                .font(.meterLabel(10))
                .foregroundColor(secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("フィルム", text: $film)
                .textInputAutocapitalization(.words)
                .textFieldStyle(.roundedBorder)

            if !isZoomLens {
                HStack {
                    TextField("焦点距離 例: 50", text: $primeFocalLengthText)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                    Spacer(minLength: 0)
                }

                Text("全画面表示で合わせたい35mm換算の焦点距離を入力してください。約\(LensFocalLengthGuide.fullscreenWideEndEquivalentFocalLength)mmより広角にはならず、未入力の場合は最広角で起動します。")
                    .font(.meterLabel(10))
                    .foregroundColor(secondaryTextColor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            DatePicker("日付", selection: $date, displayedComponents: .date)
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "ja_JP"))
                .font(.meterLabel(13))
                .foregroundColor(primaryTextColor)
                .tint(pickerTintColor)

            Text(editingPresetID == nil ? "入力後は「完了」で保存して使用します。" : "編集内容は「完了」で更新して使用します。")
                .font(.meterLabel(10))
                .foregroundColor(secondaryTextColor)
                .frame(maxWidth: .infinity, alignment: .leading)

            if editingPresetID != nil {
                Button("編集をキャンセル") {
                    clearForm()
                }
                .font(.meterLabel(12))
                .foregroundColor(secondaryTextColor)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(surfaceColor)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(strokeColor, lineWidth: 0.5))
        )
    }

    private var presetListCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if sessionStore.presets.isEmpty {
                Text("まだプリセットがありません")
                    .font(.meterLabel(12))
                    .foregroundColor(secondaryTextColor)
            } else {
                ForEach(Array(sessionStore.presets.enumerated()), id: \.element.id) { index, preset in
                    let isActive = sessionStore.selectedPresetID == preset.id
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top) {
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(isActive ? activeIndicatorColor : Color.clear)
                                    .frame(width: 8, height: 8)
                                    .padding(.top, 5)

                                VStack(alignment: .leading, spacing: 4) {
                                    presetTextBlock(
                                        for: preset,
                                        index: index + 1,
                                        textSize: 13,
                                        numberSize: 18
                                    )
                                    Text(preset.formattedDate)
                                        .font(.meterLabel(11))
                                        .foregroundColor(secondaryTextColor)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

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
                                    foregroundColor: chipForegroundColor,
                                    backgroundColor: isCopied ? Color.meterGreen : Color.clear,
                                    borderColor: isCopied ? copiedChipBorderColor : strokeColor,
                                    borderLineWidth: isCopied ? 0 : 1
                                )
                            }
                        }

                        HStack {
                            Button {
                                sessionStore.selectPreset(id: preset.id)
                            } label: {
                                presetActionChip(
                                    title: isActive ? "選択済み" : "使用する",
                                    systemImage: isActive ? "checkmark.circle.fill" : "checkmark.circle",
                                    foregroundColor: chipForegroundColor,
                                    backgroundColor: isActive ? panelColor : Color.clear,
                                    borderColor: strokeColor,
                                    borderLineWidth: isActive ? 0 : 1
                                )
                            }
                            .disabled(isActive)

                            Spacer()

                            Button("編集") {
                                editingPresetID = preset.id
                                cameraBody = preset.cameraBody
                                lensDetails = preset.lensDetailsText
                                isZoomLens = preset.lensType == .zoom
                                primeFocalLengthText = preset.primeFocalLength35mm.map(String.init) ?? ""
                                film = preset.film
                                date = preset.date
                            }
                            .font(.meterLabel(11))
                            .foregroundColor(secondaryTextColor)

                            Button("削除", role: .destructive) {
                                sessionStore.deletePreset(id: preset.id)
                            }
                            .font(.meterLabel(11))
                        }
                    }
                    .padding(.vertical, 4)

                    if index != sessionStore.presets.count - 1 {
                        Divider().background(strokeColor)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(surfaceColor)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(strokeColor, lineWidth: 0.5))
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
            .font(.meterLabel(11))
            .foregroundColor(foregroundColor)
            .frame(width: 108)
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
                    .foregroundColor(primaryTextColor)
                    .frame(width: numberColumnWidth, alignment: .leading)

                Text(lines[0])
                    .font(.system(size: textSize, weight: .medium, design: .monospaced))
                    .foregroundColor(primaryTextColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            ForEach(Array(lines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.system(size: textSize, weight: .medium, design: .monospaced))
                    .foregroundColor(primaryTextColor)
                    .padding(.leading, numberColumnWidth + 8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private func clearForm() {
        editingPresetID = nil
        cameraBody = ""
        lensDetails = ""
        isZoomLens = false
        primeFocalLengthText = ""
        film = ""
        date = Date()
    }

    private var parsedPrimeFocalLength: Int? {
        let trimmed = primeFocalLengthText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Int(trimmed)
    }

    private var hasPendingPresetInput: Bool {
        let normalizedCamera = cameraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLens = lensDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilm = film.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasLensInfo = isZoomLens || parsedPrimeFocalLength != nil || !normalizedLens.isEmpty
        return editingPresetID != nil || !normalizedCamera.isEmpty || hasLensInfo || !normalizedFilm.isEmpty
    }

    private func handleDismiss() {
        guard !isFinishingDismissal else { return }

        isFinishingDismissal = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            finishDismiss()
        }
    }

    private func finishDismiss() {
        if hasPendingPresetInput {
            sessionStore.upsertPreset(
                editingID: editingPresetID,
                cameraBody: cameraBody,
                lens: lensDetails,
                lensType: isZoomLens ? .zoom : .prime,
                primeFocalLength35mm: parsedPrimeFocalLength,
                film: film,
                date: date
            )
        }

        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}
