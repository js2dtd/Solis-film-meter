// MARK: - 役割: 購入アクセス、カメラ/フィルムプリセット、セッション状態を保持するストア
// MARK: - 目次
// 1. アクセスレベル/機能ポリシー
// 2. RevenueCat購入プラン、購入、復元、権利確認
// 3. レンズ種別/カメラ/フィルムプリセットモデル
// 4. プリセット表示/焦点距離/クリップボード補助
// 5. AppSessionStoreの選択中プリセット管理
// 6. UserDefaults永続化と保存状態復元

import Foundation
import Combine
import UIKit
import RevenueCat

enum AppAccessLevel: String, CaseIterable, Identifiable {
    case free
    case full

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .free: return "無料版"
        case .full: return "完全版"
        }
    }

    var debugDescription: String {
        switch self {
        case .free: return "無料版（中央重点・平均）"
        case .full: return "完全版（全測光・全機能）"
        }
    }
}

enum AppFeature {
    case advancedReflectiveMetering
    case incidentMetering
    case shotRecords
    case autoExposureLock
    case presets
    case pinholeMode

    var displayName: String {
        switch self {
        case .advancedReflectiveMetering: return "高度な反射光測光"
        case .incidentMetering: return "入射光測定"
        case .shotRecords: return "撮影記録"
        case .autoExposureLock: return "AEL"
        case .presets: return "プリセット"
        case .pinholeMode: return "ピンホール撮影"
        }
    }
}

enum FullVersionPurchasePlan: String {
    case monthly
    case lifetime

    var buttonTitle: String {
        switch self {
        case .monthly: return "月額で解放"
        case .lifetime: return "買い切りで解放"
        }
    }

    var successMessage: String {
        switch self {
        case .monthly: return "月額プランで完全版を解放しました。"
        case .lifetime: return "買い切りで完全版を解放しました。"
        }
    }

    var missingPackageMessage: String {
        switch self {
        case .monthly: return "RevenueCatのOfferingに月額プランが設定されていません。"
        case .lifetime: return "RevenueCatのOfferingに買い切りプランが設定されていません。"
        }
    }

    fileprivate var packageType: PackageType {
        switch self {
        case .monthly: return .monthly
        case .lifetime: return .lifetime
        }
    }

    fileprivate var packageIdentifiers: [String] {
        switch self {
        case .monthly: return ["$rc_monthly", "monthly"]
        case .lifetime: return ["$rc_lifetime", "lifetime"]
        }
    }

    fileprivate var productIdentifierHints: [String] {
        switch self {
        case .monthly:
            return ["monthly", "month"]
        case .lifetime:
            return ["lifetime", "full_unlock", "full", "unlock"]
        }
    }
}

struct AppAccessPolicy {
    let accessLevel: AppAccessLevel

    var isFullVersion: Bool {
        accessLevel == .full
    }

    var shouldShowAuxiliaryLabels: Bool {
        !isFullVersion
    }

    var defaultReflectiveMeteringMode: MeteringMode {
        .centerWeighted
    }

    var availableReflectiveMeteringModes: [MeteringMode] {
        isFullVersion ? MeteringMode.allCases : [.centerWeighted, .average]
    }

    func allows(_ feature: AppFeature) -> Bool {
        switch feature {
        case .advancedReflectiveMetering,
             .incidentMetering,
             .shotRecords,
             .autoExposureLock,
             .presets,
             .pinholeMode:
            return isFullVersion
        }
    }

    func allows(meteringMode: MeteringMode) -> Bool {
        availableReflectiveMeteringModes.contains(meteringMode)
    }

    func normalizedMeteringMode(_ mode: MeteringMode) -> MeteringMode {
        allows(meteringMode: mode) ? mode : defaultReflectiveMeteringMode
    }
}

@MainActor
final class PurchaseAccessStore: ObservableObject {
    static let fullAccessEntitlementID = "full_access"

