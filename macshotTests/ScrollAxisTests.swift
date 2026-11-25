import CoreGraphics
import Foundation
import XCTest

/// Horizontal capture is the vertical pipeline reading transposed frames. These
/// tests pin the two halves of that: the transposition maps pixels and rects
/// exactly, and synthetic sideways scrolling ends up as one wide image with no
/// duplicated or missing columns.
@MainActor
final class ScrollAxisTests: XCTestCase {

    // MARK: - Fixtures

    /// An image whose pixel at (x, y) has a distinct, exact grey value. Built
    /// from raw bytes so no drawing or colour conversion can blur the result.
    private func grayscaleImage(width: Int, height: Int) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value = UInt8((y * width + x) % 251)
                bytes[offset] = value      // blue
                bytes[offset + 1] = value  // green
                bytes[offset + 2] = value  // red
                bytes[offset + 3] = 255    // alpha
            }
        }
        let data = Data(bytes) as CFData
        let provider = CGDataProvider(data: data)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                           .union(.byteOrder32Little),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    /// Grey value at (x, y), read through the same addressing the matcher uses.
    private func grey(_ image: CGImage, x: Int, y: Int) -> Int {
        let frame = ScrollFrameAnalyzer.frame(for: image)!
        let offset = frame.offset(x: x, y: y)!
        return Int(frame.bytes[offset + frame.redOffset])
    }

    private func greyValues(_ image: CGImage) -> [Int] {
        (0..<image.height).flatMap { y in (0..<image.width).map { grey(image, x: $0, y: y) } }
    }

    // MARK: - Transposition

    func testTransposeSwapsPixelsAndSize() throws {
        let image = grayscaleImage(width: 4, height: 3)
        let transposed = try XCTUnwrap(image.transposed())

        XCTAssertEqual(transposed.width, 3)
        XCTAssertEqual(transposed.height, 4)
        for y in 0..<transposed.height {
            for x in 0..<transposed.width {
                XCTAssertEqual(grey(transposed, x: x, y: y), grey(image, x: y, y: x),
                               "pixel (\(x), \(y)) of the transpose")
            }
        }
    }

    func testTransposeIsItsOwnInverse() throws {
        let image = grayscaleImage(width: 7, height: 5)
        let restored = try XCTUnwrap(image.transposed()?.transposed())
        XCTAssertEqual(restored.width, image.width)
        XCTAssertEqual(restored.height, image.height)
        XCTAssertEqual(greyValues(restored), greyValues(image))
    }

    func testTransposeOfUnsupportedPixelFormatFails() {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let grayContext = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceGray(),
                                    bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        XCTAssertNotNil(context.makeImage())
        XCTAssertNil(grayContext.makeImage()?.transposed(), "a format the analyzer can't address")
    }

    // MARK: - Axis mapping

    func testVerticalCaptureLeavesFramesAndRectsAlone() {
        let rect = CGRect(x: 3, y: 5, width: 11, height: 13)
        XCTAssertEqual(ScrollAxis.vertical.oriented(rect), rect)
        let image = grayscaleImage(width: 4, height: 3)
        XCTAssertEqual(ScrollAxis.vertical.pixelSize(of: image), CGSize(width: 4, height: 3))
    }

    func testHorizontalCaptureSwapsRectAxes() {
        let rect = CGRect(x: 3, y: 5, width: 11, height: 13)
        XCTAssertEqual(ScrollAxis.horizontal.oriented(rect),
                       CGRect(x: 5, y: 3, width: 13, height: 11))
    }

    func testHorizontalPixelSizeIsReportedUpright() throws {
        let image = grayscaleImage(width: 4, height: 3)
        let stitched = try XCTUnwrap(ScrollAxis.horizontal.oriented(image))
        // The stitcher grows the transposed image's height; the user's image
        // grows in width.
        XCTAssertEqual(stitched.width, 3)
        XCTAssertEqual(stitched.height, 4)
        XCTAssertEqual(ScrollAxis.horizontal.pixelSize(of: stitched), CGSize(width: 4, height: 3))
    }

    // MARK: - Sideways stitching

    /// A wide document: 10-pixel cells of distinct grey values, so every column
    /// and row carries content the matcher can align on.
    private func document(width: Int, height: Int) -> CGImage {
        let colors = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: colors,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setShouldAntialias(false)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for y in stride(from: 0, to: height, by: 10) {
            for x in stride(from: 0, to: width, by: 10) {
                var seed = UInt64(x / 10 * 7919 + y / 10 * 104_729)
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let shade = CGFloat((seed >> 33) % 200) / 255
                context.setFillColor(CGColor(gray: shade, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 10, height: 10))
            }
        }
        return context.makeImage()!
    }

    func testSidewaysScrollingStitchesOneWideImage() throws {
        let windowWidth = 300, windowHeight = 220
        let offsets = [0, 40, 96, 160, 250, 380, 520, 600]
        let page = document(width: windowWidth + offsets.last!, height: windowHeight)

        // Drawn into a fresh, full-size buffer: a cropped CGImage shares its
        // parent's provider, whose byte length the analyzer rejects.
        func frame(at offset: Int) -> CGImage {
            let context = CGContext(data: nil, width: windowWidth, height: windowHeight,
                                    bitsPerComponent: 8, bytesPerRow: windowWidth * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)!
            context.interpolationQuality = .none
            context.draw(page, in: CGRect(x: -offset, y: 0, width: page.width, height: page.height))
            return context.makeImage()!
        }
        let axis = ScrollAxis.horizontal
        let first = try XCTUnwrap(axis.oriented(frame(at: offsets[0])))
        let stitcher = ScrollStitcher(firstFrame: first)
        for offset in offsets.dropFirst() {
            let oriented = try XCTUnwrap(axis.oriented(frame(at: offset)))
            XCTAssertNotEqual(stitcher.add(oriented), .noMatch, "offset \(offset)")
        }
        let stitched = try XCTUnwrap(stitcher.finish().transposed())

        XCTAssertEqual(stitched.width, page.width)
        XCTAssertEqual(stitched.height, windowHeight)
        var wrongColumns: [Int] = []
        for x in 0..<page.width where (0..<page.height).map({ grey(stitched, x: x, y: $0) })
            != (0..<page.height).map({ grey(page, x: x, y: $0) }) {
            wrongColumns.append(x)
        }
        XCTAssertTrue(wrongColumns.isEmpty,
                      "\(wrongColumns.count) columns differ, first at \(wrongColumns.first ?? -1)")
    }
}
