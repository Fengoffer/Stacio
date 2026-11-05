import AppKit
import CoreText

/// Display data only. Building this view never reads or changes the user's license.
struct LicenseCertificateContent {
    enum Tone { case valid, trial, grace, inactive, problem }
    var title = "软件授权证书"
    var subtitle = "SOFTWARE LICENSE CERTIFICATE"
    var statement = ""
    var username = "—"
    var email = "—"
    var plan = "—"
    var validity = "—"
    var validityDetail: String?
    var status = "未激活"
    var verification = "尚未激活许可证"
    var metadataTitle = "授权方式"
    var metadataValue = "尚未激活"
    var issueTitle = "签发方"
    var issueValue = "Stacio"
    var note = ""
    var tone: Tone = .inactive
}

/// A native, selectable certificate. Ornament is resolution-independent AppKit drawing;
/// every identity, status and date remains a real text field above the paper.
@MainActor
final class LicenseCertificateView: NSView {
    private enum Ink {
        static let primary = NSColor(srgbRed: 0.10, green: 0.15, blue: 0.24, alpha: 1)
        static let secondary = NSColor(srgbRed: 0.36, green: 0.41, blue: 0.49, alpha: 1)
        static let blue = NSColor(srgbRed: 0.22, green: 0.43, blue: 0.87, alpha: 1)
        static let gold = NSColor(srgbRed: 0.59, green: 0.48, blue: 0.29, alpha: 1)
        static let border = NSColor(srgbRed: 0.54, green: 0.66, blue: 0.78, alpha: 1)
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let statementLabel = NSTextField(wrappingLabelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    let userLabel = NSTextField(labelWithString: "")
    let emailLabel = NSTextField(labelWithString: "")
    let validityLabel = NSTextField(labelWithString: "")
    let planLabel = NSTextField(labelWithString: "")
    private let captions = ["授权用户", "授权邮箱", "有效期", "授权版本"].map(NSTextField.init(labelWithString:))
    private let icons = ["person", "envelope", "clock", "rosette"].map { symbolName in
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        return imageView
    }
    private let logoView = NSImageView()
    private let brandLabel = NSTextField(labelWithString: "Stacio")
    private let sealView = NSImageView()
    private let footerIcon = NSImageView()
    private let verificationLabel = NSTextField(labelWithString: "")
    private let metadataCaption = NSTextField(labelWithString: "")
    let metadataLabel = NSTextField(labelWithString: "")
    private let issueCaption = NSTextField(labelWithString: "")
    private let issueLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let teamLabel = NSTextField(labelWithString: "Stacio 团队")
    private var content = LicenseCertificateContent()
    private let brandFont: NSFont
    private let titleFont: NSFont
    override var isFlipped: Bool { true }

    init(resourceDirectory: URL? = nil) {
        let resources: URL?
        if let resourceDirectory {
            resources = resourceDirectory
        } else if Bundle.main.bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            // Installed apps carry these files in Contents/Resources. Never call
            // Bundle.module here: its generated accessor can trap when the build
            // machine's SwiftPM resource bundle is unavailable.
            resources = Bundle.main.resourceURL?.appendingPathComponent("LicenseCertificate")
        } else {
        #if SWIFT_PACKAGE
            resources = StacioPackageResources.moduleBundle?.resourceURL?.appendingPathComponent("LicenseCertificate")
        #else
            resources = Bundle.main.resourceURL?.appendingPathComponent("LicenseCertificate")
        #endif
        }
        if let fontURL = resources?.appendingPathComponent("Lack-Regular.otf") {
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, nil)
        }
        brandFont = NSFont(name: "Lack-Regular", size: 32) ?? .monospacedSystemFont(ofSize: 32, weight: .medium)
        titleFont = NSFont(name: "Songti-SC-Bold", size: 40)
            ?? NSFont(name: "Songti SC", size: 40) ?? .systemFont(ofSize: 40, weight: .semibold)
        super.init(frame: NSRect(x: 0, y: 0, width: 840, height: 620))
        // A certificate is always printed on light paper, independently of window appearance.
        appearance = NSAppearance(named: .aqua)
        setAccessibilityIdentifier("Stacio.License.statusCard")
        if let url = resources?.appendingPathComponent("StacioCertificateIcon.png") {
            logoView.image = NSImage(contentsOf: url)
        }
        logoView.setAccessibilityLabel("Stacio")
        for image in [logoView, sealView, footerIcon] + icons {
            image.imageScaling = .scaleProportionallyUpOrDown
            image.contentTintColor = Ink.blue
            addSubview(image)
        }
        sealView.setAccessibilityElement(false)
        footerIcon.setAccessibilityElement(false)
        for icon in icons { icon.setAccessibilityElement(false) }
        for label in [titleLabel, subtitleLabel, statementLabel, brandLabel, statusLabel,
                      userLabel, emailLabel, validityLabel, planLabel, verificationLabel,
                      metadataCaption, metadataLabel, issueCaption, issueLabel, noteLabel, teamLabel] + captions {
            label.textColor = Ink.primary
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        for (label, id) in [(titleLabel, "certificateTitle"), (statementLabel, "certificateStatement"),
                            (statusLabel, "statusHeadline"), (userLabel, "certificateUser"),
                            (emailLabel, "certificateEmail"), (validityLabel, "certificateValidity"),
                            (planLabel, "certificatePlan"), (metadataLabel, "certificateMetadata"),
                            (issueLabel, "certificateIssuedAt"), (verificationLabel, "certificateVerification")] {
            label.setAccessibilityIdentifier("Stacio.License.\(id)")
        }
        for label in [userLabel, emailLabel, validityLabel, planLabel, metadataLabel, issueLabel] {
            label.isSelectable = true
            label.focusRingType = .default
        }
        statementLabel.maximumNumberOfLines = 2
        statementLabel.lineBreakMode = .byWordWrapping
        render(content)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func render(_ value: LicenseCertificateContent) {
        content = value
        titleLabel.stringValue = value.title
        subtitleLabel.stringValue = value.subtitle
        statementLabel.stringValue = value.statement
        userLabel.stringValue = value.username
        emailLabel.stringValue = value.email
        validityLabel.stringValue = value.validity
        planLabel.stringValue = value.plan
        statusLabel.stringValue = value.status
        verificationLabel.stringValue = value.verification
        metadataCaption.stringValue = value.metadataTitle
        metadataLabel.stringValue = value.metadataValue
        issueCaption.stringValue = value.issueTitle
        issueLabel.stringValue = value.issueValue
        noteLabel.stringValue = value.note
        let symbol: String
        switch value.tone {
        case .valid: symbol = "checkmark.seal.fill"
        case .trial: symbol = "clock.badge.checkmark.fill"
        case .grace: symbol = "clock.badge.exclamationmark.fill"
        case .inactive: symbol = "lock.shield.fill"
        case .problem: symbol = "exclamationmark.shield.fill"
        }
        sealView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        footerIcon.image = NSImage(systemSymbolName: value.tone == .valid ? "checkmark.shield" : "info.circle", accessibilityDescription: nil)
        for label in [userLabel, emailLabel, validityLabel, planLabel, metadataLabel, issueLabel, verificationLabel, noteLabel] {
            label.toolTip = label.stringValue
        }
        validityLabel.toolTip = value.validityDetail ?? value.validity
        validityLabel.setAccessibilityHelp(validityLabel.toolTip)
        needsLayout = true
        needsDisplay = true
    }

    private var accent: NSColor {
        switch content.tone {
        case .valid, .trial: return Ink.blue
        case .grace: return NSColor(srgbRed: 0.63, green: 0.40, blue: 0.14, alpha: 1)
        case .inactive: return Ink.secondary
        case .problem: return NSColor(srgbRed: 0.67, green: 0.28, blue: 0.25, alpha: 1)
        }
    }

    override func layout() {
        super.layout()
        let scale = bounds.width / 840
        let vertical = bounds.height / 620
        func place(_ view: NSView, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) {
            view.frame = NSRect(x: x * scale, y: y * vertical, width: w * scale, height: h * vertical)
        }
        func style(_ label: NSTextField, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) {
            label.font = .systemFont(ofSize: size * scale, weight: weight)
            label.textColor = color
        }
        place(logoView, 51, 48, 63, 63)
        place(brandLabel, 132, 61, 244, 46)
        brandLabel.font = NSFont(descriptor: brandFont.fontDescriptor, size: 32 * scale)
        brandLabel.attributedStringValue = NSAttributedString(string: "Stacio", attributes: [
            .font: brandLabel.font!, .foregroundColor: Ink.primary, .kern: 4 * scale
        ])
        place(titleLabel, 51, 136, 475, 62)
        titleLabel.attributedStringValue = NSAttributedString(string: content.title, attributes: [
            .font: NSFont(descriptor: titleFont.fontDescriptor, size: 40 * scale)!,
            .foregroundColor: Ink.primary, .kern: 5 * scale
        ])
        place(subtitleLabel, 67, 203, 400, 22)
        subtitleLabel.attributedStringValue = NSAttributedString(string: content.subtitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11 * scale, weight: .medium), .foregroundColor: Ink.gold, .kern: 2.2 * scale
        ])
        place(statementLabel, 53, 252, 713, 38)
        style(statementLabel, size: 13, color: Ink.secondary)
        place(sealView, 619, 132, 80, 80)
        sealView.contentTintColor = accent
        place(statusLabel, 570, 230, 178, 22)
        statusLabel.alignment = .center
        style(statusLabel, size: 11, color: accent, weight: .medium)

