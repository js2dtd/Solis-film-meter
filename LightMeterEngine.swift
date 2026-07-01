//
//  LightMeterEngine.swift
//  Solis film meter
//

// MARK: - 役割: 輝度サンプリングと露出値計算を担う測光エンジン
// MARK: - 目次
// 1. スポット警告・明暗2点測光・輝度測定モデル
// 2. EV/Av/Tv/M推奨値計算
// 3. 測光モード別の輝度サンプリング
// 4. スポット警告コンテキスト算出
// 5. 明暗2点測光の派生EV計算
// 6. 低レベル輝度サンプル/重み付け補助

import Foundation
import CoreImage

enum SpotMeteringWarning: Equatable {
    case none
    case brightArea
    case offTarget

    var isWarning: Bool {
        self != .none
    }

    var isBrightArea: Bool {
        self == .brightArea
    }

    var isOffTarget: Bool {
        self == .offTarget
    }

    var shortText: String? {
        switch self {
        case .none:
            return nil
        case .brightArea:
            return "高輝度"
        case .offTarget:
            return "基準外測光点"
        }
    }

    var detailText: String? {
        switch self {
        case .none:
            return nil
        case .brightArea:
            return "かなり明るい場所です"
        case .offTarget:
            return "基準から外れています"
        }
    }
}

struct SpotMeteringWarningContext {
    let spotLogLuminance: Double
    let darkestLogLuminance: Double
    let shadowLogLuminance: Double
    let midtoneLogLuminance: Double
    let sunlitLogLuminance: Double
    let brightestLogLuminance: Double
}

struct ThreePointMeteringSample {
    let x: Double
    let y: Double
    let luminance: Double
}

struct ThreePointMeteringResult {
    let highlight: ThreePointMeteringSample
    let midtone: ThreePointMeteringSample
    let shadow: ThreePointMeteringSample
    let meteredLuminance: Double
    let exposureBiasEV: Double
    let dynamicRangeEV: Double
}

struct ThreePointDerivedEVResult {
    let highlightEV: Double
    let midtoneEV: Double
    let shadowEV: Double
    let meteredEV: Double
    let exposureBiasEV: Double
    let dynamicRangeEV: Double
}

struct MeteringLuminanceMeasurements {
    let reference: Double
    let spot: Double
    let spotWarningContext: SpotMeteringWarningContext
    let centerWeighted: Double
    let matrix: Double
    let average: Double

    func luminance(for mode: MeteringMode) -> Double {
        switch mode {
        case .spot:
            return spot
        case .centerWeighted:
            return centerWeighted
        case .matrix:
            return matrix
        case .average:
            return average
        case .threePoint:
            return average
        }
    }
}

// MARK: - 露出計算エンジン — EV算出、Av/Tv/M各モードの推奨値計算、輝度測定
class LightMeterEngine {

    private let calibrationConstant: Double = 12.5
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let linearSRGBColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let minimumLuminance = 1.0e-4
    private let spotRegionSize = 0.12
    private let spotSigmaInFullFrame = 0.030
    private let threePointLockedRegionSize = 0.28
    private let threePointLockedSigma = 0.065
    
    // MARK: - EV計算 — 輝度/絞り+SSからEV値を算出
    
    func calculateEV(fromLuminance luminance: Double, iso: Int = 100) -> Double {
        guard luminance > 0 else { return -10 }
        return log2((luminance * Double(iso)) / calibrationConstant)
    }
    
    func calculateEV(aperture: Aperture, shutterSpeed: ShutterSpeed) -> Double {
        return aperture.avValue + shutterSpeed.tvValue
    }
    
    // MARK: - 絞り優先モード — EV+絞り+ISOから推奨SS算出
    
