import AppKit
import Foundation

/// Visual constants for the Stacio AI panel.
enum AgentTheme {
 enum Color {
 static let panel = StacioDesignSystem.theme.windowBackgroundColor
 static let deepest = NSColor.controlBackgroundColor
 static let inputBase = NSColor.textBackgroundColor
 static let userBubble = NSColor.controlAccentColor.withAlphaComponent(0.10)
 static let cardOuter = NSColor.controlBackgroundColor
 static let cardInset = NSColor.labelColor.withAlphaComponent(0.05)
 static let border = NSColor.separatorColor
 static let borderCard = NSColor.separatorColor
 static let text = NSColor.labelColor
 static let textMuted = NSColor.secondaryLabelColor
 static let textSecondary = NSColor.secondaryLabelColor
 static let textTertiary = NSColor.tertiaryLabelColor
 static let textDisabled = NSColor.secondaryLabelColor
 static let taskSuccess = NSColor.systemGreen
 static let pending = NSColor.systemOrange
 static let danger = NSColor.systemRed
 static let warning = NSColor.systemOrange
 static let permissionWarning = NSColor.systemOrange
 static let success = NSColor.systemGreen
 static let brand = NSColor.controlAccentColor
 static let brandSolid = NSColor.linkColor
 static let hoverRow = NSColor.labelColor.withAlphaComponent(0.07)
 static let hoverMedium = NSColor.labelColor.withAlphaComponent(0.07)
 static let selectedRow = NSColor.controlAccentColor.withAlphaComponent(0.16)
 static let warningSubtle = NSColor(srgbRed:0.980, green:0.678, blue:0.078, alpha:0.10)
 static let dangerSubtle = NSColor(srgbRed:1.0, green:0.302, blue:0.310, alpha:0.10)

 static func chipAccent(for kind: AgentContextKind) -> (foreground: NSColor, background: NSColor) {
 switch kind {
 case .terminal:
 return (NSColor(srgbRed:0.753, green:0.518, blue:0.988, alpha:1), NSColor(srgbRed:0.753, green:0.518, blue:0.988, alpha:0.16))
 case .connection:
 return (NSColor(srgbRed:0.996, green:0.737, blue:0.180, alpha:1), NSColor(srgbRed:0.996, green:0.737, blue:0.180, alpha:0.16))
 case .file, .folder, .selection:
 return (NSColor(srgbRed:0.412, green:0.631, blue:1.0, alpha:1), NSColor(srgbRed:0.412, green:0.631, blue:1.0, alpha:0.16))
 }
 }
 }

 enum Metric {
 static let headerHeight: CGFloat=36
 static let headerPaddingLeading: CGFloat=16
 static let headerPaddingTrailing: CGFloat=12
 static let contentPaddingHorizontal: CGFloat=16
 static let contentPaddingVertical: CGFloat=24
 static let messageGap: CGFloat = 12
 static let composerRadius: CGFloat = 12
 static let composerInnerRadius: CGFloat = 8
 static let composerOuterPadding: CGFloat=4
 static let composerEditorMinHeight: CGFloat = 46
 static let composerEditorPaddingTop: CGFloat = 9
 static let composerEditorPaddingHorizontal: CGFloat = 12
 static let composerFooterBottomPadding: CGFloat=10
 static let composerFooterHorizontalPadding: CGFloat=12
 static let composerMaxHeightRatio: CGFloat=0.45
 static let composerMaxHeightCap: CGFloat=320
 static let toolCardSummaryHeight: CGFloat=24
 static let toolCardBodyMaxHeight: CGFloat=240
 static let thinkingMaxHeight: CGFloat=240
 static let radiusMedium: CGFloat=4
 static let radiusCard: CGFloat=6
 static let radiusLarge: CGFloat=8
 static let space1: CGFloat=4
 static let space2: CGFloat=8
 static let space3: CGFloat=12
 }

 enum Font {
 static let body = NSFont.systemFont(ofSize:13)
 static let bodyMedium = NSFont.systemFont(ofSize:13, weight: .medium)
 static let bodySmall = NSFont.systemFont(ofSize:12)
 static let caption = NSFont.systemFont(ofSize:11)
 static let heading = NSFont.systemFont(ofSize:15, weight: .semibold)
 static let title = NSFont.systemFont(ofSize:13, weight: .medium)
 static let mono = NSFont.monospacedSystemFont(ofSize:12, weight: .regular)
 static let monoSmall = NSFont.monospacedSystemFont(ofSize:11, weight: .regular)
 static let monoSummary = NSFont.monospacedSystemFont(ofSize:13, weight: .regular)

 static func paragraphStyle(lineHeight: CGFloat=20) -> NSParagraphStyle {
 let style = NSMutableParagraphStyle()
 style.minimumLineHeight = lineHeight
 style.maximumLineHeight = lineHeight
 style.lineBreakMode = .byCharWrapping
 return style
 }
 }
}

/// Updates layer colors when the host changes appearance.
@MainActor
class AgentSurfaceView: NSView {
    var surfaceColor: NSColor? { didSet { updateSurface() } }
    var outlineColor: NSColor? { didSet { updateSurface() } }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface()
    }

    private func updateSurface() {
        guard surfaceColor != nil || outlineColor != nil || wantsLayer else { return }
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = surfaceColor?.cgColor
            layer?.borderColor = outlineColor?.cgColor
        }
    }
}
