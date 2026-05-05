import SwiftUI
import AVFoundation

/// Draggable floating camera overlay window.
/// Shows live camera preview in a circular shape.
/// Click the close button to hide; re-show via menu bar.
struct CameraOverlay: View {
    @ObservedObject var appState: AppState

    let cameraManager: CameraManager
    var onHide: (() -> Void)?

    var body: some View {
        ZStack {
            // Camera Preview
            CameraPreviewRepresentable(cameraManager: cameraManager)
                .frame(width: appState.cameraSize, height: appState.cameraSize)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.4), .white.opacity(0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )

            // Close/hide button (top-right of circle)
            Button(action: { onHide?() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.8), .black.opacity(0.5))
            }
            .buttonStyle(.plain)
            .offset(x: appState.cameraSize / 2 - 8, y: -(appState.cameraSize / 2 - 8))
            .help("Hide camera preview")
        }
        .frame(width: appState.cameraSize, height: appState.cameraSize)
    }
}

// MARK: - Camera Preview (custom NSView that properly handles layout)

struct CameraPreviewRepresentable: NSViewRepresentable {
    let cameraManager: CameraManager

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.setPreviewLayer(cameraManager.videoPreviewLayer)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        nsView.setPreviewLayer(cameraManager.videoPreviewLayer)
    }
}

/// Custom NSView that hosts an AVCaptureVideoPreviewLayer.
/// Handles layout properly so the layer resizes with the view.
class CameraPreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        if previewLayer === layer { return } // Already set

        // Remove old layer
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil

        guard let layer = layer else { return }

        layer.cornerRadius = bounds.width / 2
        layer.masksToBounds = true

        // Mirror horizontally (natural mirror like FaceTime/Zoom)
        layer.transform = CATransform3DMakeScale(-1, 1, 1)

        // Set frame to current bounds (may be zero initially, fixed in layout())
        layer.frame = bounds

        self.layer?.addSublayer(layer)
        previewLayer = layer
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
        previewLayer?.cornerRadius = bounds.width / 2
    }
}