        let values = [userLabel, emailLabel, validityLabel, planLabel]
        let positions: [(CGFloat, CGFloat)] = [(72, 319), (449, 319), (72, 392), (449, 392)]
        for index in 0..<4 {
            let (x, y) = positions[index]
            place(icons[index], x, y + 12, 25, 28)
            place(captions[index], x + 42, y, 300, 21)
            style(captions[index], size: 11.5, color: Ink.secondary)
            place(values[index], x + 42, y + 27, 286, 30)
            style(values[index], size: values[index].stringValue.count > 30 ? 14 : 18,
                  color: index == 3 ? accent : Ink.primary, weight: .medium)
        }
        place(noteLabel, 73, 464, 574, 20)
        style(noteLabel, size: 10.5, color: Ink.secondary)
        place(metadataCaption, 54, 509, 420, 18)
        place(metadataLabel, 54, 534, 425, 22)
        place(issueCaption, 520, 509, 266, 18)
        place(issueLabel, 520, 534, 267, 22)
        for label in [metadataCaption, issueCaption] { style(label, size: 10.5, color: Ink.secondary) }
        for label in [metadataLabel, issueLabel] {
            label.font = .monospacedSystemFont(ofSize: 11.5 * scale, weight: .regular)
            label.textColor = Ink.secondary
        }
        place(footerIcon, 46, 581, 19, 22)
        footerIcon.contentTintColor = accent
        place(verificationLabel, 77, 584, 610, 20)
        style(verificationLabel, size: 10.5, color: accent)
        place(teamLabel, 704, 584, 89, 20)
        style(teamLabel, size: 11, color: Ink.blue, weight: .medium)
        teamLabel.alignment = .right
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scaleX(by: bounds.width / 840, yBy: bounds.height / 620)
        transform.concat()
        let paper = NSRect(x: 0, y: 0, width: 840, height: 620)
        NSColor(srgbRed: 0.980, green: 0.986, blue: 0.996, alpha: 1).setFill()
        NSBezierPath(roundedRect: paper.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9).fill()
        let inside = NSBezierPath(roundedRect: paper.insetBy(dx: 17, dy: 17), xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        inside.addClip()
        NSGradient(starting: .white, ending: NSColor(srgbRed: 0.962, green: 0.975, blue: 0.995, alpha: 1))?.draw(in: paper, angle: 55)
        drawPaperTexture()
        drawMedallion(center: NSPoint(x: 659, y: 168))

        let panel = NSBezierPath(roundedRect: NSRect(x: 52, y: 303, width: 736, height: 191), xRadius: 9, yRadius: 9)
        NSColor.white.withAlphaComponent(0.58).setFill()
        panel.fill()
        Ink.blue.withAlphaComponent(0.18).setStroke()
        panel.lineWidth = 0.7
        panel.stroke()
        stroke([NSPoint(x: 423, y: 326), NSPoint(x: 423, y: 454)], color: Ink.border.withAlphaComponent(0.23), width: 0.65)
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: 53, y: 291)); rule.line(to: NSPoint(x: 787, y: 291))
        rule.setLineDash([2.5, 2.5], count: 2, phase: 0)
        Ink.border.withAlphaComponent(0.40).setStroke(); rule.lineWidth = 0.6; rule.stroke()
        drawStamp(center: NSPoint(x: 733, y: 484))
        NSColor(srgbRed: 0.32, green: 0.49, blue: 0.77, alpha: 0.065).setFill()
        NSRect(x: 17, y: 570, width: 806, height: 50).fill()
        stroke([NSPoint(x: 17, y: 570), NSPoint(x: 823, y: 570)], color: Ink.blue.withAlphaComponent(0.20), width: 0.7)
        NSGraphicsContext.restoreGraphicsState()
        drawBorder()
        drawSprig(origin: NSPoint(x: 53, y: 215), scale: 0.50, reflected: false, color: Ink.gold.withAlphaComponent(0.70))
        let subtitleWidth = subtitleLabel.attributedStringValue.size().width / max(0.1, bounds.width / 840)
        drawSprig(origin: NSPoint(x: min(487, 80 + subtitleWidth), y: 215), scale: 0.50, reflected: true, color: Ink.gold.withAlphaComponent(0.70))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawPaperTexture() {
        let path = NSBezierPath()
        for n in stride(from: -640, through: 920, by: 18) {
            for direction in [-1.0, 1.0] {
                for step in 0...88 {
                    let y = CGFloat(step) * 7.2
                    let x = CGFloat(n) + direction * y * 0.42 + sin(y / 28 + CGFloat(n) / 90) * 6
                    if step == 0 { path.move(to: NSPoint(x: x, y: y)) }
                    else { path.line(to: NSPoint(x: x, y: y)) }
                }
            }
        }
        Ink.border.withAlphaComponent(0.046).setStroke(); path.lineWidth = 0.35; path.stroke()
    }

