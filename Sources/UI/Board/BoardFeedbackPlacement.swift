import Foundation
import CoreGraphics

/// Finds a visible rectangle without intersecting any resize hit region.
/// The edge candidates are complete for axis-aligned rectangular obstacles:
/// a fitting rectangle can slide until it meets a viewport or obstacle edge.
enum BoardFeedbackPlacement {
    static func find(in bounds: CGRect, avoiding obstacles: [CGRect], panels: [CGRect], preferredWidth: CGFloat, minimumWidth: CGFloat, height: CGFloat) -> CGRect? {
        guard bounds.width.isFinite, bounds.height.isFinite, preferredWidth.isFinite, minimumWidth.isFinite, height.isFinite,
              minimumWidth > 0, height > 0, bounds.width >= minimumWidth, bounds.height >= height else { return nil }
        let upper = min(bounds.width, preferredWidth)
        guard upper >= minimumWidth else { return nil }
        let widths = [upper, min(upper, 240), min(upper, 160), min(upper, 96), minimumWidth].filter { $0 >= minimumWidth }
        let clips = obstacles.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
        func area(_ rect: CGRect) -> CGFloat { rect.isNull || rect.isEmpty ? 0 : rect.width * rect.height }
        for width in widths {
            let maxX = bounds.maxX - width, maxY = bounds.maxY - height
            func clamp(_ x: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, x)) }
            var xs = [bounds.minX, bounds.midX - width / 2, maxX]
            var ys = [maxY, bounds.minY, bounds.midY - height / 2]
            for rect in clips { xs += [rect.minX - width, rect.maxX]; ys += [rect.minY - height, rect.maxY] }
            var best: CGRect?, bestScore = CGFloat.greatestFiniteMagnitude
            for y in ys { for x in xs {
                let candidate = CGRect(x: clamp(x, bounds.minX, maxX), y: clamp(y, bounds.minY, maxY), width: width, height: height)
                guard clips.allSatisfy({ !$0.intersects(candidate) }) else { continue }
                let overlap = panels.reduce(CGFloat.zero) { $0 + area($1.intersection(candidate)) }
                let preference = abs(candidate.midX - bounds.midX) + abs(candidate.maxY - bounds.maxY)
                let score = overlap * 1000 + preference
                if score < bestScore { best = candidate; bestScore = score }
            } }
            if let best { return best }
        }
        return nil
    }
}
