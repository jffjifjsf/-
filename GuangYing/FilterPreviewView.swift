import Combine
import SwiftUI
import UIKit

/// 滤镜预览层。
///
/// 直接订阅相机控制器推送的已渲染帧，把 `UIImage` 设到 `UIImageView` 上，
/// **不经过 SwiftUI 的状态刷新**——否则 12fps 的整棵视图树重建会明显拖慢。
struct FilterPreviewView: UIViewRepresentable {

    let controller: CameraController
    let mirrored: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.backgroundColor = .black
        applyMirroring(to: view)

        context.coordinator.cancellable = controller.frameSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak view] image in
                view?.image = image
            }
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        applyMirroring(to: uiView)
    }

    /// 前置摄像头预览需水平翻转，与系统预览层行为一致
    private func applyMirroring(to view: UIImageView) {
        view.transform = mirrored
            ? CGAffineTransform(scaleX: -1, y: 1)
            : .identity
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var cancellable: AnyCancellable?
    }
}
