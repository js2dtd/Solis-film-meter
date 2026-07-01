// MARK: - 役割: カメラプレビューをSwiftUIで表示するブリッジビュー
// MARK: - 目次
// 1. CameraPreviewViewのUIViewRepresentableブリッジ
// 2. AVCaptureVideoPreviewLayer生成と接続設定
// 3. セッション差し替えと表示更新
// 4. プレビュー向き固定とレイヤーリサイズ
// 5. PreviewContainerView

import SwiftUI
import AVFoundation
import UIKit

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let isActive: Bool
    var onPreviewLayerUpdate: ((AVCaptureVideoPreviewLayer?) -> Void)? = nil

    private let portraitRotationAngle: CGFloat = 90

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.videoGravity = .resizeAspectFill
        view.previewLayer.session = isActive ? session : nil
        configurePreviewConnection(view.previewLayer.connection)
        view.isUserInteractionEnabled = false
        onPreviewLayerUpdate?(isActive ? view.previewLayer : nil)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        let targetSession = isActive ? session : nil
        if uiView.previewLayer.session !== targetSession {
            uiView.previewLayer.session = targetSession
        }
        configurePreviewConnection(uiView.previewLayer.connection)
        onPreviewLayerUpdate?(isActive ? uiView.previewLayer : nil)
    }

    private func configurePreviewConnection(_ connection: AVCaptureConnection?) {
        guard let connection else { return }
        if #available(iOS 17.0, *) {
            guard connection.isVideoRotationAngleSupported(portraitRotationAngle) else { return }
            connection.videoRotationAngle = portraitRotationAngle
        } else if connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        guard let layer = layer as? AVCaptureVideoPreviewLayer else {
            fatalError("Expected AVCaptureVideoPreviewLayer")
        }
        return layer
    }
}
