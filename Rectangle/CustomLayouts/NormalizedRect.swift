/// NormalizedRect.swift
///
/// A rectangle expressed as fractions of a screen's `visibleFrame`, **top-left
/// origin** (x from the left edge, y from the TOP edge) — the intuitive Divvy
/// framing. Part of the parallel custom-layout subsystem (Divvy-2 M1).

import Foundation
import CoreGraphics

struct NormalizedRect: Codable, Equatable {
    var x: CGFloat   // [0,1] from the left
    var y: CGFloat   // [0,1] from the TOP
    var w: CGFloat   // (0,1]
    var h: CGFloat   // (0,1]

    /// Float slop tolerance for boundary checks.
    private static let eps: CGFloat = 1e-6

    var isValid: Bool {
        let e = Self.eps
        guard [x, y, w, h].allSatisfy({ $0.isFinite }) else { return false }
        return x >= -e && y >= -e && w > e && h > e
            && x + w <= 1 + e && y + h <= 1 + e
    }

    /// Snap an arbitrary rect into a valid in-range rect (best effort).
    func clamped() -> NormalizedRect {
        func finite(_ v: CGFloat) -> CGFloat { v.isFinite ? v : 0 }
        var nx = min(max(finite(x), 0), 1)
        var ny = min(max(finite(y), 0), 1)
        var nw = min(max(finite(w), 0), 1)
        var nh = min(max(finite(h), 0), 1)
        nw = min(nw, 1 - nx)
        nh = min(nh, 1 - ny)
        let minSize: CGFloat = 0.001
        if nw < minSize { nx = max(0, min(nx, 1 - minSize)); nw = minSize }
        if nh < minSize { ny = max(0, min(ny, 1 - minSize)); nh = minSize }
        return NormalizedRect(x: nx, y: ny, w: nw, h: nh)
    }

    /// Map onto an AppKit `visibleFrame` (bottom-left origin), in integer pixels.
    /// Uses EDGE-rounding (not per-dimension rounding) so that two adjacent layouts
    /// sharing a fractional edge round that edge to the SAME integer — guaranteeing
    /// they tile with no 1px gap or overlap.
    func pixelRect(in visible: CGRect) -> CGRect {
        let leftPx  = (visible.minX + x * visible.width).rounded()
        let rightPx = (visible.minX + (x + w) * visible.width).rounded()
        // y is from the TOP; convert to AppKit bottom-left within the frame.
        let topY = y * visible.height
        let botY = (y + h) * visible.height
        let originYpx = (visible.minY + visible.height - botY).rounded()
        let maxYpx    = (visible.minY + visible.height - topY).rounded()
        return CGRect(x: leftPx, y: originYpx, width: rightPx - leftPx, height: maxYpx - originYpx)
    }
}