    func calculateShutterSpeed(
        forEV ev: Double,
        aperture: Aperture,
        iso: ISOValue,
        compensation: Double = 0,
        availableShutterSpeeds: [ShutterSpeed] = ShutterSpeed.standardValues
    ) -> (shutterSpeed: ShutterSpeed?, exactDuration: Double?, evDifference: Double, continuousEVDifference: Double, isWithinRange: Bool) {
        let requiredTv = ev - aperture.avValue + iso.svValue - compensation
        let allSpeeds = availableShutterSpeeds
        guard let minimumTv = allSpeeds.map(\.tvValue).min(),
              let maximumTv = allSpeeds.map(\.tvValue).max() else {
            return (nil, nil, 0, 0, false)
        }

        let clampedTv: Double
        let isWithinRange: Bool
        if requiredTv.isFinite {
            clampedTv = min(max(requiredTv, minimumTv), maximumTv)
            isWithinRange = requiredTv >= minimumTv && requiredTv <= maximumTv
        } else if requiredTv.sign == .minus {
            clampedTv = minimumTv
            isWithinRange = false
        } else {
            clampedTv = maximumTv
            isWithinRange = false
        }

        let exactRequiredTime: Double? = {
            guard requiredTv.isFinite else { return nil }
            let value = 1.0 / pow(2, requiredTv)
            return value.isFinite && value > 0 ? value : nil
        }()
        let requiredTime = 1.0 / pow(2, clampedTv)
        var closestSpeed: ShutterSpeed?
        var minDifference = Double.infinity
        
        for speed in allSpeeds {
            let difference = abs(log2(speed.rawValue / requiredTime))
            if difference < minDifference {
                minDifference = difference
                closestSpeed = speed
            }
        }
        
        guard let recommended = closestSpeed else {
            return (nil, nil, 0, 0, false)
        }
        
        // 推奨値と理想値の差
        // 推奨シャッターが理想より速い（Tv大）→ 光が少ない → アンダー（負の値）
        // 推奨シャッターが理想より遅い（Tv小）→ 光が多い → オーバー（正の値）
        let evDifference = requiredTv.isFinite ? requiredTv - recommended.tvValue : clampedTv - recommended.tvValue
        let continuousEVDifference = requiredTv.isFinite ? requiredTv - clampedTv : 0
        
        return (recommended, exactRequiredTime ?? requiredTime, evDifference, continuousEVDifference, isWithinRange)
    }
    
    // MARK: - シャッタースピード優先モード — EV+SS+ISOから推奨絞り算出
    
    func calculateAperture(
        forEV ev: Double,
        shutterSpeed: ShutterSpeed,
        iso: ISOValue,
        compensation: Double = 0,
        availableApertures: [Aperture] = Aperture.regularValues
    ) -> (aperture: Aperture?, evDifference: Double, isWithinRange: Bool) {
        let requiredAv = ev - shutterSpeed.tvValue + iso.svValue - compensation
        let allApertures = availableApertures
        guard let minimumAv = allApertures.map(\.avValue).min(),
              let maximumAv = allApertures.map(\.avValue).max() else {
            return (nil, 0, false)
        }

        let clampedAv: Double
        let isWithinRange: Bool
        if requiredAv.isFinite {
            clampedAv = min(max(requiredAv, minimumAv), maximumAv)
            isWithinRange = requiredAv >= minimumAv && requiredAv <= maximumAv
        } else if requiredAv.sign == .minus {
            clampedAv = minimumAv
            isWithinRange = false
        } else {
            clampedAv = maximumAv
            isWithinRange = false
        }

        let requiredFNumber = sqrt(pow(2, clampedAv))
        var closestAperture: Aperture?
        var minDifference = Double.infinity
        
        for aperture in allApertures {
            let difference = abs(log2(aperture.rawValue / requiredFNumber))
            if difference < minDifference {
                minDifference = difference
                closestAperture = aperture
            }
        }
        
        guard let recommended = closestAperture else {
            return (nil, 0, false)
        }
        
        // 推奨値と理想値の差
        // 推奨絞りが理想より開いている（Av小）→ 光が多い → オーバー（正の値）
        // 推奨絞りが理想より絞っている（Av大）→ 光が少ない → アンダー（負の値）
        let evDifference = requiredAv.isFinite ? requiredAv - recommended.avValue : clampedAv - recommended.avValue
        
        return (recommended, evDifference, isWithinRange)
    }
    
    // MARK: - マニュアルモード — 測定EVと設定値の差分を算出
    
    func calculateEVDifference(
        measuredEV: Double,
        aperture: Aperture,
        shutterSpeed: ShutterSpeed,
        iso: ISOValue,
        compensation: Double = 0
    ) -> Double {
        // 適正露出に必要なEV（測光値をISO補正）
        let requiredEV = measuredEV + iso.svValue + compensation
        
        // 現在の設定が提供するEV
        // Av + Tv = カメラ設定のEV（大きいほど暗く写る）
        let cameraEV = aperture.avValue + shutterSpeed.tvValue
        
        // 設定EV - 必要EV = 差
        // 正の値 = 設定EVが大きい = 暗く写る = アンダー
        // 負の値 = 設定EVが小さい = 明るく写る = オーバー
        // 表示上は逆にしたいので符号反転
        return requiredEV - cameraEV
    }
    