    @Published var accessLevel: AppAccessLevel {
        didSet {
            #if DEBUG || SOLIS_ENABLE_TEST_ACCESS_UI
            if shouldPersistDebugAccess {
                defaults.set(accessLevel.rawValue, forKey: storageKey)
            }
            #endif
        }
    }
    @Published private(set) var isRefreshingAccess: Bool = false
    @Published private(set) var isPurchasing: Bool = false
    @Published private(set) var isRestoringPurchases: Bool = false
    @Published private(set) var activePurchasePlan: FullVersionPurchasePlan?
    @Published private(set) var purchaseStatusMessage: String?

    var policy: AppAccessPolicy {
        AppAccessPolicy(accessLevel: accessLevel)
    }

    var isPurchaseActionInProgress: Bool {
        isRefreshingAccess || isPurchasing || isRestoringPurchases
    }

    private let defaults = UserDefaults.standard
    private let storageKey = "debugPurchaseAccessLevel.v1"
    private var shouldPersistDebugAccess = true

    init() {
        #if DEBUG || SOLIS_ENABLE_TEST_ACCESS_UI
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-SolisAccessFull") {
            accessLevel = .full
        } else if arguments.contains("-SolisAccessFree") {
            accessLevel = .free
        } else if let rawValue = defaults.string(forKey: storageKey),
                  let savedLevel = AppAccessLevel(rawValue: rawValue) {
            accessLevel = savedLevel
        } else {
            accessLevel = .free
        }
        #else
        accessLevel = .free
        #endif
    }

    func refreshPurchasedAccess() {
        guard !isRefreshingAccess else { return }
        isRefreshingAccess = true

        Purchases.shared.getCustomerInfo { [weak self] customerInfo, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRefreshingAccess = false

                if let customerInfo {
                    self.apply(customerInfo: customerInfo)
                    return
                }

                if let error {
                    self.purchaseStatusMessage = "購入状態を確認できませんでした: \(error.localizedDescription)"
                }
            }
        }
    }

    func purchaseFullVersion() {
        purchaseFullVersion(plan: .lifetime)
    }

    func purchaseFullVersion(plan: FullVersionPurchasePlan) {
        guard !isPurchaseActionInProgress else { return }
        isPurchasing = true
        activePurchasePlan = plan
        purchaseStatusMessage = nil

        Purchases.shared.getOfferings { [weak self] offerings, error in
            Task { @MainActor in
                guard let self else { return }

                if let error {
                    self.isPurchasing = false
                    self.purchaseStatusMessage = "購入商品の取得に失敗しました: \(error.localizedDescription)"
                    return
                }

                let packages = offerings?.current?.availablePackages ?? []
                guard let package = Self.package(for: plan, in: packages) else {
                    self.isPurchasing = false
                    self.activePurchasePlan = nil
                    self.purchaseStatusMessage = self.missingPackageMessage(for: plan, availablePackages: packages)
                    return
                }

                self.purchase(package: package, plan: plan)
            }
        }
    }

    func restorePurchases() {
        guard !isPurchaseActionInProgress else { return }
        isRestoringPurchases = true
        purchaseStatusMessage = nil

        Purchases.shared.restorePurchases { [weak self] customerInfo, error in
            Task { @MainActor in
                guard let self else { return }
                self.isRestoringPurchases = false

                if let customerInfo {
                    let hasFullAccess = self.apply(customerInfo: customerInfo)
                    self.purchaseStatusMessage = hasFullAccess
                        ? "購入を復元しました。"
                        : "復元できる完全版の購入が見つかりませんでした。"
                    return
                }

                if let error {
                    self.purchaseStatusMessage = "購入の復元に失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    private func purchase(package: Package, plan: FullVersionPurchasePlan) {
        Purchases.shared.purchase(package: package) { [weak self] _, customerInfo, error, userCancelled in
            Task { @MainActor in
                guard let self else { return }
                self.isPurchasing = false
                self.activePurchasePlan = nil

                if let customerInfo {
                    let hasFullAccess = self.apply(customerInfo: customerInfo)
                    self.purchaseStatusMessage = hasFullAccess
                        ? plan.successMessage
                        : "購入は完了しましたが、完全版の権利を確認できませんでした。"
                    return
                }

                if userCancelled {
                    self.purchaseStatusMessage = "購入をキャンセルしました。"
                } else if let error {
                    self.purchaseStatusMessage = "購入に失敗しました: \(error.localizedDescription)"
                }
            }
        }
    }

    private static func package(for plan: FullVersionPurchasePlan, in packages: [Package]) -> Package? {
        if let package = packages.first(where: { $0.packageType == plan.packageType }) {
            return package
        }

        if let package = packages.first(where: { package in
            plan.packageIdentifiers.contains(package.identifier)
        }) {
            return package
        }

        return packages.first { package in
            let productIdentifier = package.storeProduct.productIdentifier.lowercased()
            return plan.productIdentifierHints.contains { productIdentifier.contains($0) }
        }
    }

    private func missingPackageMessage(for plan: FullVersionPurchasePlan, availablePackages: [Package]) -> String {
        guard !availablePackages.isEmpty else {
            return "RevenueCatのCurrent OfferingにPackageが設定されていません。"
        }

        let availableText = availablePackages
            .map { "\($0.identifier) / \($0.storeProduct.productIdentifier)" }
            .joined(separator: ", ")
        return "\(plan.missingPackageMessage) 現在取得できたPackage: \(availableText)"
    }

    @discardableResult
    private func apply(customerInfo: CustomerInfo) -> Bool {
        let hasFullAccess = customerInfo.entitlements.all[Self.fullAccessEntitlementID]?.isActive == true
        setAccessLevel(hasFullAccess ? .full : .free, persistDebugAccess: false)
        return hasFullAccess
    }

    private func setAccessLevel(_ newValue: AppAccessLevel, persistDebugAccess: Bool) {
        shouldPersistDebugAccess = persistDebugAccess
        accessLevel = newValue
        shouldPersistDebugAccess = true
    }
}

enum PresetLensType: String, Codable, CaseIterable, Identifiable {
    case prime
    case zoom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .prime: return "単焦点"
        case .zoom: return "ズーム"
        }
    }
}

