import AppKit
@testable import StacioApp

final class RecordingTerminalPathCompletionProvider: TerminalPathCompletionProviding {
    private let values: [TerminalPathCompletionCandidate]
    private(set) var requests: [TerminalPathCompletionRequest] = []

    init(candidates: [TerminalPathCompletionCandidate]) {
        self.values = candidates
    }

    func candidates(for request: TerminalPathCompletionRequest) throws -> [TerminalPathCompletionCandidate] {
        requests.append(request)
        return values
    }
}

extension NSColor {
    var stacioTestAlphaComponent: CGFloat {
        (usingColorSpace(.deviceRGB) ?? self).alphaComponent
    }

    var stacioTestRelativeLuminance: CGFloat {
        let components = stacioTestRGBComponents
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(components.red)
            + 0.7152 * linear(components.green)
            + 0.0722 * linear(components.blue)
    }

    func stacioTestContrastRatio(against other: NSColor) -> CGFloat {
        let lhs = stacioTestRelativeLuminance
        let rhs = other.stacioTestRelativeLuminance
        return (max(lhs, rhs) + 0.05) / (min(lhs, rhs) + 0.05)
    }

    private var stacioTestRGBComponents: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let color = usingColorSpace(.deviceRGB) ?? NSColor.black
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }
}

extension CGColor {
    var stacioTestRelativeLuminance: CGFloat {
        (NSColor(cgColor: self) ?? .black).stacioTestRelativeLuminance
    }
}
