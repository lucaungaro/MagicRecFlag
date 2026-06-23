import SwiftUI
import AVFoundation

struct ROISelectorView: View {
    @EnvironmentObject var state: AppState
    @StateObject private var preview = PreviewCaptureSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Detection Region")
                .font(.title2).bold()

            Text("Draw the rectangle that will be analysed for red colour. "
                 + "Drag any corner to resize, or drag inside the box to move it.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Live preview + ROI overlay
            GeometryReader { geo in
                ZStack {
                    previewView
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1))

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
            print("[ROI] selectedDLDevice: \(state.selectedDLDevice?.name ?? "nil")")
            print("[ROI] selectedAVDevice: \(state.selectedDevice?.localizedName ?? "nil")")
            if let dl = state.selectedDLDevice {
                print("[ROI] → startDeckLink: \(dl.name)")
                preview.startDeckLink(device: dl)
            } else if let av = state.selectedDevice {
                print("[ROI] → startAVFoundation: \(av.localizedName)")
                preview.startAVFoundation(device: av)
            } else {
                print("[ROI] ⚠️ No device selected — nothing to preview")
            }
        }
        .onDisappear { preview.stop() }
    }

    @ViewBuilder
    private var previewView: some View {
        if preview.isDeckLink {
            // DeckLink: render frames as NSImage
            if let img = preview.dlPreviewImage {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                ZStack {
                    Color.black
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Waiting for DeckLink signal…")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
        } else {
            CapturePreviewView(session: preview.avSession)
        }
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
        CGRect(x: roiRect.minX * containerSize.width,
               y: roiRect.minY * containerSize.height,
               width: roiRect.width  * containerSize.width,
               height: roiRect.height * containerSize.height)
    }

    var body: some View {
        ZStack {
            // Dimmed outside the ROI
            Rectangle()
                .fill(Color.black.opacity(0.35))
                .mask(
                    Rectangle()
                        .overlay(
                            Rectangle()
                                .frame(width: pixelRect.width, height: pixelRect.height)
                                .offset(x: pixelRect.midX - containerSize.width  / 2,
                                        y: pixelRect.midY - containerSize.height / 2)
                                .blendMode(.destinationOut)
                        )
                )

            // ROI box — contentShape ensures the interior is draggable (not just the stroke)
            Rectangle()
                .stroke(Color.yellow, lineWidth: 2)
                .contentShape(Rectangle())
                .frame(width: pixelRect.width, height: pixelRect.height)
                .position(x: pixelRect.midX, y: pixelRect.midY)
                .gesture(
                    DragGesture()
                        .onChanged { drag in
                            if dragging == nil { dragging = .body; dragStart = roiRect }
                            let dx = drag.translation.width  / containerSize.width
                            let dy = drag.translation.height / containerSize.height
                            roiRect = clamp(CGRect(
                                x: dragStart.minX + dx, y: dragStart.minY + dy,
                                width: dragStart.width,  height: dragStart.height))
                        }
                        .onEnded { _ in dragging = nil }
                )

            // Corner handles
            ForEach([DragHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { h in
                cornerHandle(h)
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
                        let dx = drag.translation.width  / containerSize.width
                        let dy = drag.translation.height / containerSize.height
                        roiRect = resized(rect: dragStart, handle: handle, dx: dx, dy: dy)
                    }
                    .onEnded { _ in dragging = nil }
            )
    }

    private func cornerPosition(_ h: DragHandle) -> (CGFloat, CGFloat) {
        switch h {
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
        case .topLeft:     r = CGRect(x: rect.minX+dx, y: rect.minY+dy, width: rect.width-dx,  height: rect.height-dy)
        case .topRight:    r = CGRect(x: rect.minX,    y: rect.minY+dy, width: rect.width+dx,  height: rect.height-dy)
        case .bottomLeft:  r = CGRect(x: rect.minX+dx, y: rect.minY,    width: rect.width-dx,  height: rect.height+dy)
        case .bottomRight: r = CGRect(x: rect.minX,    y: rect.minY,    width: rect.width+dx,  height: rect.height+dy)
        case .body: break
        }
        return clamp(r)
    }

    private func clamp(_ r: CGRect) -> CGRect {
        let minSize: CGFloat = 0.05
        return CGRect(
            x: max(0, min(r.minX, 1 - minSize)),
            y: max(0, min(r.minY, 1 - minSize)),
            width:  max(minSize, min(r.width,  1 - max(0, r.minX))),
            height: max(minSize, min(r.height, 1 - max(0, r.minY))))
    }
}

extension ROIOverlayView.DragHandle: Hashable {}

// MARK: – NSView-based AVFoundation preview

struct CapturePreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView(); v.captureSession = session; return v
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
            guard let s = captureSession else { return }
            let layer = AVCaptureVideoPreviewLayer(session: s)
            layer.videoGravity = .resizeAspect
            layer.frame = bounds
            wantsLayer = true
            self.layer?.addSublayer(layer)
            previewLayer = layer
        }
    }
    override func layout() { super.layout(); previewLayer?.frame = bounds }
}

