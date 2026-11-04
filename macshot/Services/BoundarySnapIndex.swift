import Cocoa

/// Image-edge index for "boundary snap" — snapping the capture selection's
/// dragged edges to strong color boundaries (UI lines, window borders, table
/// rows, etc.) in the captured screenshot, like CleanShot X + PixelSnap.
///
/// Built ONCE per screenshot (off the main thread). During a resize drag the
/// lookup is a cheap scan over a small ±radius window, scored only across the
/// selection's perpendicular span so it snaps to edges that actually run along
/// the dragged side — not unrelated lines elsewhere on screen.
///
/// All "boundary" indices are between-pixel positions: vertical boundary `b`
/// (0…width) sits between pixel columns `b-1` and `b`; horizontal boundary `b`
/// (0…height) sits between rows `b-1` and `b`. Boundary 0 and width/height are
/// the image edges (no diff), so the usable range is 1…dim-1.
struct BoundarySnapIndex {
    let width: Int
    let height: Int
    /// drawRect the screenshot was drawn into (overlay-space). Used to map
    /// view points ↔ image pixels.
    let drawRect: NSRect

    /// Per-pixel vertical edge strength, quantized to 0…255. The RGB euclidean
    /// distance (0…~441) is saturated at 255: lookups only threshold and compare
    /// means, and ranking between candidates is by distance, not strength.
    /// Indexed `[y * (width + 1) + xBoundary]`, xBoundary in 1…width-1.
    private let verticalDiff: [UInt8]
    /// Per-pixel horizontal edge strength, quantized to 0…255.
    /// Indexed `[yBoundary * width + x]`, yBoundary in 1…height-1.
    private let horizontalDiff: [UInt8]

    /// A qualifying snap target.
    struct Hit {
        let viewPosition: CGFloat   // overlay-space coordinate to snap the edge to
        let pixelBoundary: Int
        let strength: Float
    }

    // Tuning. An edge qualifies when its mean color difference along the
    // selection span clears `minMeanDiff` AND it's covered along a good fraction
    // of that span (so a single stray high-contrast pixel doesn't count).
    private static let minMeanDiff: Float = 28      // 0…255 (quantized RGB euclidean)
    private static let minSupportFraction: Float = 0.55

    // MARK: - Build

    /// Build the index from a screenshot CGImage drawn into `drawRect`.
    /// Returns nil for degenerate images. Safe to call off the main thread.
    static func build(from cgImage: CGImage, drawRect: NSRect) -> BoundarySnapIndex? {
        let w = cgImage.width
        let h = cgImage.height
        guard w >= 2, h >= 2, drawRect.width > 0, drawRect.height > 0 else { return nil }
        // Cap work on huge displays (e.g. 6K) — the arrays are O(pixels), which
        // is fine up to ~20MP. Bail only if absurd.
        guard w * h <= 40_000_000 else { return nil }

        // One byte per pixel-direction instead of a Float (4 bytes), and the
        // screenshot is rendered in horizontal strips instead of one
        // full-resolution RGBA copy. On a 3024×1964 display that is ~12 MB
        // retained / ~14 MB peak instead of 47 MB / 71 MB.
        var vDiff = [UInt8](repeating: 0, count: h * (w + 1))
        var hDiff = [UInt8](repeating: 0, count: h * w)

        let bytesPerRow = w * 4
        let stripRows = min(128, h)
        var strip = [UInt8](repeating: 0, count: stripRows * bytesPerRow)
        // Last row of the previous strip, so horizontal diffs stay continuous
        // across strip boundaries.
        var previousRow = [UInt8](repeating: 0, count: bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        var yTop = 0
        while yTop < h {
            let rows = min(stripRows, h - yTop)
            guard let stripImage = cgImage.cropping(
                to: CGRect(x: 0, y: yTop, width: w, height: rows))
            else { return nil }

            let rendered = strip.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(
                    data: raw.baseAddress, width: w, height: rows,
                    bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { return false }
                ctx.draw(stripImage, in: CGRect(x: 0, y: 0, width: w, height: rows))
                return true
            }
            guard rendered else { return nil }

            strip.withUnsafeBufferPointer { buf in
                let p = buf.baseAddress!
                for r in 0..<rows {
                    let y = yTop + r
                    let row = r * bytesPerRow
                    let vBase = y * (w + 1)
                    // Vertical boundaries: |column x - column x-1| per row.
                    for x in 1..<w {
                        vDiff[vBase + x] = colorDist(p, row + (x - 1) * 4, row + x * 4)
                    }
                    // Horizontal boundaries: |row y - row y-1| per column.
                    guard y > 0 else { continue }
                    let hBase = y * w
                    if r > 0 {
                        let previous = row - bytesPerRow
                        for x in 0..<w {
                            hDiff[hBase + x] = colorDist(p, previous + x * 4, row + x * 4)
                        }
                    } else {
                        previousRow.withUnsafeBufferPointer { prev in
                            for x in 0..<w {
                                hDiff[hBase + x] = colorDist(
                                    prev.baseAddress!, x * 4, p, row + x * 4)
                            }
                        }
                    }
                }
                // Save this strip's last row for the next strip's first row.
                let last = (rows - 1) * bytesPerRow
                previousRow.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.update(from: p + last, count: bytesPerRow)
                }
            }
            yTop += rows
        }

        return BoundarySnapIndex(
            width: w, height: h, drawRect: drawRect,
            verticalDiff: vDiff, horizontalDiff: hDiff)
    }

