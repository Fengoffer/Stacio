import AppKit

/// oh-my-zsh 主题的实时预览视图（P2）。
///
/// 工作原理：以目标主题运行 `zsh -f -c 'source .../oh-my-zsh.sh; print -rP -- "$PROMPT"'`，
/// 捕获真实渲染的提示符（含 ANSI 颜色），再用轻量 ANSI SGR 解析器转成富文本显示。
/// 渲染在后台队列执行，避免阻塞设置窗口。
public final class OhMyZshThemePreviewView: NSView {
    private let previewLabel = NSTextField(labelWithString: "")
    private let placeholderLabel = NSTextField(labelWithString: L10n.Settings.ohmyzshThemePreviewPlaceholder)
    private var renderTask: DispatchWorkItem?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 1).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor

        previewLabel.font = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        previewLabel.textColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2
        previewLabel.setAccessibilityIdentifier("Stacio.Settings.ohmyzshThemePreview")

        placeholderLabel.font = NSFont.systemFont(ofSize: 12)
        placeholderLabel.textColor = NSColor(calibratedWhite: 0.55, alpha: 1)
        placeholderLabel.stringValue = L10n.Settings.ohmyzshThemePreviewPlaceholder

        for label in [previewLabel, placeholderLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            previewLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            previewLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholderLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            placeholderLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        heightAnchor.constraint(equalToConstant: 56).isActive = true
        showPlaceholder()
    }

    // MARK: - 渲染

    public func render(theme: String, resourceDirectoryURL: URL?) {
        renderTask?.cancel()
        guard let resourceDirectoryURL else {
            showPlaceholder()
            return
        }
        showLoading()
        let task = DispatchWorkItem { [weak self] in
            let bytes = Self.renderPrompt(theme: theme, resourceDirectoryURL: resourceDirectoryURL)
            DispatchQueue.main.async {
                guard let self else { return }
                if bytes.isEmpty {
                    self.showPlaceholder()
                } else {
                    self.previewLabel.attributedStringValue = Self.attributedString(fromANSI: bytes)
                    self.previewLabel.isHidden = false
                    self.placeholderLabel.isHidden = true
                }
            }
        }
        renderTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    private func showPlaceholder() {
        previewLabel.isHidden = true
        placeholderLabel.isHidden = false
        placeholderLabel.stringValue = L10n.Settings.ohmyzshThemePreviewPlaceholder
    }

    private func showLoading() {
        previewLabel.isHidden = true
        placeholderLabel.isHidden = false
        placeholderLabel.stringValue = L10n.Settings.ohmyzshThemePreviewLoading
    }

    // MARK: - 渲染命令

    /// 以指定主题渲染提示符（输出含 ANSI SGR 码）。
    /// 渲染结果静态缓存（主题 + 资源路径为 key）：避免每次打开设置/切换分区
    /// 重建 pane 时重复启动 zsh 进程渲染同一主题（进程开销 + 8 秒上限等待）。
    private static let renderCacheLock = NSLock()
    private static var renderCache: [String: [UInt8]] = [:]

    static func renderPrompt(theme: String, resourceDirectoryURL: URL) -> [UInt8] {
        let cacheKey = "\(resourceDirectoryURL.path)|\(theme)"
        renderCacheLock.lock()
        if let cached = renderCache[cacheKey] {
            renderCacheLock.unlock()
            return cached
        }
        renderCacheLock.unlock()

        let sanitized = theme.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard !sanitized.isEmpty else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            "-f",
            "-c",
            "export ZSH=\"\(resourceDirectoryURL.path)\"; ZSH_THEME=\"\(sanitized)\"; source \"$ZSH/oh-my-zsh.sh\" 2>/dev/null; print -rP -- \"$PROMPT\""
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        // 主题渲染有极少数可能等待终端交互；给出 8 秒上限。
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        let bytes = Array(data)
        renderCacheLock.lock()
        renderCache[cacheKey] = bytes
        renderCacheLock.unlock()
        return bytes
    }

    // MARK: - ANSI 解析（轻量 SGR）

    private static let ansiForegroundColors: [UInt8: NSColor] = [
        30: NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.0, alpha: 1),
        31: NSColor(calibratedRed: 0.824, green: 0.282, blue: 0.282, alpha: 1),
        32: NSColor(calibratedRed: 0.482, green: 0.714, blue: 0.333, alpha: 1),
        33: NSColor(calibratedRed: 0.898, green: 0.663, blue: 0.298, alpha: 1),
        34: NSColor(calibratedRed: 0.353, green: 0.553, blue: 0.91, alpha: 1),
        35: NSColor(calibratedRed: 0.788, green: 0.494, blue: 0.812, alpha: 1),
        36: NSColor(calibratedRed: 0.416, green: 0.769, blue: 0.761, alpha: 1),
        37: NSColor(calibratedRed: 0.933, green: 0.933, blue: 0.933, alpha: 1),
        90: NSColor(calibratedRed: 0.4, green: 0.4, blue: 0.4, alpha: 1),
        91: NSColor(calibratedRed: 0.9, green: 0.5, blue: 0.5, alpha: 1),
        92: NSColor(calibratedRed: 0.6, green: 0.85, blue: 0.5, alpha: 1),
        93: NSColor(calibratedRed: 0.95, green: 0.8, blue: 0.5, alpha: 1),
        94: NSColor(calibratedRed: 0.6, green: 0.75, blue: 0.95, alpha: 1),
        95: NSColor(calibratedRed: 0.9, green: 0.65, blue: 0.9, alpha: 1),
        96: NSColor(calibratedRed: 0.6, green: 0.85, blue: 0.85, alpha: 1),
        97: NSColor(calibratedRed: 1.0, green: 1.0, blue: 1.0, alpha: 1)
    ]

    static func attributedString(fromANSI bytes: [UInt8]) -> NSAttributedString {
        let baseFont = NSFont(name: "Menlo", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let baseColor = NSColor(calibratedWhite: 0.9, alpha: 1)
        let result = NSMutableAttributedString(string: "", attributes: [.font: baseFont, .foregroundColor: baseColor])
        var currentColor = baseColor
        var bold = false
        var index = 0
        let length = bytes.count
        var plainChunk = [UInt8]()

        func flushPlain() {
            guard !plainChunk.isEmpty else { return }
            let str = String(decoding: plainChunk, as: UTF8.self)
            var attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: currentColor]
            if bold {
                if let boldFont = NSFont(name: "Menlo-Bold", size: 13) ?? NSFont(name: "Menlo-Bold", size: 13) {
                    attrs[.font] = boldFont
                }
            }
            result.append(NSAttributedString(string: str, attributes: attrs))
            plainChunk.removeAll(keepingCapacity: true)
        }

        while index < length {
            let byte = bytes[index]
            if byte == 0x1B, index + 1 < length, bytes[index + 1] == UInt8(ascii: "[") {
                // 解析 CSI
                var j = index + 2
                var params = [Int]()
                var current = ""
                while j < length {
                    let c = Character(UnicodeScalar(bytes[j]))
                    if c.isNumber {
                        current.append(c)
                    } else if c == ";" {
                        params.append(Int(current) ?? 0)
                        current = ""
                    } else if c == "m" {
                        if !current.isEmpty { params.append(Int(current) ?? 0) }
                        break
                    } else {
                        break
                    }
                    j += 1
                }
                flushPlain()
                // 应用 SGR
                var codes = params
                if codes.isEmpty { codes = [0] }
                var i = 0
                while i < codes.count {
                    let code = codes[i]
                    switch code {
                    case 0:
                        currentColor = baseColor
                        bold = false
                    case 1:
                        bold = true
                    case 30...37:
                        currentColor = ansiForegroundColors[UInt8(code)] ?? baseColor
                    case 38:
                        // 256 色：38;5;N 或 38;2;r;g;b —— 简单回退到 37
                        if i + 1 < codes.count, codes[i + 1] == 5, i + 2 < codes.count {
                            i += 2
                        }
                        currentColor = ansiForegroundColors[37] ?? baseColor
                    case 90...97:
                        currentColor = ansiForegroundColors[UInt8(code)] ?? baseColor
                    default:
                        break
                    }
                    i += 1
                }
                index = j + 1
            } else {
                plainChunk.append(byte)
                index += 1
            }
        }
        flushPlain()
        return result
    }
}
