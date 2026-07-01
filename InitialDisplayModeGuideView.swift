// MARK: - 役割: 初回起動時の表示スタイル選択ガイド
// MARK: - 目次
// 1. InitialDisplayModeGuideView本体
// 2. Streamlined/Assisted表示スタイルカード
// 3. 選択状態、説明、フッターアクション
// 4. DisplayStyleChoice定義

import SwiftUI

struct InitialDisplayModeGuideView: View {
    @ObservedObject var viewModel: ExposureViewModel
    @Binding var isPresented: Bool
    @State private var selectedStyle: DisplayStyleChoice

    init(viewModel: ExposureViewModel, isPresented: Binding<Bool>) {
        self.viewModel = viewModel
        self._isPresented = isPresented
        self._selectedStyle = State(
            initialValue: viewModel.showAuxiliaryLabels ? .assisted : .streamlined
        )
    }

    private var usesRefinedInterface: Bool {
        !selectedStyle.showsAuxiliaryLabels
    }

    private var backgroundColor: Color {
        usesRefinedInterface ? .refinedBackground : .meterBackground
    }

    private var heroGlowColor: Color {
        usesRefinedInterface ? .cyan.opacity(0.2) : .meterAccent.opacity(0.16)
    }

    private var cardColor: Color {
        usesRefinedInterface ? .refinedSurface : .meterCardBg
    }

    private var accentColor: Color {
        usesRefinedInterface ? .cyan : .meterAccent
    }

    private var strokeColor: Color {
        usesRefinedInterface ? .refinedStroke.opacity(0.9) : Color.black.opacity(0.12)
    }

    private var primaryTextColor: Color {
        usesRefinedInterface ? .refinedText : .meterSecondary
    }

    private var secondaryTextColor: Color {
        usesRefinedInterface ? .refinedTextSoft : .meterSecondary.opacity(0.72)
    }

    private var buttonFillColor: Color {
        usesRefinedInterface ? .refinedPanel : .meterAccent
    }

    private var buttonTextColor: Color {
        usesRefinedInterface ? .refinedTextOnDark : .black
    }

    var body: some View {
        ZStack {
            backgroundColor.ignoresSafeArea()

            decorativeBackground

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    heroSection
                    styleSelectionSection
                    footerNote
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 140)
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .interactiveDismissDisabled()
        .preferredColorScheme(usesRefinedInterface ? .dark : .light)
    }

    private var decorativeBackground: some View {
        ZStack {
            Circle()
                .fill(heroGlowColor)
                .frame(width: 260, height: 260)
                .blur(radius: 18)
                .offset(x: 120, y: -220)

            Circle()
                .fill(accentColor.opacity(0.12))
                .frame(width: 220, height: 220)
                .blur(radius: 30)
                .offset(x: -150, y: 260)
        }
        .allowsHitTesting(false)
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("WELCOME")
                .font(.meterLabel(10))
                .tracking(2)
                .foregroundColor(accentColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(accentColor.opacity(usesRefinedInterface ? 0.18 : 0.12))
                )

            VStack(alignment: .leading, spacing: 10) {
                Text("Solis film meter")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundColor(primaryTextColor)

                Text("最初に表示スタイルを選ぶと、起動直後から自分に合った見え方で使い始められます。")
                    .font(.meterLabel(13))
                    .foregroundColor(secondaryTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var styleSelectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("どちらの表示で始めますか")
                .font(.meterValue(14))
                .foregroundColor(primaryTextColor)

            VStack(spacing: 14) {
                selectionCard(for: .assisted)
                selectionCard(for: .streamlined)
            }
        }
    }

    private func selectionCard(for style: DisplayStyleChoice) -> some View {
        let isSelected = selectedStyle == style

        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedStyle = style
            }
            if viewModel.enableHaptics {
                HapticManager.shared.selectionChanged()
            }
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(style.title)
                            .font(.meterValue(14))
                            .foregroundColor(primaryTextColor)

                        Text(style.description)
                            .font(.meterLabel(11))
                            .foregroundColor(secondaryTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(isSelected ? style.previewAccent : secondaryTextColor.opacity(0.7))
                }

                HStack(spacing: 10) {
                    styleFeatureChip(title: style.featureLine1, accent: style.previewAccent)
                    styleFeatureChip(title: style.featureLine2, accent: style.previewAccent)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22)
                    .fill(cardColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 22)
                            .stroke(
                                isSelected ? style.previewAccent.opacity(0.7) : strokeColor,
                                lineWidth: isSelected ? 1.4 : 0.5
                            )
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 22))
        }
        .buttonStyle(.plain)
    }

    private func styleFeatureChip(title: String, accent: Color) -> some View {
        Text(title)
            .font(.meterLabel(9))
            .foregroundColor(primaryTextColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(accent.opacity(0.12))
            )
    }

    private var footerNote: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("あとで変更できます")
                .font(.meterValue(12))
                .foregroundColor(primaryTextColor)

            Text("設定 > 表示設定 > 補助テキストを表示 から、いつでも切り替えられます。")
                .font(.meterLabel(11))
                .foregroundColor(secondaryTextColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(cardColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(strokeColor, lineWidth: 0.5)
                )
        )
    }

    private var bottomActionBar: some View {
        VStack(spacing: 10) {
            Button {
                startApp()
            } label: {
                Text(selectedStyle.startButtonTitle)
                    .font(.meterValue(14))
                    .foregroundColor(buttonTextColor)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(buttonFillColor)
                    )
            }
            .buttonStyle(.plain)

            Text("初回設定はここで保存されます。")
                .font(.meterLabel(10))
                .foregroundColor(secondaryTextColor)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .background(
            Rectangle()
                .fill(backgroundColor.opacity(0.96))
                .ignoresSafeArea()
        )
    }

    private func startApp() {
        viewModel.showAuxiliaryLabels = selectedStyle.showsAuxiliaryLabels
        viewModel.markDisplayModeGuideSeenIfNeeded()
        viewModel.saveSettings()
        if viewModel.enableHaptics {
            HapticManager.shared.success()
        }
        isPresented = false
    }
}

private enum DisplayStyleChoice: CaseIterable {
    case assisted
    case streamlined

    var showsAuxiliaryLabels: Bool {
        self == .assisted
    }

    var title: String {
        switch self {
        case .assisted:
            return "補助テキスト版"
        case .streamlined:
            return "通常版"
        }
    }

    var shortTag: String {
        switch self {
        case .assisted:
            return "GUIDED"
        case .streamlined:
            return "MINIMAL"
        }
    }

    var description: String {
        switch self {
        case .assisted:
            return "ラベルや説明を表示して、今どこを見ればいいか分かりやすくする表示です。"
        case .streamlined:
            return "必要な情報を絞って、画面を静かに見せるシンプルな表示です。"
        }
    }

    var featureLine1: String {
        switch self {
        case .assisted:
            return "説明つき"
        case .streamlined:
            return "情報を厳選"
        }
    }

    var featureLine2: String {
        switch self {
        case .assisted:
            return "迷いにくい"
        case .streamlined:
            return "すっきり表示"
        }
    }

    var previewAccent: Color {
        switch self {
        case .assisted:
            return .meterAccent
        case .streamlined:
            return .cyan
        }
    }

    var startButtonTitle: String {
        switch self {
        case .assisted:
            return "補助テキスト版で始める"
        case .streamlined:
            return "通常版で始める"
        }
    }
}
