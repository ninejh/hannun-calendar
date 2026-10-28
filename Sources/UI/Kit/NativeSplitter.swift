import AppKit

struct NativeSplitterMetadata: Equatable, Sendable {
    var split: LayoutSplit
    var step: PanelSizeStep
    var valueDescription: String
    var help: String
    var label = ""
    func requestedStep(forKeyCode key: UInt16) -> PanelSizeStep? {
        if key == 115 { return .tiny }; if key == 119 { return .large }
        let delta: Int
        switch (split, key) {
        case (.column, 123), (.main, 126), (.rail, 125), (.railBottom, 126): delta = 1
        case (.column, 124), (.main, 125), (.rail, 126), (.railBottom, 125): delta = -1
        default: return nil
        }
        return PanelSizeStep(rawValue: min(4, max(1, step.rawValue + delta)))
    }
}
extension BoardScreenContext {
    func splitterMetadata(split: LayoutSplit, step: PanelSizeStep, primary: String, neighbor: String, neighborStep: PanelSizeStep? = nil) -> NativeSplitterMetadata {
        func name(_ value: PanelSizeStep) -> String {
            let key: String = switch value { case .tiny: "tiny"; case .small: "small"; case .regular: "regular"; case .large: "large" }
            return text("layout.step." + key)
        }
        let labelKey: String = switch split { case .column: "column"; case .main: "main"; default: "pair" }
        let label = text("a11y.splitter." + labelKey, values: ["primary": primary, "neighbor": neighbor])
        let value = text("a11y.splitter.value", values: ["name": name(step), "step": String(step.rawValue)])
        let help = neighborStep.map { text("a11y.splitter.pair_help", values: ["primary": primary, "primarySize": name(step), "neighbor": neighbor, "neighborSize": name($0)]) } ?? text("a11y.splitter.help")
        return NativeSplitterMetadata(split: split, step: step, valueDescription: value, help: help, label: label)
    }
}
