import CoreGraphics
import Foundation

/// Which way a scroll capture follows the content.
///
/// `ScrollFrameMatcher` and `ScrollStitcher` know one axis: content moving up
/// a frame, new rows appended at the bottom. Horizontal capture reuses that
/// tested pipeline by transposing every frame — the frame's columns become its
/// rows — and transposing the finished image back. A page that scrolls
/// sideways is then aligned and stitched exactly like a page that scrolls down.
enum ScrollAxis: String, CaseIterable {
    case vertical
    case horizontal

    var isHorizontal: Bool { self == .horizontal }

    var toggled: ScrollAxis { self == .vertical ? .horizontal : .vertical }

    /// The frame as the stitcher reads it. nil only when the frame's pixel
    /// layout can't be transposed (the matcher can't sample it either).
    func oriented(_ image: CGImage) -> CGImage? {
        isHorizontal ? image.transposed() : image
    }

    /// A rect in the coordinates of `oriented(_:)`'s output, so a position in a
    /// captured frame keeps pointing at the same pixels.
    func oriented(_ rect: CGRect) -> CGRect {
        isHorizontal
            ? CGRect(x: rect.minY, y: rect.minX, width: rect.height, height: rect.width)
            : rect
    }

    /// Size of an image in screen orientation, from its stitched (possibly
    /// transposed) form.
    func pixelSize(of image: CGImage) -> CGSize {
        isHorizontal
            ? CGSize(width: CGFloat(image.height), height: CGFloat(image.width))
            : CGSize(width: CGFloat(image.width), height: CGFloat(image.height))
    }
}

extension CGImage {
    /// Pixel-exact transpose: the output pixel at (x, y) is this image's (y, x).
    ///
    /// Only the 8-bit, 32-bits-per-pixel layouts `ScrollFrameAnalyzer` can
    /// address are transposed; whole 4-byte pixels are moved, so the channel
    /// order, colour space and alpha are preserved exactly.
    func transposed() -> CGImage? {
        guard let frame = ScrollFrameAnalyzer.frame(for: self) else { return nil }
        let outWidth = frame.height
        let outHeight = frame.width
        let outBytesPerRow = outWidth * 4
        var output = [UInt8](repeating: 0, count: outBytesPerRow * outHeight)
        let source = UnsafeRawPointer(frame.bytes)
        output.withUnsafeMutableBytes { destination in
            guard let destination = destination.baseAddress else { return }
            for y in 0..<frame.height {
                let sourceRow = y * frame.bytesPerRow
                for x in 0..<frame.width {
                    let pixel = source.loadUnaligned(fromByteOffset: sourceRow + x * 4, as: UInt32.self)
                    destination.storeBytes(of: pixel, toByteOffset: x * outBytesPerRow + y * 4, as: UInt32.self)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(output) as CFData) else { return nil }
        let colorSpace = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: alphaInfo.rawValue)
            .union(self.bitmapInfo.intersection(.byteOrderMask))
        return CGImage(width: outWidth, height: outHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: outBytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo,
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
