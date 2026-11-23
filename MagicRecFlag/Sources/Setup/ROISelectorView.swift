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

            // Live preview + ROI overlay. The preview is aspect-fit, so the overlay
            // covers only the picture (not the black bars): its normalised rect is
            // then the same one the analyser applies to the frame.
            GeometryReader { geo in
                let picture = fittedRect(in: geo.size)
                ZStack {
                    previewView
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4), lineWidth: 1))

                    ROIOverlayView(roiRect: $state.roiRect, containerSize: picture.size)
                        .frame(width: picture.width, height: picture.height)
                        .position(x: picture.midX, y: picture.midY)
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
                liveReadout
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .padding(24)
        .onAppear {
            print("[ROI] selectedDLDevice: \(state.selectedDLDevice?.name ?? "nil")")
            print("[ROI] selectedNDISource: \(state.selectedNDISource?.name ?? "nil")")
            print("[ROI] selectedAVDevice: \(state.selectedDevice?.localizedName ?? "nil")")
            if let dl = state.selectedDLDevice {
                print("[ROI] → startDeckLink: \(dl.name)")
                preview.startDeckLink(device: dl)
            } else if let ndi = state.selectedNDISource {
                print("[ROI] → startNDI: \(ndi.name)")
                preview.startNDI(source: ndi)
            } else if let av = state.selectedDevice {
                print("[ROI] → startAVFoundation: \(av.localizedName)")
                preview.startAVFoundation(device: av)
            } else {
                print("[ROI] ⚠️ No device selected — nothing to preview")
            }
        }
        .onDisappear { preview.stop() }
    }

    /// Live share of red pixels in the region, against the threshold, so the
    /// threshold can be set from what the analyser actually sees.
    @ViewBuilder
    private var liveReadout: some View {
        HStack(spacing: 6) {
            if let fraction = preview.redFraction {
                let triggers = fraction >= state.redThreshold
                Circle()
                    .fill(triggers ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                Text("Red in region now: \(Int((fraction * 100).rounded()))% — "
                     + (triggers ? "would trigger REC" : "below threshold, stays STBY"))
            } else {
                Text("Red in region now: —")
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    /// The area the aspect-fit preview picture occupies inside `container`.
    private func fittedRect(in container: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: container)
        guard let video = preview.videoSize, video.width > 0, video.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: video, insideRect: bounds)
    }

    @ViewBuilder
    private var previewView: some View {
        if let waitingText = preview.frameSourceWaitingText {
            // DeckLink / NDI: render frames as NSImage
            if let img = preview.framePreviewImage {
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
                        Text(waitingText)
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
        let minSize: CGFloat = 0.01   // small enough for a tally dot (~20 px on 1920)
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

    // DeckLink / NDI — frames delivered as pixel buffers, rendered as NSImage
    private var dlCaptureSession:  DLCaptureSession?
    private var ndiCaptureSession: NDICaptureSession?
    private let ciContext  = CIContext()
    private var frameCount = 0

    /// Non-nil while previewing a DeckLink or NDI source (no AVCaptureSession);
    /// shown until the first frame arrives.
    @Published var frameSourceWaitingText: String?  = nil
    @Published var framePreviewImage:      NSImage? = nil

    /// Pixel size of the incoming frames (for mapping the ROI onto the picture).
    @Published var videoSize:   CGSize? = nil
    /// Live share of red pixels in the current ROI, with the current tuning.
    @Published var redFraction: Double? = nil

    override init() { super.init() }

    // MARK: AVFoundation start

    func startAVFoundation(device: AVCaptureDevice) {
        frameSourceWaitingText = nil
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
            // Same format as the live CaptureEngine, so the readout matches it.
            avOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
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
        guard avFrameCount % 2 == 0,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        measure(imageBuffer)
    }

    // MARK: DeckLink start

    func startDeckLink(device: DLDevice) {
        frameSourceWaitingText = "Waiting for DeckLink signal…"
        guard let cap = DLCaptureSession(device: device) else {
            print("[Preview] Could not create DLCaptureSession")
            return
        }
        dlCaptureSession = cap
        cap.start { [weak self] pixelBuffer in self?.showFrame(pixelBuffer) }
    }

    // MARK: NDI start

    func startNDI(source: NDISource) {
        frameSourceWaitingText = "Waiting for NDI source “\(source.name)”…"
        guard let cap = NDICaptureSession(source: source) else {
            print("[Preview] Could not create NDICaptureSession")
            return
        }
        ndiCaptureSession = cap
        cap.start { [weak self] pixelBuffer in self?.showFrame(pixelBuffer) }
    }

    private func showFrame(_ pixelBuffer: CVPixelBuffer) {
        frameCount += 1
        guard frameCount % 2 == 0 else { return }   // ~15 fps is enough for setup
        measure(pixelBuffer)
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return }
        let img = NSImage(cgImage: cg, size: .zero)
        DispatchQueue.main.async { self.framePreviewImage = img }
    }

    /// Runs the live analyser on a preview frame (called on the capture thread).
    private func measure(_ pixelBuffer: CVPixelBuffer) {
        let state = AppState.shared
        let fraction = ROIAnalyzer.redFraction(
            pixelBuffer:   pixelBuffer,
            roi:           state.roiRect,
            redHueWidth:   state.redHueWidth,
            minSaturation: state.minSaturation,
            minBrightness: state.minBrightness)
        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        DispatchQueue.main.async {
            if self.videoSize != size { self.videoSize = size }
            self.redFraction = fraction
        }
    }

    // MARK: Stop

    func stop() {
        avSession.stopRunning()
        dlCaptureSession?.stop()
        dlCaptureSession = nil
        ndiCaptureSession?.stop()
        ndiCaptureSession = nil
        frameSourceWaitingText = nil
        redFraction = nil
    }
}
