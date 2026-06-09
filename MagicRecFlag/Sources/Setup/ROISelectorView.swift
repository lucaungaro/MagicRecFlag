import SwiftUI
import AVFoundation

struct ROISelectorView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var preview = PreviewCaptureSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Detection Region")
                .font(.title2).bold()

            Text("Draw the rectangle that will be analysed for red colour. Drag the corners to resize. The region should cover where a red tally light or red circle will appear.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Live preview + ROI overlay
            GeometryReader { geo in
                ZStack {
                    // Video preview layer
                    CapturePreviewView(session: preview.session)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                        )

                    // ROI overlay
                    ROIOverlayView(roiRect: $state.roiRect, containerSize: geo.size)
                }
            }
            .frame(maxHeight: .infinity)

            // Threshold tuning
            VStack(alignment: .leading, spacing: 8) {
                Text("Detection Sensitivity")
                    .font(.caption).foregroundColor(.secondary)
                HStack {
                    Text("Red threshold").frame(width: 120, alignment: .leading)
                    Slider(value: $state.redThreshold, in: 0.05...0.5, step: 0.01)
                    Text("\(Int(state.redThreshold * 100))%").frame(width: 40)
                }
                .font(.caption)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding(24)
        .onAppear {
            if let device = state.selectedDevice {
                preview.start(device: device)
            }
        }
        .onDisappear { preview.stop() }
    }
}

// MARK: – ROI Overlay (draggable rectangle)

struct ROIOverlayView: View {
    @Binding var roiRect: CGRect
    let containerSize: CGSize

    @State private var dragging: DragHandle? = nil
    @State private var dragStart: CGRect = .zero

    enum DragHandle { case topLeft, topRight, bottomLeft, bottomRight, body }

    private var pixelRect: CGRect {
        CGRect(
            x: roiRect.minX * containerSize.width,
            y: roiRect.minY * containerSize.height,
            width: roiRect.width * containerSize.width,
            height: roiRect.height * containerSize.height
        )
    }

    var body: some View {
        ZStack {
            // Dimmed outside
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .mask(
                    Rectangle()
                        .overlay(
                            Rectangle()
                                .frame(width: pixelRect.width, height: pixelRect.height)
                                .offset(x: pixelRect.midX - containerSize.width/2,
                                        y: pixelRect.midY - containerSize.height/2)
                                .blendMode(.destinationOut)
                        )
                )

            // ROI box — contentShape fills the interior so dragging anywhere inside moves it
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: pixelRect.width, height: pixelRect.height)
                .position(x: pixelRect.midX, y: pixelRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { drag in
                            if dragging == nil { dragging = .body; dragStart = roiRect }
                            let dx = drag.translation.width / containerSize.width
                            let dy = drag.translation.height / containerSize.height
                            roiRect = clamp(CGRect(
                                x: dragStart.minX + dx,
                                y: dragStart.minY + dy,
                                width: dragStart.width,
                                height: dragStart.height
                            ))
                        }
                        .onEnded { _ in dragging = nil }
                )

            // Corner handles
            ForEach([DragHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { handle in
                cornerHandle(handle)
            }
        }
    }

    @ViewBuilder
    private func cornerHandle(_ handle: DragHandle) -> some View {
        let (cx, cy) = cornerPosition(handle)
        Circle()
            .fill(Color.yellow)
            .frame(width: 14, height: 14)
            .position(x: cx, y: cy)
            .gesture(
                DragGesture()
                    .onChanged { drag in
                        if dragging == nil { dragging = handle; dragStart = roiRect }
                        let dx = drag.translation.width / containerSize.width
                        let dy = drag.translation.height / containerSize.height
                        roiRect = resized(rect: dragStart, handle: handle, dx: dx, dy: dy)
                    }
                    .onEnded { _ in dragging = nil }
            )
    }

    private func cornerPosition(_ handle: DragHandle) -> (CGFloat, CGFloat) {
        switch handle {
        case .topLeft:     return (pixelRect.minX, pixelRect.minY)
        case .topRight:    return (pixelRect.maxX, pixelRect.minY)
        case .bottomLeft:  return (pixelRect.minX, pixelRect.maxY)
        case .bottomRight: return (pixelRect.maxX, pixelRect.maxY)
        case .body:        return (pixelRect.midX, pixelRect.midY)
        }
    }

    private func resized(rect: CGRect, handle: DragHandle, dx: CGFloat, dy: CGFloat) -> CGRect {
        var r = rect
        switch handle {
        case .topLeft:
            r = CGRect(x: rect.minX+dx, y: rect.minY+dy, width: rect.width-dx, height: rect.height-dy)
        case .topRight:
            r = CGRect(x: rect.minX, y: rect.minY+dy, width: rect.width+dx, height: rect.height-dy)
        case .bottomLeft:
            r = CGRect(x: rect.minX+dx, y: rect.minY, width: rect.width-dx, height: rect.height+dy)
        case .bottomRight:
            r = CGRect(x: rect.minX, y: rect.minY, width: rect.width+dx, height: rect.height+dy)
        case .body: break
        }
        return clamp(r)
    }

    private func clamp(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.05
        return CGRect(
            x: max(0, min(r.minX, 1 - minSize)),
            y: max(0, min(r.minY, 1 - minSize)),
            width: max(minSize, min(r.width, 1 - max(0, r.minX))),
            height: max(minSize, min(r.height, 1 - max(0, r.minY)))
        )
    }
}

extension ROIOverlayView.DragHandle: Hashable {}

// MARK: – NSView-based capture preview

struct CapturePreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.captureSession = session
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.captureSession = session
    }
}

final class PreviewNSView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?

    var captureSession: AVCaptureSession? {
        didSet {
            previewLayer?.removeFromSuperlayer()
            guard let session = captureSession else { return }
            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            wantsLayer = true
            self.layer?.addSublayer(layer)
            previewLayer = layer
        }
    }

    override func layout() {
        super.layout()
        previewLayer?.frame = bounds
    }
}

// MARK: – Preview capture session helper

@MainActor
final class PreviewCaptureSession: ObservableObject {
    let session = AVCaptureSession()
    private var input: AVCaptureDeviceInput?

    func start(device: AVCaptureDevice) {
        session.beginConfiguration()
        if let old = input { session.removeInput(old) }
        do {
            let newInput = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                input = newInput
            }
        } catch {
            print("Preview session error: \(error)")
        }
        session.commitConfiguration()
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        session.stopRunning()
    }
}
