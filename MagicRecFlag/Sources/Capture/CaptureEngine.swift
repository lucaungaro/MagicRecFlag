import AVFoundation
import CoreImage
import AppKit

/// Manages the AVCaptureSession and dispatches ROI analysis on every frame.
final class CaptureEngine: NSObject {

    static let shared = CaptureEngine()

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "com.magicrecflag.analysis", qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    // Debounce: how many consecutive "red" frames before triggering
    private let triggerFrameCount = 3
    private var consecutiveRedFrames = 0
    private var consecutiveNonRedFrames = 0

    private var lastState: RecordingState = .standby

    enum RecordingState { case standby, recording }

    // MARK: – Public

    func start() {
        guard let device = AppState.shared.selectedDevice else { return }

        session.beginConfiguration()
        session.sessionPreset = .high

        // Input
        if let old = currentInput { session.removeInput(old) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            print("[CaptureEngine] Input error: \(error)")
        }

        // Output
        session.outputs.forEach { session.removeOutput($0) }
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    func stop() {
        session.stopRunning()
    }
}

// MARK: – AVCaptureVideoDataOutputSampleBufferDelegate

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let isRed = ROIAnalyzer.analyseRedInROI(
            pixelBuffer: imageBuffer,
            roi: AppState.shared.roiRect,
            threshold: AppState.shared.redThreshold,
            redHueWidth: AppState.shared.redHueWidth,
            minSaturation: AppState.shared.minSaturation,
            minBrightness: AppState.shared.minBrightness
        )

        handleDetection(isRed: isRed)
    }

    private func handleDetection(isRed: Bool) {
        if isRed {
            consecutiveRedFrames += 1
            consecutiveNonRedFrames = 0
        } else {
            consecutiveNonRedFrames += 1
            consecutiveRedFrames = 0
        }

        // Require N consecutive frames to avoid flickering
        if consecutiveRedFrames >= triggerFrameCount && lastState == .standby {
            lastState = .recording
            DispatchQueue.main.async { ActionDispatcher.shared.triggerRecord() }
        } else if consecutiveNonRedFrames >= triggerFrameCount && lastState == .recording {
            lastState = .standby
            DispatchQueue.main.async { ActionDispatcher.shared.triggerStop() }
        }
    }
}
