import SwiftUI
import AVFoundation

/// CameraManager.displayLayer(AVSampleBufferDisplayLayer)를 화면에 붙이기만 하는 뷰.
/// 이 레이어에 무엇을, 언제 그릴지는 전적으로 CameraManager의 delay buffer가 결정한다.
struct DelayedPreviewView: UIViewRepresentable {
    let displayLayer: AVSampleBufferDisplayLayer

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.displayLayer = displayLayer
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}
}

final class PreviewContainerView: UIView {
    var displayLayer: AVSampleBufferDisplayLayer? {
        didSet {
            oldValue?.removeFromSuperlayer()
            guard let displayLayer else { return }
            layer.addSublayer(displayLayer)
            displayLayer.frame = bounds
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer?.frame = bounds
    }
}
