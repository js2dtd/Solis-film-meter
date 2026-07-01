//
//  ApertureBladeSilhouetteIcon.swift
//  Solis film meter
//

// MARK: - 役割: 絞り羽根アイコンの描画
// MARK: - 目次
// 1. ApertureBladeSilhouetteIcon表示
// 2. ApertureBladeSilhouetteShape
// 3. 絞り羽根パス生成と開口率調整

import SwiftUI

struct ApertureBladeSilhouetteIcon: View {
    var bladeCount: Int = 6
    var color: Color = .primary
    var openingRatio: CGFloat = 0.3

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)

            ApertureBladeSilhouetteShape(
                bladeCount: bladeCount,
                openingRatio: openingRatio
            )
            .fill(color, style: FillStyle(eoFill: true))
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

private struct ApertureBladeSilhouetteShape: Shape {
    var bladeCount: Int
    var openingRatio: CGFloat

    func path(in rect: CGRect) -> Path {
        let count = max(5, bladeCount)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = min(rect.width, rect.height) * 0.47
        let innerRadius = outerRadius * min(max(openingRatio, 0.18), 0.46)
        let step = (CGFloat.pi * 2) / CGFloat(count)

        var path = Path()

        for index in 0..<count {
            let baseAngle = -CGFloat.pi / 2 + (step * CGFloat(index))

            let outerStart = point(center: center, radius: outerRadius, angle: baseAngle - (step * 0.34))
            let outerEnd = point(center: center, radius: outerRadius, angle: baseAngle + (step * 0.36))
            let innerTip = point(center: center, radius: outerRadius * 0.36, angle: baseAngle + (step * 0.08))
            let innerShoulder = point(center: center, radius: outerRadius * 0.56, angle: baseAngle - (step * 0.28))

            path.move(to: outerStart)
            path.addLine(to: outerEnd)
            path.addLine(to: innerTip)
            path.addLine(to: innerShoulder)
            path.closeSubpath()
        }

        path.addPath(
            apertureOpeningPath(
                center: center,
                radius: innerRadius,
                sides: count,
                rotation: -CGFloat.pi / 2 + (step * 0.18)
            )
        )

        return path
    }

    private func point(center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    private func apertureOpeningPath(center: CGPoint, radius: CGFloat, sides: Int, rotation: CGFloat) -> Path {
        var path = Path()

        for side in 0..<sides {
            let angle = rotation + ((CGFloat.pi * 2) / CGFloat(sides)) * CGFloat(side)
            let point = point(center: center, radius: radius, angle: angle)

            if side == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        path.closeSubpath()
        return path
    }
}

#Preview("Aperture Blade") {
    ZStack {
        Color.black
        ApertureBladeSilhouetteIcon(color: .white)
            .frame(width: 96, height: 96)
    }
}