    // MARK: - 輝度測定 — CIImage→リニアRGB変換→測光モード別加重平均
    
    func measureLuminance(
        from image: CIImage,
        mode: MeteringMode,
        spotPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        visibleRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> Double {
        measureLuminances(
            from: image,
            requiredMode: mode,
            spotPoint: spotPoint,
            visibleRect: visibleRect,
            includeSpotWarningContext: mode == .spot
        ).luminance(for: mode)
    }

    func measureLuminances(
        from image: CIImage,
        requiredMode: MeteringMode? = nil,
        spotPoint: CGPoint = CGPoint(x: 0.5, y: 0.5),
        visibleRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        includeSpotWarningContext: Bool = true
    ) -> MeteringLuminanceMeasurements {
        let linearImage = image.applyingFilter("CISRGBToneCurveToLinear")
        let normalizedVisibleRect = normalizedUnitRect(visibleRect)
        let visibleImage = crop(linearImage, toNormalizedRect: normalizedVisibleRect)
        let visibleSpotPoint = normalizePoint(spotPoint, within: normalizedVisibleRect)
        let shouldMeasureAllModes = requiredMode == nil
        let needsSpot = shouldMeasureAllModes || requiredMode == .spot

        // グローバルサンプリング（reference, center-weighted, matrix, average用）
        let samples = sampleLuminanceMap(
            from: visibleImage,
            in: visibleImage.extent,
            sampleWidth: 29,
            sampleHeight: 29
        )
        let sortedLogLuminances = samples
            .map { log2(max($0.luminance, minimumLuminance)) }
            .sorted()
        let medianLogLuminance = percentile(0.5, in: sortedLogLuminances)
        let referenceLuminance = measureReferenceLuminance(from: samples, medianLogLuminance: medianLogLuminance)

        // スポット用高解像度サンプリング（スポット周辺20%領域を31×31でサンプリング）
        let spotMeasurement = needsSpot
            ? measureSpotLuminanceHighRes(
                from: visibleImage,
                at: visibleSpotPoint,
                regionSize: spotRegionSize,
                sigmaInFullFrame: spotSigmaInFullFrame
            )
            : SpotMeasurement(luminance: referenceLuminance)
        let spotLogLuminance = log2(max(spotMeasurement.luminance, minimumLuminance))
        let spotWarningContext = includeSpotWarningContext
            ? SpotMeteringWarningContext(
                spotLogLuminance: spotLogLuminance,
                darkestLogLuminance: percentile(0.05, in: sortedLogLuminances),
                shadowLogLuminance: percentile(0.25, in: sortedLogLuminances),
                midtoneLogLuminance: medianLogLuminance,
                sunlitLogLuminance: percentile(0.75, in: sortedLogLuminances),
                brightestLogLuminance: percentile(0.95, in: sortedLogLuminances)
            )
            : SpotMeteringWarningContext(
                spotLogLuminance: spotLogLuminance,
                darkestLogLuminance: medianLogLuminance,
                shadowLogLuminance: medianLogLuminance,
                midtoneLogLuminance: medianLogLuminance,
                sunlitLogLuminance: medianLogLuminance,
                brightestLogLuminance: medianLogLuminance
            )

        return MeteringLuminanceMeasurements(
            reference: referenceLuminance,
            spot: spotMeasurement.luminance,
            spotWarningContext: spotWarningContext,
            centerWeighted: shouldMeasureAllModes || requiredMode == .centerWeighted
                ? measureCenterWeightedLuminance(from: samples)
                : referenceLuminance,
            matrix: shouldMeasureAllModes || requiredMode == .matrix
                ? measureMatrixLuminance(from: samples, medianLogLuminance: medianLogLuminance)
                : referenceLuminance,
            average: shouldMeasureAllModes || requiredMode == .average || requiredMode == .threePoint
                ? measureAverageLuminance(from: samples)
                : referenceLuminance
        )
    }

    func measureLockedThreePointLuminance(
        from image: CIImage,
        highlightPoint: CGPoint,
        shadowPoint: CGPoint,
        visibleRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) -> ThreePointMeteringResult {
        let linearImage = image.applyingFilter("CISRGBToneCurveToLinear")
        let normalizedVisibleRect = normalizedUnitRect(visibleRect)
        let visibleImage = crop(linearImage, toNormalizedRect: normalizedVisibleRect)
        let highlightPoint = clampedUnitPoint(highlightPoint)
        let shadowPoint = clampedUnitPoint(shadowPoint)

        let highlight = ThreePointMeteringSample(
            x: highlightPoint.x,
            y: highlightPoint.y,
            luminance: measureSpotLuminanceHighRes(
                from: visibleImage,
                at: highlightPoint,
                regionSize: threePointLockedRegionSize,
                sigmaInFullFrame: threePointLockedSigma
            ).luminance
        )
        let shadow = ThreePointMeteringSample(
            x: shadowPoint.x,
            y: shadowPoint.y,
            luminance: measureSpotLuminanceHighRes(
                from: visibleImage,
                at: shadowPoint,
                regionSize: threePointLockedRegionSize,
                sigmaInFullFrame: threePointLockedSigma
            ).luminance
        )
        let samples = sampleLuminanceMap(
            from: visibleImage,
            in: visibleImage.extent,
            sampleWidth: 35,
            sampleHeight: 35
        )
        let autoMidtonePoint = inferredMidtonePoint(
            from: samples,
            highlight: highlight,
            shadow: shadow
        )
        let midtone = ThreePointMeteringSample(
            x: autoMidtonePoint.x,
            y: autoMidtonePoint.y,
            luminance: measureSpotLuminanceHighRes(
                from: visibleImage,
                at: autoMidtonePoint,
                regionSize: threePointLockedRegionSize,
                sigmaInFullFrame: threePointLockedSigma
            ).luminance
        )

        return makeThreePointResult(highlight: highlight, midtone: midtone, shadow: shadow)
    }

    func deriveThreePointEVResult(highlightEV: Double, shadowEV: Double) -> ThreePointDerivedEVResult {
        let orderedHighlightEV = max(highlightEV, shadowEV)
        let orderedShadowEV = min(highlightEV, shadowEV)
        let midtoneEV = (orderedHighlightEV + orderedShadowEV) * 0.5
        let exposureBiasEV = threePointExposureBias(
            highlightHeadroomEV: max(0, orderedHighlightEV - midtoneEV),
            shadowDepthEV: max(0, midtoneEV - orderedShadowEV)
        )

        return ThreePointDerivedEVResult(
            highlightEV: orderedHighlightEV,
            midtoneEV: midtoneEV,
            shadowEV: orderedShadowEV,
            meteredEV: midtoneEV + exposureBiasEV,
            exposureBiasEV: exposureBiasEV,
            dynamicRangeEV: max(0, orderedHighlightEV - orderedShadowEV)
        )
    }
    
    private func measureReferenceLuminance(from samples: [LuminanceSample], medianLogLuminance: Double) -> Double {
        return meteredLuminance(
            from: samples,
            trimFraction: 0.06
        ) { x, y, luminance in
            let dx = x - 0.5
            let dy = y - 0.5
            let radius = sqrt(dx * dx + dy * dy)
            let centerWeight = 0.55 + exp(-(radius * radius) / (2 * 0.28 * 0.28)) * 1.35

            let deltaEV = log2(max(luminance, minimumLuminance)) - medianLogLuminance
            let highlightPenalty = deltaEV > 0.85
                ? 1.0 / (1.0 + (deltaEV - 0.85) * 1.9)
                : 1.0
            let shadowPenalty = deltaEV < -2.1
                ? 1.0 / (1.0 + (-deltaEV - 2.1) * 0.45)
                : 1.0

            return centerWeight * highlightPenalty * shadowPenalty
        }
    }
    
    // スポット測光：スポット周辺を高解像度クロップしてサンプリング
    private func measureSpotLuminanceHighRes(
        from image: CIImage,
        at point: CGPoint,
        regionSize: Double = 0.12,
        sigmaInFullFrame: Double = 0.030
    ) -> SpotMeasurement {
        let spotRegionSize = regionSize
        let halfSize = spotRegionSize / 2.0
        let cx = Double(point.x)
        let cy = Double(point.y)

        // クロップ領域（画像端でクランプ）
        let cropMinX = max(cx - halfSize, 0)
        let cropMinY = max(cy - halfSize, 0)
        let cropMaxX = min(cx + halfSize, 1)
        let cropMaxY = min(cy + halfSize, 1)
        let cropRect = normalizedUnitRect(CGRect(
            x: cropMinX, y: cropMinY,
            width: cropMaxX - cropMinX, height: cropMaxY - cropMinY
        ))

        guard cropRect.width > 0.01, cropRect.height > 0.01 else {
            return SpotMeasurement(luminance: 0.18)
        }

        let croppedImage = crop(image, toNormalizedRect: cropRect)
        let spotSamples = sampleLuminanceMap(
            from: croppedImage,
            in: croppedImage.extent,
            sampleWidth: 31,
            sampleHeight: 31
        )

        // クロップ内での相対的なスポット中心位置
        let relCenterX = (cx - Double(cropRect.minX)) / Double(cropRect.width)
        let relCenterY = (cy - Double(cropRect.minY)) / Double(cropRect.height)

        // クロップ領域内のsigmaを、全体画像基準の幅から相対値へ変換
        let sigmaInCrop = sigmaInFullFrame / spotRegionSize

        let luminance = meteredLuminance(from: spotSamples, trimFraction: 0.04) { x, y, _ in
            gaussianWeight(x: x, y: y, centerX: relCenterX, centerY: relCenterY, sigma: sigmaInCrop)
        }
        return SpotMeasurement(luminance: luminance)
    }
    
    private func measureCenterWeightedLuminance(from samples: [LuminanceSample]) -> Double {
        return meteredLuminance(from: samples, trimFraction: 0.08) { x, y, _ in
            let dx = x - 0.5
            let dy = y - 0.5
            let radius = sqrt(dx * dx + dy * dy)
            let radialBoost = exp(-(radius * radius) / (2 * 0.24 * 0.24))
            return 0.25 + radialBoost * 1.75
        }
    }
    
    private func measureMatrixLuminance(from samples: [LuminanceSample], medianLogLuminance: Double) -> Double {
        return meteredLuminance(from: samples, trimFraction: 0.10) { x, y, luminance in
            let dx = x - 0.5
            let dy = y - 0.5
            let radius = sqrt(dx * dx + dy * dy)
            let centerWeight = 0.75 + exp(-(radius * radius) / (2 * 0.33 * 0.33))

            let deltaEV = abs(log2(max(luminance, minimumLuminance)) - medianLogLuminance)
            let outlierPenalty: Double
            if deltaEV <= 1.5 {
                outlierPenalty = 1.0
            } else {
                outlierPenalty = 1.0 / (1.0 + (deltaEV - 1.5) * 1.35)
            }

            return centerWeight * outlierPenalty
        }
    }
    
    private func measureAverageLuminance(from samples: [LuminanceSample]) -> Double {
        return meteredLuminance(from: samples, trimFraction: 0.08) { _, _, _ in
            1.0
        }
    }

    private func makeThreePointResult(
        highlight: ThreePointMeteringSample,
        midtone: ThreePointMeteringSample,
        shadow: ThreePointMeteringSample
    ) -> ThreePointMeteringResult {
        let highlightHeadroomEV = max(0, log2(max(highlight.luminance, minimumLuminance) / max(midtone.luminance, minimumLuminance)))
        let shadowDepthEV = max(0, log2(max(midtone.luminance, minimumLuminance) / max(shadow.luminance, minimumLuminance)))
        let dynamicRangeEV = max(0, log2(max(highlight.luminance, minimumLuminance) / max(shadow.luminance, minimumLuminance)))

        let exposureBiasEV = threePointExposureBias(
            highlightHeadroomEV: highlightHeadroomEV,
            shadowDepthEV: shadowDepthEV
        )
        let meteredLuminance = max(minimumLuminance, midtone.luminance * pow(2, exposureBiasEV))

        return ThreePointMeteringResult(
            highlight: highlight,
            midtone: midtone,
            shadow: shadow,
            meteredLuminance: meteredLuminance,
            exposureBiasEV: exposureBiasEV,
            dynamicRangeEV: dynamicRangeEV
        )
    }

    private func threePointExposureBias(
        highlightHeadroomEV: Double,
        shadowDepthEV: Double
    ) -> Double {
        // 中間部を基準にしつつ、ハイライト保護を少し優先する控えめな補正。
        let highlightBias = max(0, 2.2 - highlightHeadroomEV) * 0.28
        let shadowRelief = max(0, 1.4 - shadowDepthEV) * 0.18
        return min(max(highlightBias - shadowRelief, -0.35), 0.5)
    }

    private func inferredMidtonePoint(
        from samples: [LuminanceSample],
        highlight: ThreePointMeteringSample,
        shadow: ThreePointMeteringSample
    ) -> CGPoint {
        let fallback = CGPoint(
            x: (highlight.x + shadow.x) * 0.5,
            y: (highlight.y + shadow.y) * 0.5
        )
        guard !samples.isEmpty else { return fallback }

        let highlightLog = log2(max(highlight.luminance, minimumLuminance))
        let shadowLog = log2(max(shadow.luminance, minimumLuminance))
        let targetLog = (highlightLog + shadowLog) * 0.5
        let midpointX = (highlight.x + shadow.x) * 0.5
        let midpointY = (highlight.y + shadow.y) * 0.5

        let best = samples.min { lhs, rhs in
            midtoneCandidateScore(
                sample: lhs,
                targetLog: targetLog,
                midpointX: midpointX,
                midpointY: midpointY,
                highlight: highlight,
                shadow: shadow
            ) < midtoneCandidateScore(
                sample: rhs,
                targetLog: targetLog,
                midpointX: midpointX,
                midpointY: midpointY,
                highlight: highlight,
                shadow: shadow
            )
        }

        return CGPoint(x: best?.x ?? fallback.x, y: best?.y ?? fallback.y)
    }

    private func midtoneCandidateScore(
        sample: LuminanceSample,
        targetLog: Double,
        midpointX: Double,
        midpointY: Double,
        highlight: ThreePointMeteringSample,
        shadow: ThreePointMeteringSample
    ) -> Double {
        let luminanceDelta = abs(log2(max(sample.luminance, minimumLuminance)) - targetLog)
        let midpointDistance = hypot(sample.x - midpointX, sample.y - midpointY)
        let segmentDistance = distanceToSegment(
            pointX: sample.x,
            pointY: sample.y,
            startX: highlight.x,
            startY: highlight.y,
            endX: shadow.x,
            endY: shadow.y
        )

        return luminanceDelta * 2.4 + midpointDistance * 0.8 + segmentDistance * 0.6
    }

    private func distanceToSegment(
        pointX: Double,
        pointY: Double,
        startX: Double,
        startY: Double,
        endX: Double,
        endY: Double
    ) -> Double {
        let segmentX = endX - startX
        let segmentY = endY - startY
        let lengthSquared = segmentX * segmentX + segmentY * segmentY

        guard lengthSquared > 1.0e-6 else {
            return hypot(pointX - startX, pointY - startY)
        }

        let t = min(
            max(
                ((pointX - startX) * segmentX + (pointY - startY) * segmentY) / lengthSquared,
                0
            ),
            1
        )
        let projectionX = startX + t * segmentX
        let projectionY = startY + t * segmentY
        return hypot(pointX - projectionX, pointY - projectionY)
    }

    private func normalizedUnitRect(_ rect: CGRect) -> CGRect {
        let minX = min(max(rect.minX, 0), 1)
        let minY = min(max(rect.minY, 0), 1)
        let maxX = min(max(rect.maxX, minX), 1)
        let maxY = min(max(rect.maxY, minY), 1)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func crop(_ image: CIImage, toNormalizedRect normalizedRect: CGRect) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }

        let cropRect = CGRect(
            x: extent.minX + extent.width * normalizedRect.minX,
            y: extent.minY + extent.height * normalizedRect.minY,
            width: extent.width * normalizedRect.width,
            height: extent.height * normalizedRect.height
        ).intersection(extent)

        guard !cropRect.isEmpty else { return image }
        return image.cropped(to: cropRect)
    }