    /// Edge strength between two pixels of the same buffer, quantized to 0…255.
    @inline(__always)
    private static func colorDist(_ p: UnsafePointer<UInt8>, _ a: Int, _ b: Int) -> UInt8 {
        colorDist(p, a, p, b)
    }

    /// Edge strength between pixels in two buffers, quantized to 0…255.
    @inline(__always)
    private static func colorDist(_ pa: UnsafePointer<UInt8>, _ a: Int,
                                 _ pb: UnsafePointer<UInt8>, _ b: Int) -> UInt8 {
        let dr = Int(pa[a]) - Int(pb[b])
        let dg = Int(pa[a + 1]) - Int(pb[b + 1])
        let db = Int(pa[a + 2]) - Int(pb[b + 2])
        let squared = dr * dr + dg * dg + db * db
        let distance = Int(Float(squared).squareRoot())
        return distance >= 255 ? 255 : UInt8(distance)
    }

    // MARK: - Coordinate mapping

    private var scaleX: CGFloat { CGFloat(width) / drawRect.width }
    private var scaleY: CGFloat { CGFloat(height) / drawRect.height }

    /// overlay-space X → pixel boundary (rounded, clamped to 0…width).
    private func pixelX(_ viewX: CGFloat) -> Int {
        max(0, min(width, Int((((viewX - drawRect.minX) * scaleX)).rounded())))
    }
    /// overlay-space Y → pixel boundary (Y flipped; rounded, clamped 0…height).
    private func pixelY(_ viewY: CGFloat) -> Int {
        max(0, min(height, Int((((drawRect.maxY - viewY) * scaleY)).rounded())))
    }
    private func viewXOf(boundary b: Int) -> CGFloat { drawRect.minX + CGFloat(b) / scaleX }
    private func viewYOf(boundary b: Int) -> CGFloat { drawRect.maxY - CGFloat(b) / scaleY }

    // MARK: - Lookup

    /// Find the nearest strong VERTICAL image boundary to `viewX`, scoring edge
    /// strength along the selection's [yMinView, yMaxView] span. `radiusPoints`
    /// is the snap radius in overlay points.
    func nearestVertical(toViewX viewX: CGFloat, yMinView: CGFloat, yMaxView: CGFloat,
                         radiusPoints: CGFloat) -> Hit? {
        let center = pixelX(viewX)
        let radiusPx = max(1, Int((radiusPoints * scaleX).rounded()))
        var y0 = pixelY(max(yMinView, yMaxView))   // larger view-Y → smaller pixel-Y
        var y1 = pixelY(min(yMinView, yMaxView))
        if y0 > y1 { swap(&y0, &y1) }
        y0 = max(0, y0); y1 = min(height - 1, y1)
        guard y1 >= y0 else { return nil }
        let span = y1 - y0 + 1

        var best: Hit?
        var bestDist = Int.max
        let lo = max(1, center - radiusPx)
        let hi = min(width - 1, center + radiusPx)
        guard lo <= hi else { return nil }
        for b in lo...hi {
            var sum: Float = 0
            var support = 0
            for y in y0...y1 {
                let d = Float(verticalDiff[y * (width + 1) + b])
                sum += d
                if d >= Self.minMeanDiff { support += 1 }
            }
            let mean = sum / Float(span)
            let supportFrac = Float(support) / Float(span)
            guard mean >= Self.minMeanDiff, supportFrac >= Self.minSupportFraction else { continue }
            // Prefer a true local maximum (sharper than its neighbours).
            let dist = abs(b - center)
            if dist < bestDist {
                bestDist = dist
                best = Hit(viewPosition: viewXOf(boundary: b), pixelBoundary: b, strength: mean)
            }
        }
        return best
    }

    /// Find the nearest strong HORIZONTAL image boundary to `viewY`, scoring edge
    /// strength along the selection's [xMinView, xMaxView] span.
    func nearestHorizontal(toViewY viewY: CGFloat, xMinView: CGFloat, xMaxView: CGFloat,
                           radiusPoints: CGFloat) -> Hit? {
        let center = pixelY(viewY)
        let radiusPx = max(1, Int((radiusPoints * scaleY).rounded()))
        var x0 = pixelX(min(xMinView, xMaxView))
        var x1 = pixelX(max(xMinView, xMaxView))
        x0 = max(0, x0); x1 = min(width - 1, x1)
        guard x1 >= x0 else { return nil }
        let span = x1 - x0 + 1

        var best: Hit?
        var bestDist = Int.max
        let lo = max(1, center - radiusPx)
        let hi = min(height - 1, center + radiusPx)
        guard lo <= hi else { return nil }
        for b in lo...hi {
            var sum: Float = 0
            var support = 0
            let base = b * width
            for x in x0...x1 {
                let d = Float(horizontalDiff[base + x])
                sum += d
                if d >= Self.minMeanDiff { support += 1 }
            }
            let mean = sum / Float(span)
            let supportFrac = Float(support) / Float(span)
            guard mean >= Self.minMeanDiff, supportFrac >= Self.minSupportFraction else { continue }
            let dist = abs(b - center)
            if dist < bestDist {
                bestDist = dist
                best = Hit(viewPosition: viewYOf(boundary: b), pixelBoundary: b, strength: mean)
            }
        }
        return best
    }
}