// MARK: – Unified preview session (AVFoundation + DeckLink)

final class PreviewCaptureSession: NSObject, ObservableObject,
                                   AVCaptureVideoDataOutputSampleBufferDelegate {
    // AVFoundation
    let avSession = AVCaptureSession()
    private var avInput: AVCaptureDeviceInput?
    private let avOutput = AVCaptureVideoDataOutput()
    private let avQueue  = DispatchQueue(label: "preview.av.frames")
    private var avFrameCount = 0

    // DeckLink
    private var dlCaptureSession: DLCaptureSession?
    private let ciContext  = CIContext()
    private var frameCount = 0

    @Published var isDeckLink:      Bool     = false
    @Published var dlPreviewImage:  NSImage? = nil

    override init() { super.init() }

    // MARK: AVFoundation start

    func startAVFoundation(device: AVCaptureDevice) {
        isDeckLink = false
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        print("[Preview/AV] auth status: \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")

        avFrameCount = 0
        avSession.beginConfiguration()
        if let old = avInput { avSession.removeInput(old) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if avSession.canAddInput(input) {
                avSession.addInput(input); avInput = input
                print("[Preview/AV] input added: \(device.localizedName)")
            } else {
                print("[Preview/AV] ⚠️ canAddInput == false for \(device.localizedName)")
            }
        } catch { print("[Preview/AV] AVCaptureDeviceInput error: \(error)") }

        // Attach a data output so we can definitively confirm frames are flowing
        // (independent of the preview layer).
        if avOutput.sampleBufferDelegate == nil, avSession.canAddOutput(avOutput) {
            avOutput.setSampleBufferDelegate(self, queue: avQueue)
            avSession.addOutput(avOutput)
        }
        avSession.commitConfiguration()

        let s = avSession
        Task.detached {
            s.startRunning()
            print("[Preview/AV] startRunning called — isRunning=\(s.isRunning)")
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        avFrameCount += 1
        if avFrameCount <= 3 { print("[Preview/AV] frame \(avFrameCount) arrived ✓") }
    }

    // MARK: DeckLink start

    func startDeckLink(device: DLDevice) {
        isDeckLink = true
        guard let cap = DLCaptureSession(device: device) else {
            print("[Preview] Could not create DLCaptureSession")
            return
        }
        dlCaptureSession = cap
        cap.start { [weak self] pixelBuffer in
            guard let self else { return }
            self.frameCount += 1
            guard self.frameCount % 2 == 0 else { return }   // ~15 fps is enough for setup
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            guard let cg = self.ciContext.createCGImage(ci, from: ci.extent) else { return }
            let img = NSImage(cgImage: cg, size: .zero)
            DispatchQueue.main.async { self.dlPreviewImage = img }
        }
    }

    // MARK: Stop

    func stop() {
        avSession.stopRunning()
        dlCaptureSession?.stop()
        dlCaptureSession = nil
        isDeckLink = false
    }
}
