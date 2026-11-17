import AVFoundation
import SwiftUI

/// 把 AVCaptureVideoPreviewLayer 桥接进 SwiftUI。
struct CameraPreview: UIViewRepresentable {

    let session: AVCaptureSession
    /// 前置摄像头需要镜像，否则自拍画面与最终成片左右相反
    let mirrored: Bool

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection,
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
        applyMirroring(to: view)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
        applyMirroring(to: uiView)
    }

    private func applyMirroring(to view: PreviewView) {
        guard let connection = view.previewLayer.connection,
              connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
