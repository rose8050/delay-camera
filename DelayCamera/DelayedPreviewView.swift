import SwiftUI
import AVFoundation

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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct GridOverlayView: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let width = geometry.size.width
                let height = geometry.size.height
                for i in 1...2 {
                    let x = width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: height))

                    let y = height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.75)
            .shadow(color: .black.opacity(0.35), radius: 1)
        }
        .allowsHitTesting(false)
    }
}