    private func normalizePoint(_ point: CGPoint, within visibleRect: CGRect) -> CGPoint {
        guard visibleRect.width > 0.0001, visibleRect.height > 0.0001 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let relativeX = (point.x - visibleRect.minX) / visibleRect.width
        let relativeY = (point.y - visibleRect.minY) / visibleRect.height
        return CGPoint(
            x: min(max(relativeX, 0), 1),
            y: min(max(relativeY, 0), 1)
        )
    }

    private func clampedUnitPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
    }
    
    private func sampleLuminanceMap(from image: CIImage, in rect: CGRect, sampleWidth: Int, sampleHeight: Int) -> [LuminanceSample] {
        let croppedRect = rect.intersection(image.extent)
        guard !croppedRect.isEmpty else { return [] }

        let width = max(1, sampleWidth)
        let height = max(1, sampleHeight)
        let translated = image
            .cropped(to: croppedRect)
            .transformed(by: CGAffineTransform(translationX: -croppedRect.minX, y: -croppedRect.minY))
        let scaled = translated.transformed(
            by: CGAffineTransform(
                scaleX: CGFloat(width) / croppedRect.width,
                y: CGFloat(height) / croppedRect.height
            )
        )

        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: width * 4,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            format: .RGBA8,
            colorSpace: linearSRGBColorSpace
        )

        var samples: [LuminanceSample] = []
        samples.reserveCapacity(width * height)

        for row in 0..<height {
            for column in 0..<width {
                let index = (row * width + column) * 4
                let r = Double(bitmap[index]) / 255.0
                let g = Double(bitmap[index + 1]) / 255.0
                let b = Double(bitmap[index + 2]) / 255.0
                let luminance = max(minimumLuminance, 0.2126 * r + 0.7152 * g + 0.0722 * b)
                let x = (Double(column) + 0.5) / Double(width)
                let y = 1.0 - (Double(row) + 0.5) / Double(height)
                samples.append(LuminanceSample(x: x, y: y, luminance: luminance))
            }
        }

        return samples
    }
    
    private func meteredLuminance(
        from samples: [LuminanceSample],
        trimFraction: Double,
        weighting: (Double, Double, Double) -> Double
    ) -> Double {
        guard !samples.isEmpty else { return 0.18 }

        let weightedLogs = samples.compactMap { sample -> WeightedLogSample? in
            let weight = weighting(sample.x, sample.y, sample.luminance)
            guard weight > 0 else { return nil }
            return WeightedLogSample(
                logLuminance: log2(max(sample.luminance, minimumLuminance)),
                weight: weight
            )
        }

        guard !weightedLogs.isEmpty else { return 0.18 }

        let meteredLogLuminance = weightedTrimmedMean(of: weightedLogs, trimFraction: trimFraction)
        return pow(2.0, meteredLogLuminance)
    }

    private func weightedTrimmedMean(of samples: [WeightedLogSample], trimFraction: Double) -> Double {
        let sorted = samples.sorted { $0.logLuminance < $1.logLuminance }
        let totalWeight = sorted.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return log2(0.18) }

        let clampedTrim = min(max(trimFraction, 0), 0.45)
        let lowerBound = totalWeight * clampedTrim
        let upperBound = totalWeight * (1.0 - clampedTrim)

        var cumulativeWeight = 0.0
        var accumulatedValue = 0.0
        var includedWeight = 0.0

        for sample in sorted {
            let nextWeight = cumulativeWeight + sample.weight
            let keptWeight = max(0.0, min(nextWeight, upperBound) - max(cumulativeWeight, lowerBound))
            if keptWeight > 0 {
                accumulatedValue += sample.logLuminance * keptWeight
                includedWeight += keptWeight
            }
            cumulativeWeight = nextWeight
        }

        if includedWeight > 0 {
            return accumulatedValue / includedWeight
        }

        let weightedSum = sorted.reduce(0.0) { $0 + $1.logLuminance * $1.weight }
        return weightedSum / totalWeight
    }

    private func gaussianWeight(x: Double, y: Double, centerX: Double, centerY: Double, sigma: Double) -> Double {
        let dx = x - centerX
        let dy = y - centerY
        let squaredDistance = dx * dx + dy * dy
        return exp(-squaredDistance / (2 * sigma * sigma))
    }

    private func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return log2(0.18) }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private func percentile(_ percentile: Double, in sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return log2(0.18) }
        let clamped = min(max(percentile, 0), 1)
        let index = Int((Double(sortedValues.count - 1) * clamped).rounded())
        return sortedValues[min(max(index, 0), sortedValues.count - 1)]
    }

    private func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return log2(0.18) }
        return values.reduce(0, +) / Double(values.count)
    }
}

private struct LuminanceSample {
    let x: Double
    let y: Double
    let luminance: Double
}

private struct WeightedLogSample {
    let logLuminance: Double
    let weight: Double
}

private struct SpotMeasurement {
    let luminance: Double
}
