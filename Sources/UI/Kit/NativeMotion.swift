import AppKit
import QuartzCore

enum MotionDuration {
    static let instant = 0.10, fast = 0.12, popover = 0.18, toastEnter = 0.18, toastStay = 8.0, toastExit = 0.15
    static let panel = 0.20, swap = 0.22, reset = 0.24, spinner = 0.75, check = 0.12, timer = 0.20, shake = 0.12, reducedFade = 0.08
}
enum NativeMotionKind { case press, release, popover, toast, panel, swap, reset, check, timer, shake, spinner, rollback }
struct NativeMotionPlan {
    var duration: TimeInterval
    var keyPath: String
    var from: Double
    var to: Double
}
@MainActor private final class NativeMotionCompletion {
    weak var layer: CALayer?
    let generation: UUID
    var timer: Timer?
    init(layer: CALayer, generation: UUID) { self.layer = layer; self.generation = generation }
}
@MainActor enum NativeMotion {
    private static let feedbackKey = "hannun.feedback"
    private static let generationKey = "hannunGeneration"
    private static var completions: [ObjectIdentifier: NativeMotionCompletion] = [:]
#if HANNUN_TESTING
    static var pendingCompletionCount: Int { completions.count }
    static func testSpinnerAnimation(_ layer: CALayer) -> CABasicAnimation? {
        guard let animation = layer.animation(forKey: feedbackKey) as? CABasicAnimation,
              animation.keyPath == "transform.rotation.z", animation.repeatCount == .infinity else { return nil }
        return animation
    }
#endif
    static func plan(_ kind: NativeMotionKind, reduceMotion: Bool) -> NativeMotionPlan {
        if case .rollback = kind { return NativeMotionPlan(duration: 0, keyPath: "opacity", from: 1, to: 1) }
        if reduceMotion { return NativeMotionPlan(duration: MotionDuration.reducedFade, keyPath: "opacity", from: 0.6, to: 1) }
        switch kind {
        case .press: return NativeMotionPlan(duration: 0, keyPath: "transform.scale", from: 1, to: 0.985)
        case .release: return NativeMotionPlan(duration: MotionDuration.instant, keyPath: "transform.scale", from: 0.985, to: 1)
        case .check: return NativeMotionPlan(duration: MotionDuration.check, keyPath: "transform.scale", from: 1.1, to: 1)
        case .spinner: return NativeMotionPlan(duration: MotionDuration.spinner, keyPath: "transform.rotation.z", from: 0, to: -.pi * 2)
        case .shake: return NativeMotionPlan(duration: MotionDuration.shake, keyPath: "transform.translation.x", from: 0, to: 0)
        case .timer: return NativeMotionPlan(duration: MotionDuration.timer, keyPath: "opacity", from: 0, to: 0)
        case .popover: return NativeMotionPlan(duration: MotionDuration.popover, keyPath: "opacity", from: 0, to: 1)
        case .toast: return NativeMotionPlan(duration: MotionDuration.toastEnter, keyPath: "opacity", from: 0, to: 1)
        case .panel: return NativeMotionPlan(duration: MotionDuration.panel, keyPath: "opacity", from: 0, to: 1)
        case .swap: return NativeMotionPlan(duration: MotionDuration.swap, keyPath: "opacity", from: 0.6, to: 1)
        case .reset: return NativeMotionPlan(duration: MotionDuration.reset, keyPath: "opacity", from: 0.6, to: 1)
        case .rollback: return NativeMotionPlan(duration: 0, keyPath: "opacity", from: 1, to: 1)
        }
    }
    /// Scalar paint feedback uses the same ease-out curve as the native layer animation.
    static func easeOutProgress(_ progress: Double) -> Double {
        let x = min(1, max(0, progress))
        var low = 0.0, high = 1.0
        for _ in 0..<16 {
            let t = (low + high) / 2, u = 1 - t
            let curveX = 3 * u * u * t * 0.23 + 3 * u * t * t * 0.32 + t * t * t
            if curveX < x { low = t } else { high = t }
        }
        let u = 1 - (low + high) / 2
        return 1 - u * u * u
    }
    static func apply(_ kind: NativeMotionKind, to layer: CALayer, reduceMotion: Bool) {
        let plan = plan(kind, reduceMotion: reduceMotion)
        let current = layer.presentation()?.value(forKeyPath: plan.keyPath)
        stop(layer)
        // Switching Reduce Motion while interrupted must also clear the old transform.
        if reduceMotion || kind == .rollback { CATransaction.begin(); CATransaction.setDisableActions(true); layer.transform = CATransform3DIdentity; CATransaction.commit() }
        guard plan.duration > 0 else {
            CATransaction.begin(); CATransaction.setDisableActions(true); layer.setValue(plan.to, forKeyPath: plan.keyPath); CATransaction.commit(); return
        }
        let animation: CAAnimation
        if !reduceMotion, kind == .timer || kind == .shake {
            let keyframes = CAKeyframeAnimation(keyPath: plan.keyPath)
            keyframes.values = kind == .timer ? [0, 0.4, 0] : [0, -3, 3, -2, 2, 0]
            animation = keyframes
        } else {
            let basic = CABasicAnimation(keyPath: plan.keyPath); basic.fromValue = current ?? plan.from; basic.toValue = plan.to
            if kind == .spinner && !reduceMotion { basic.repeatCount = .infinity; basic.timingFunction = CAMediaTimingFunction(name: .linear) }
            animation = basic
        }
        animation.duration = plan.duration
        if kind != .spinner { animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1) }
        CATransaction.begin(); CATransaction.setDisableActions(true); layer.setValue(plan.to, forKeyPath: plan.keyPath); CATransaction.commit()
        let generation = UUID()
        animation.setValue(generation.uuidString, forKey: generationKey)
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: feedbackKey)
        if kind != .spinner || reduceMotion { scheduleCompletion(for: layer, generation: generation, after: plan.duration) }
    }
    private static func scheduleCompletion(for layer: CALayer, generation: UUID, after seconds: TimeInterval) {
        let identity = ObjectIdentifier(layer)
        let completion = NativeMotionCompletion(layer: layer, generation: generation)
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak completion] _ in
            MainActor.assumeIsolated {
                guard let completion, completions[identity]?.generation == completion.generation else { return }
                completions.removeValue(forKey: identity)
                completion.timer?.invalidate(); completion.timer = nil
                // An ordered-out render tree may defer CA's own completion indefinitely.
                // The model already contains the final value; never remove a newer feedback.
                if let layer = completion.layer,
                   layer.animation(forKey: feedbackKey)?.value(forKey: generationKey) as? String == completion.generation.uuidString {
                    layer.removeAnimation(forKey: feedbackKey)
                }
            }
        }
        completion.timer = timer; completions[identity] = completion
        RunLoop.main.add(timer, forMode: .common)
    }
    static func stop(_ layer: CALayer) {
        if let completion = completions.removeValue(forKey: ObjectIdentifier(layer)) {
            completion.timer?.invalidate(); completion.timer = nil
        }
        layer.removeAllAnimations()
    }
}
