import AVFoundation
import CoreImage
import AppKit

final class CaptureEngine: NSObject {

    static let shared = CaptureEngine()

    // AVFoundation path
    private let session      = AVCaptureSession()
    private let videoOutput  = AVCaptureVideoDataOutput()
    private let analysisQueue = DispatchQueue(label: "com.magicrecflag.analysis",
                                              qos: .userInteractive)
    private var currentInput: AVCaptureDeviceInput?

    // DeckLink path
    private var dlSession: DLCaptureSession?

    // Debounce state (shared between both paths)
    private let triggerFrameCount = 3
    private var consecutiveRedFrames    = 0
    private var consecutiveNonRedFrames = 0
    private var lastState: RecordingState = .standby

    enum RecordingState { case standby, recording }

    // MARK: – Public

    func start() {
        if let dl = AppState.shared.selectedDLDevice {
            startDeckLink(device: dl)
        } else if let av = AppState.shared.selectedDevice {
            startAVFoundation(device: av)
        }
    }

    func stop() {
        session.stopRunning()
        dlSession?.stop()
        dlSession = nil
        // Reset debounce state for next session
        consecutiveRedFrames    = 0
        consecutiveNonRedFrames = 0
        lastState = .standby
    }

    // MARK: – AVFoundation path

    private func startAVFoundation(device: AVCaptureDevice) {
        session.beginConfiguration()
        session.sessionPreset = .high
        if let old = currentInput { session.removeInput(old) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) { session.addInput(input); currentInput = input }
        } catch {
            print("[CaptureEngine] AVFoundation input error: \(error)")
        }
        session.outputs.forEach { session.removeOutput($0) }
        videoOutput.setSampleBufferDelegate(self, queue: analysisQueue)
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        session.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    // MARK: – DeckLink path

    private func startDeckLink(device: DLDevice) {
        guard let captureSession = DLCaptureSession(device: device) else {
            print("[CaptureEngine] Could not create DLCaptureSession")
            return
        }
        dlSession = captureSession
        captureSession.start { [weak self] pixelBuffer in
            guard let self else { return }
            let isRed = ROIAnalyzer.analyseRedInROI(
                pixelBuffer: pixelBuffer,
                roi:           AppState.shared.roiRect,
                threshold:     AppState.shared.redThreshold,
                redHueWidth:   AppState.shared.redHueWidth,
                minSaturation: AppState.shared.minSaturation,
                minBrightness: AppState.shared.minBrightness
            )
            self.handleDetection(isRed: isRed)
        }
    }

    // MARK: – Shared detection logic

    fileprivate func handleDetection(isRed: Bool) {
        if isRed {
            consecutiveRedFrames    += 1
            consecutiveNonRedFrames  = 0
        } else {
            consecutiveNonRedFrames += 1
            consecutiveRedFrames     = 0
        }
        if consecutiveRedFrames >= triggerFrameCount && lastState == .standby {
            lastState = .recording
            DispatchQueue.main.async { ActionDispatcher.shared.triggerRecord() }
        } else if consecutiveNonRedFrames >= triggerFrameCount && lastState == .recording {
            lastState = .standby
            DispatchQueue.main.async { ActionDispatcher.shared.triggerStop() }
        }
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
            roi:           AppState.shared.roiRect,
            threshold:     AppState.shared.redThreshold,
            redHueWidth:   AppState.shared.redHueWidth,
            minSaturation: AppState.shared.minSaturation,
            minBrightness: AppState.shared.minBrightness
        )
        handleDetection(isRed: isRed)
    }
}
