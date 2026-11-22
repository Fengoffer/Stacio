import AppKit
import ImageIO
import UniformTypeIdentifiers

/// The conversation owns its image files. Only small references enter the frequently saved transcript.
extension AgentContextChip {
    var imageFile: URL? {
        guard imageNumber != nil, let url = URL(string: uri), url.isFileURL else { return nil }
        return url
    }
}

enum AgentImages {
    static func thumbnail(_ url: URL, pixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    static func save(_ data: Data, in directory: URL, number: Int) throws -> AgentContextChip {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(id + ".png")
        try png.write(to: url, options: .atomic)
        var chip = AgentContextChip(id: id, kind: .file, label: "图片" + String(number), uri: url.absoluteString)
        chip.imageNumber = number
        return chip
    }

    static func content(text: String, images: [AgentContextChip]) throws -> Any {
        guard !images.isEmpty else { return text }
        var parts: [[String: Any]] = [["type": "text", "text": text.isEmpty ? "请分析附图。" : text]]
        for image in images {
            guard let url = image.imageFile else { throw CocoaError(.fileReadCorruptFile) }
            let data = try Data(contentsOf: url)
            parts.append(["type": "text", "text": "@" + image.label])
            parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + data.base64EncodedString()]])
        }
        return parts
    }
}

@MainActor
final class AgentImageTile: NSButton {
    let chip: AgentContextChip
    init(_ chip: AgentContextChip) {
        self.chip = chip
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyUpOrDown
        image = chip.imageFile.flatMap { AgentImages.thumbnail($0, pixels: 200) }
        toolTip = "@" + chip.label
        setAccessibilityLabel(chip.label)
        target = self
        action = #selector(preview)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        widthAnchor.constraint(equalToConstant: 66).isActive = true
        heightAnchor.constraint(equalToConstant: 60).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    @objc private func preview() {
        guard let host = window?.contentView, let url = chip.imageFile, let image = NSImage(contentsOf: url) else { return }
        let overlay = AgentImageOverlay(frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay)
        overlay.show(image)
        window?.makeFirstResponder(overlay)
    }
}

@MainActor
private final class AgentImageOverlay: NSView {
    private let picture = NSImageView()
    override var acceptsFirstResponder: Bool { true }
    func show(_ image: NSImage) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
        picture.image = image
        picture.imageScaling = .scaleProportionallyUpOrDown
        addSubview(picture)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "关闭预览")!, target: self, action: #selector(dismiss))
        close.isBordered = false
        close.contentTintColor = .white
        close.translatesAutoresizingMaskIntoConstraints = false
        addSubview(close)
        NSLayoutConstraint.activate([close.topAnchor.constraint(equalTo: topAnchor, constant: 14), close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16), close.widthAnchor.constraint(equalToConstant: 32), close.heightAnchor.constraint(equalToConstant: 32)])
        needsLayout = true
    }
    override func layout() {
        super.layout()
        guard let size = picture.image?.size, size.width > 0, size.height > 0 else { return }
        let scale = max(0, min((bounds.width - 48) / size.width, (bounds.height - 96) / size.height))
        let w = size.width * scale, h = size.height * scale
        picture.frame = NSRect(x: bounds.midX - w/2, y: bounds.midY - h/2, width: w, height: h)
    }
    override func mouseDown(with event: NSEvent) {
        if !picture.frame.contains(convert(event.locationInWindow, from: nil)) { dismiss() }
    }
    override func cancelOperation(_ sender: Any?) { dismiss() }
    @objc private func dismiss() { removeFromSuperview() }
}
