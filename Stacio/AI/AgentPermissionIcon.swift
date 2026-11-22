import AppKit

extension AgentPermissionMode {
 @MainActor
 func permissionIcon(size: CGFloat = 14, tint: NSColor? = nil) -> NSImage? {
 let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
 switch self {
 case .supervised:
 return NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "手掌")?
 .withSymbolConfiguration(symbolConfiguration)
 case .smartApproval, .dangerFullAccess:
 let mode = self
 let icon = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
 guard let context = NSGraphicsContext.current?.cgContext else { return false }
 context.saveGState()
 defer { context.restoreGState() }
 context.translateBy(x: rect.minX, y: rect.minY)
 context.scaleBy(x: rect.width / 16, y: rect.height / 16)
 context.setStrokeColor((tint ?? .black).cgColor)
 context.setFillColor((tint ?? .black).cgColor)
 context.setLineWidth(1.35)
 context.setLineCap(.round)
 context.setLineJoin(.round)

 context.move(to: CGPoint(x: 8, y: 1.35))
 context.addQuadCurve(to: CGPoint(x: 14.2, y: 4), control: CGPoint(x: 10.8, y: 2.9))
 context.addLine(to: CGPoint(x: 14.2, y: 7.7))
 context.addQuadCurve(to: CGPoint(x: 8, y: 14.65), control: CGPoint(x: 14.2, y: 12.6))
 context.addQuadCurve(to: CGPoint(x: 1.8, y: 7.7), control: CGPoint(x: 1.8, y: 12.6))
 context.addLine(to: CGPoint(x: 1.8, y: 4))
 context.addQuadCurve(to: CGPoint(x: 8, y: 1.35), control: CGPoint(x: 5.2, y: 2.9))
 context.closePath()
 context.strokePath()

 context.setLineWidth(1.2)
 if mode == .smartApproval {
 context.move(to: CGPoint(x: 5.7, y: 10.7))
 context.addLine(to: CGPoint(x: 8, y: 5.25))
 context.addLine(to: CGPoint(x: 10.3, y: 10.7))
 context.move(to: CGPoint(x: 6.5, y: 8.85))
 context.addLine(to: CGPoint(x: 9.5, y: 8.85))
 } else {
 context.move(to: CGPoint(x: 8, y: 5.25))
 context.addLine(to: CGPoint(x: 8, y: 8.25))
 }
 context.strokePath()
 if mode == .dangerFullAccess {
 context.fillEllipse(in: CGRect(x: 7.3, y: 9.65, width: 1.4, height: 1.4))
 }
 return true
 }
 icon.isTemplate = tint == nil
 icon.accessibilityDescription = mode == .smartApproval ? "A 字盾牌" : "感叹号盾牌"
 return icon
 }
 }
}