struct CameraFilmPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var cameraBody: String
    var lens: String
    var lensType: PresetLensType
    var primeFocalLength35mm: Int?
    var film: String
    var date: Date

    init(
        id: UUID = UUID(),
        cameraBody: String,
        lens: String = "",
        lensType: PresetLensType = .prime,
        primeFocalLength35mm: Int? = nil,
        film: String,
        date: Date = Date()
    ) {
        self.id = id
        self.cameraBody = cameraBody
        self.lensType = lensType
        self.primeFocalLength35mm = lensType == .prime ? primeFocalLength35mm : nil
        self.lens = CameraFilmPreset.normalizedLensDetails(
            rawLens: lens,
            lensType: lensType,
            primeFocalLength35mm: self.primeFocalLength35mm
        )
        self.film = film
        self.date = date
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case cameraBody
        case lens
        case lensType
        case primeFocalLength35mm
        case film
        case date
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        cameraBody = try container.decode(String.self, forKey: .cameraBody)
        film = try container.decode(String.self, forKey: .film)
        date = try container.decode(Date.self, forKey: .date)

        let rawLens = try container.decodeIfPresent(String.self, forKey: .lens) ?? ""
        let decodedLensType = try container.decodeIfPresent(PresetLensType.self, forKey: .lensType)
        let decodedPrimeFocalLength = try container.decodeIfPresent(Int.self, forKey: .primeFocalLength35mm)

        let inferredLensType = decodedLensType ?? Self.inferredLensType(from: rawLens, primeFocalLength35mm: decodedPrimeFocalLength)
        let inferredPrimeFocalLength = inferredLensType == .prime
            ? (decodedPrimeFocalLength ?? Self.inferredPrimeFocalLength35mm(from: rawLens))
            : nil

        lensType = inferredLensType
        primeFocalLength35mm = inferredPrimeFocalLength
        lens = Self.normalizedLensDetails(rawLens: rawLens, lensType: inferredLensType, primeFocalLength35mm: inferredPrimeFocalLength)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    var formattedDate: String {
        Self.dateFormatter.string(from: date)
    }

    var lensDisplayText: String {
        switch lensType {
        case .prime:
            if let primeFocalLength35mm {
                return "\(primeFocalLength35mm)mm"
            }
            return "単焦点"
        case .zoom:
            return "ズーム"
        }
    }

    var lensDetailsText: String {
        lens.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var preferredEquivalentFocalLength: Double {
        requestedEquivalentFocalLength(visibleFocalLengthMultiplier: 1)
    }

    func requestedEquivalentFocalLength(visibleFocalLengthMultiplier: Double) -> Double {
        let multiplier = max(1, visibleFocalLengthMultiplier)

        switch lensType {
        case .prime:
            guard let primeFocalLength35mm else {
                return LensFocalLengthGuide.wideEndRequestEquivalentFocalLength
            }
            return max(1, (Double(primeFocalLength35mm) + 0.001) / multiplier)
        case .zoom:
            return LensFocalLengthGuide.wideEndRequestEquivalentFocalLength
        }
    }

    var allowsInteractiveZoom: Bool {
        lensType == .zoom
    }

    var displayLines: [String] {
        let lensLine: String? = {
            var parts: [String] = []
            switch lensType {
            case .prime:
                if let primeFocalLength35mm {
                    parts.append("\(primeFocalLength35mm)mm")
                }
            case .zoom:
                parts.append("ズーム")
            }

            let details = lensDetailsText
            if !details.isEmpty {
                parts.append(details)
            }

            return parts.isEmpty ? nil : "レンズ：\(parts.joined(separator: " / "))"
        }()

        let lines: [String] = [
            cameraBody.isEmpty ? nil : "カメラ：\(cameraBody)",
            lensLine,
            film.isEmpty ? nil : "フィルム：\(film)"
        ].compactMap { $0 }

        return lines.isEmpty ? ["未入力"] : lines
    }

    func displayIndexSymbol(index: Int) -> String {
        index.circledNumber
    }

    func formattedText(index: Int) -> String {
        let lines = displayLines
        let firstLine = "\(displayIndexSymbol(index: index)) \(lines[0])"
        let remainingLines = lines.dropFirst().map { "　 \($0)" }
        return ([firstLine] + remainingLines).joined(separator: "\n")
    }

    func copyToClipboard(index: Int) {
        UIPasteboard.general.string = formattedText(index: index)
    }

    private static func normalizedLensDetails(rawLens: String, lensType: PresetLensType, primeFocalLength35mm: Int?) -> String {
        let trimmedLens = rawLens.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLens.isEmpty else { return "" }

        switch lensType {
        case .prime:
            if let primeFocalLength35mm, trimmedLens == "\(primeFocalLength35mm)mm" {
                return ""
            }
        case .zoom:
            let normalized = trimmedLens.lowercased()
            if normalized == "zoom" || normalized == "ズーム" {
                return ""
            }
        }

        return trimmedLens
    }

    private static func inferredLensType(from rawLens: String, primeFocalLength35mm: Int?) -> PresetLensType {
        if primeFocalLength35mm != nil {
            return .prime
        }

        let normalized = rawLens.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.contains("zoom") || normalized.contains("ズーム") {
            return .zoom
        }
        return .prime
    }

    private static func inferredPrimeFocalLength35mm(from rawLens: String) -> Int? {
        let normalized = rawLens.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.hasSuffix("mm") else { return nil }

        let numberPart = normalized.dropLast(2)
        guard !numberPart.isEmpty, numberPart.allSatisfy(\.isNumber) else { return nil }
        return Int(numberPart)
    }
}

private struct StoredSessionState: Codable {
    var presets: [CameraFilmPreset]
    var selectedPresetID: UUID?

    static let initial = StoredSessionState(
        presets: [],
        selectedPresetID: nil
    )
}

@MainActor
final class AppSessionStore: ObservableObject {
    @Published private(set) var presets: [CameraFilmPreset] = []
    @Published private(set) var selectedPresetID: UUID?

    let orderPageURL = URL(string: "https://filmshop.natsusomare.jp/collections/%E7%8F%BE%E5%83%8F%E3%83%87%E3%83%BC%E3%82%BF%E5%8C%96")

    private let defaults = UserDefaults.standard
    private let stateKey = "appSessionState.v1"

    init() {
        load()
    }

    var activePreset: CameraFilmPreset? {
        guard let selectedPresetID else { return nil }
        return presets.first { $0.id == selectedPresetID }
    }

    func upsertPreset(
        editingID: UUID?,
        cameraBody: String,
        lens: String,
        lensType: PresetLensType,
        primeFocalLength35mm: Int?,
        film: String,
        date: Date
    ) {
        let normalizedCamera = cameraBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedLens = lens.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFilm = film.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPrimeFocalLength = lensType == .prime ? primeFocalLength35mm : nil
        let hasLensInfo = lensType == .zoom || normalizedPrimeFocalLength != nil || !normalizedLens.isEmpty

        // 一部空欄は許可。全項目空欄のみ保存しない。
        guard !normalizedCamera.isEmpty || hasLensInfo || !normalizedFilm.isEmpty else { return }

        if let editingID, let index = presets.firstIndex(where: { $0.id == editingID }) {
            var updated = presets
            updated[index].cameraBody = normalizedCamera
            updated[index].lensType = lensType
            updated[index].primeFocalLength35mm = normalizedPrimeFocalLength
            updated[index].lens = CameraFilmPreset(
                id: updated[index].id,
                cameraBody: normalizedCamera,
                lens: normalizedLens,
                lensType: lensType,
                primeFocalLength35mm: normalizedPrimeFocalLength,
                film: normalizedFilm,
                date: date
            ).lens
            updated[index].film = normalizedFilm
            updated[index].date = date
            presets = updated
            selectedPresetID = updated[index].id
        } else {
            let newPreset = CameraFilmPreset(
                cameraBody: normalizedCamera,
                lens: normalizedLens,
                lensType: lensType,
                primeFocalLength35mm: normalizedPrimeFocalLength,
                film: normalizedFilm,
                date: date
            )
            presets.append(newPreset)
            selectedPresetID = newPreset.id
        }

        save()
    }

    func selectPreset(id: UUID?) {
        selectedPresetID = id
        save()
    }

    func deletePreset(id: UUID) {
        presets.removeAll { $0.id == id }
        if selectedPresetID == id {
            selectedPresetID = nil
        }
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: stateKey),
              let decoded = try? JSONDecoder().decode(StoredSessionState.self, from: data) else {
            apply(StoredSessionState.initial)
            return
        }

        apply(decoded)
    }

    private func apply(_ state: StoredSessionState) {
        presets = state.presets
        selectedPresetID = state.selectedPresetID.flatMap { presetID in
            presets.contains(where: { $0.id == presetID }) ? presetID : nil
        }
    }

    private func save() {
        let state = StoredSessionState(
            presets: presets,
            selectedPresetID: selectedPresetID
        )

        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: stateKey)
        }
    }
}

private extension Int {
    var circledNumber: String {
        let map: [Int: String] = [
            1: "①", 2: "②", 3: "③", 4: "④", 5: "⑤",
            6: "⑥", 7: "⑦", 8: "⑧", 9: "⑨", 10: "⑩",
            11: "⑪", 12: "⑫", 13: "⑬", 14: "⑭", 15: "⑮",
            16: "⑯", 17: "⑰", 18: "⑱", 19: "⑲", 20: "⑳"
        ]
        return map[self] ?? "\(self)."
    }
}
