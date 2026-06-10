import CoreVideo
import Foundation

/// Pure-function red-colour analyser.
/// Works directly on CVPixelBuffer (BGRA format) for maximum performance.
enum ROIAnalyzer {

    /// Returns true if the fraction of "red" pixels in `roi` exceeds `threshold`.
    /// - Parameters:
    ///   - pixelBuffer: BGRA pixel buffer from AVFoundation
    ///   - roi: Normalised rect (0…1 in both axes)
    ///   - threshold: Fraction of pixels that must be red (e.g. 0.15 = 15%)
    ///   - redHueWidth: Half-width of the red hue band (hue wraps at 0/1)
    ///   - minSaturation: Minimum HSV saturation to count as a colour
    ///   - minBrightness: Minimum HSV value (brightness) to count
    static func analyseRedInROI(
        pixelBuffer: CVPixelBuffer,
        roi: CGRect,
        threshold: Double,
        redHueWidth: Double,
        minSaturation: Double,
        minBrightness: Double
    ) -> Bool {

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // Convert normalised ROI to pixel coordinates
        let x0 = max(0, Int(roi.minX * Double(width)))
        let y0 = max(0, Int(roi.minY * Double(height)))
        let x1 = min(width,  Int(roi.maxX * Double(width)))
        let y1 = min(height, Int(roi.maxY * Double(height)))

        guard x1 > x0, y1 > y0 else { return false }

        // Sample every Nth pixel for speed (stride = 2 → check 25% of pixels)
        let stride = 2
        var redCount = 0
        var totalCount = 0

        let buffer = base.assumingMemoryBound(to: UInt8.self)
        let isARGB = CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32ARGB

        for y in Swift.stride(from: y0, to: y1, by: stride) {
            for x in Swift.stride(from: x0, to: x1, by: stride) {
                let offset = y * bytesPerRow + x * 4
                // BGRA: [B, G, R, A]  /  ARGB: [A, R, G, B]
                let r: Double
                let g: Double
                let b: Double
                if isARGB {
                    r = Double(buffer[offset + 1]) / 255.0
                    g = Double(buffer[offset + 2]) / 255.0
                    b = Double(buffer[offset + 3]) / 255.0
                } else {
                    b = Double(buffer[offset])     / 255.0
                    g = Double(buffer[offset + 1]) / 255.0
                    r = Double(buffer[offset + 2]) / 255.0
                }

                if isRed(r: r, g: g, b: b,
                         redHueWidth: redHueWidth,
                         minSaturation: minSaturation,
                         minBrightness: minBrightness) {
                    redCount += 1
                }
                totalCount += 1
            }
        }

        guard totalCount > 0 else { return false }
        let fraction = Double(redCount) / Double(totalCount)
        return fraction >= threshold
    }

    // MARK: – HSV conversion + red test

    /// Convert RGB → HSV and test whether the pixel falls in the red zone.
    private static func isRed(r: Double, g: Double, b: Double,
                               redHueWidth: Double,
                               minSaturation: Double,
                               minBrightness: Double) -> Bool {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let delta = maxC - minC

        // Value (brightness)
        guard maxC >= minBrightness else { return false }

        // Saturation
        let saturation = maxC > 0 ? delta / maxC : 0
        guard saturation >= minSaturation else { return false }

        // Hue (0…1)
        var hue: Double = 0
        if delta > 0 {
            if maxC == r {
                hue = (g - b) / delta
            } else if maxC == g {
                hue = 2 + (b - r) / delta
            } else {
                hue = 4 + (r - g) / delta
            }
            hue /= 6
            if hue < 0 { hue += 1 }
        }

        // Red wraps around 0/1
        return hue <= redHueWidth || hue >= (1 - redHueWidth)
    }
}