    private func drawBorder() {
        for (inset, width, alpha): (CGFloat, CGFloat, CGFloat) in [(1.5, 0.9, 0.36), (12, 0.9, 0.68), (15, 0.6, 0.52), (18, 0.8, 0.68)] {
            Ink.border.withAlphaComponent(alpha).setStroke()
            let path = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: 840 - inset * 2, height: 620 - inset * 2), xRadius: 9, yRadius: 9)
            path.lineWidth = width; path.stroke()
        }
        let lace = NSBezierPath()
        for side in 0..<4 {
            let length: CGFloat = side < 2 ? 784 : 564
            for phase in [0.0, .pi] {
                for step in 0...Int(length * 2) {
                    let distance = CGFloat(step) / 2
                    let ripple = sin(distance * .pi / 3.8 + phase) * 1.4
                    let point: NSPoint
                    switch side {
                    case 0: point = NSPoint(x: 28 + distance, y: 14.8 + ripple)
                    case 1: point = NSPoint(x: 28 + distance, y: 605.2 + ripple)
                    case 2: point = NSPoint(x: 14.8 + ripple, y: 28 + distance)
                    default: point = NSPoint(x: 825.2 + ripple, y: 28 + distance)
                    }
                    if step == 0 { lace.move(to: point) } else { lace.line(to: point) }
                }
            }
        }
        Ink.border.withAlphaComponent(0.57).setStroke(); lace.lineWidth = 0.38; lace.stroke()
        for (x, y, sx, sy): (CGFloat, CGFloat, CGFloat, CGFloat) in [(14,14,1,1), (826,14,-1,1), (14,606,1,-1), (826,606,-1,-1)] {
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: x, yBy: y); t.scaleX(by: sx, yBy: sy); t.concat()
            let scroll = NSBezierPath()
            scroll.move(to: NSPoint(x: -3, y: 14)); scroll.line(to: NSPoint(x: 3, y: 14))
            scroll.curve(to: NSPoint(x: 14, y: 3), controlPoint1: NSPoint(x: 11, y: 15), controlPoint2: NSPoint(x: 15, y: 11))
            scroll.line(to: NSPoint(x: 14, y: -3))
            Ink.border.withAlphaComponent(0.9).setStroke(); scroll.lineWidth = 1; scroll.stroke()
            for r: CGFloat in [4, 7, 10] {
                let p = NSBezierPath(); p.appendArc(withCenter: NSPoint(x: 2, y: 2), radius: r, startAngle: 0, endAngle: 90)
                Ink.border.withAlphaComponent(0.7).setStroke(); p.lineWidth = 0.5; p.stroke()
            }
            let petal = NSBezierPath()
            petal.move(to: .zero); petal.curve(to: NSPoint(x: 8, y: 8), controlPoint1: NSPoint(x: 8, y: -3), controlPoint2: NSPoint(x: 11, y: 5))
            petal.curve(to: .zero, controlPoint1: NSPoint(x: 4, y: 11), controlPoint2: NSPoint(x: -3, y: 8))
            Ink.border.withAlphaComponent(0.38).setFill(); petal.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMedallion(center: NSPoint) {
        let decorative = content.tone == .valid || content.tone == .trial ? Ink.blue : accent
        for layer in 0..<28 {
            let path = NSBezierPath()
            for step in 0...400 {
                let a = CGFloat(step) / 400 * .pi * 2
                let phase = CGFloat(layer) * .pi / 14
                let radius = 78 + 14 * sin(a * 9 + phase) + 7 * cos(a * 3 - phase)
                let p = NSPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
                if step == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            path.close(); decorative.withAlphaComponent(0.085).setStroke(); path.lineWidth = 0.40; path.stroke()
        }
        for index in 0..<5 {
            let path = NSBezierPath()
            for step in 0...280 {
                let angle = CGFloat(step) / 280 * .pi * 2
                let radius = CGFloat(46 + index * 3) + 5 * cos(angle * 8 + CGFloat(index) / 3)
                let point = NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                if step == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            path.close(); decorative.withAlphaComponent(0.025).setFill(); path.fill()
            decorative.withAlphaComponent(0.10).setStroke(); path.lineWidth = 0.6; path.stroke()
        }
        for sign: CGFloat in [-1, 1] {
            let branch = NSBezierPath()
            for step in 0...70 {
                let a = (-36 + CGFloat(step) * 1.52) * .pi / 180
                let p = NSPoint(x: center.x + sign * cos(a) * 123, y: center.y + sin(a) * 123)
                if step == 0 { branch.move(to: p) } else { branch.line(to: p) }
            }
            Ink.border.withAlphaComponent(0.40).setStroke(); branch.lineWidth = 1.1; branch.stroke()
            for i in 0..<10 {
                let a = (-29 + CGFloat(i) * 8.7) * .pi / 180
                let root = NSPoint(x: center.x + sign * cos(a) * 123, y: center.y + sin(a) * 123)
                drawLeaf(at: root, angle: sign > 0 ? a - 0.90 : .pi - a + 0.90, length: 15,
                         color: Ink.border.withAlphaComponent(0.32))
                drawLeaf(at: root, angle: sign > 0 ? a - 2.18 : .pi - a + 2.18, length: 13,
                         color: Ink.border.withAlphaComponent(0.27))
            }
        }
    }

    private func drawLeaf(at origin: NSPoint, angle: CGFloat, length: CGFloat, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform(); t.translateX(by: origin.x, yBy: origin.y); t.rotate(byRadians: angle); t.concat()
        let p = NSBezierPath(); p.move(to: .zero)
        p.curve(to: NSPoint(x: length, y: 0), controlPoint1: NSPoint(x: length * 0.24, y: -length * 0.32), controlPoint2: NSPoint(x: length * 0.80, y: -length * 0.22))
        p.curve(to: .zero, controlPoint1: NSPoint(x: length * 0.60, y: length * 0.32), controlPoint2: NSPoint(x: length * 0.12, y: length * 0.17))
        color.setFill(); p.fill(); NSGraphicsContext.restoreGraphicsState()
    }

    private func drawSprig(origin: NSPoint, scale: CGFloat, reflected: Bool, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform(); t.translateX(by: origin.x, yBy: origin.y); t.scaleX(by: reflected ? -scale : scale, yBy: scale); t.concat()
        let p = NSBezierPath(); p.move(to: NSPoint(x: 7, y: 18)); p.curve(to: NSPoint(x: -6, y: -23), controlPoint1: NSPoint(x: -15, y: 6), controlPoint2: NSPoint(x: -12, y: -14))
        color.setStroke(); p.lineWidth = 0.9; p.stroke()
        for i in 0..<6 {
            let y = -17 + CGFloat(i) * 5.5
            let x = -9 + pow(CGFloat(i) - 1.5, 2) * 0.65
            drawLeaf(at: NSPoint(x: x, y: y), angle: -2.25, length: 9, color: color)
            drawLeaf(at: NSPoint(x: x, y: y), angle: -0.82, length: 8, color: color)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawStamp(center: NSPoint) {
        let color = Ink.blue.withAlphaComponent(content.tone == .valid ? 0.31 : 0.16)
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform(); t.translateX(by: center.x, yBy: center.y); t.rotate(byDegrees: -14); t.concat()
        for (radius, width): (CGFloat, CGFloat) in [(43, 1.2), (40, 0.5), (27, 0.9)] {
            let circle = NSBezierPath(ovalIn: NSRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2))
            color.setStroke(); circle.lineWidth = width; circle.stroke()
        }
        drawArcText("S T A C I O", radius: 33, start: -144, end: -36, color: color, bottom: false)
        drawArcText("S O F T W A R E", radius: 34, start: 151, end: 29, color: color, bottom: true)
        let script = NSFont(name: "SnellRoundhand", size: 25) ?? .systemFont(ofSize: 22, weight: .light)
        let signature = NSAttributedString(string: "Stacio", attributes: [.font: script, .foregroundColor: color.withAlphaComponent(color.alphaComponent + 0.15)])
        signature.draw(at: NSPoint(x: -signature.size().width / 2, y: -17))
        let flourish = NSBezierPath(); flourish.move(to: NSPoint(x: -25, y: 13)); flourish.curve(to: NSPoint(x: 25, y: 9), controlPoint1: NSPoint(x: -7, y: 2), controlPoint2: NSPoint(x: 16, y: 18))
        color.setStroke(); flourish.lineWidth = 0.6; flourish.stroke()
        for n in 0..<4 {
            let wave = NSBezierPath()
            for i in 0...65 {
                let x = CGFloat(i) + 35
                let y = CGFloat(n) * 7 - 9 + sin(x / 10) * 3
                if i == 0 { wave.move(to: NSPoint(x: x, y: y)) } else { wave.line(to: NSPoint(x: x, y: y)) }
            }
            color.withAlphaComponent(color.alphaComponent * 0.52).setStroke(); wave.lineWidth = 0.7; wave.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawArcText(_ text: String, radius: CGFloat, start: CGFloat, end: CGFloat, color: NSColor, bottom: Bool) {
        let chars = Array(text)
        for (i, character) in chars.enumerated() {
            let angle = (start + (end - start) * CGFloat(i) / CGFloat(max(1, chars.count - 1))) * .pi / 180
            NSGraphicsContext.saveGraphicsState()
            let t = NSAffineTransform(); t.translateX(by: cos(angle) * radius, yBy: sin(angle) * radius)
            t.rotate(byRadians: angle + (bottom ? -.pi / 2 : .pi / 2)); t.concat()
            let s = NSAttributedString(string: String(character), attributes: [.font: NSFont.systemFont(ofSize: 7.3, weight: .medium), .foregroundColor: color])
            s.draw(at: NSPoint(x: -s.size().width / 2, y: -s.size().height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func stroke(_ points: [NSPoint], color: NSColor, width: CGFloat) {
        let p = NSBezierPath()
        for (i, point) in points.enumerated() { if i == 0 { p.move(to: point) } else { p.line(to: point) } }
        color.setStroke(); p.lineWidth = width; p.stroke()
    }
}
