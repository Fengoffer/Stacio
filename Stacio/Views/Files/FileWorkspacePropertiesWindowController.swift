import AppKit
import StacioCoreBindings

public struct FileWorkspaceProperties: Equatable, Sendable {
    public let name: String
    public let path: String
    public let device: String
    public let kind: String
    public let size: UInt64?
    public let modifiedTime: String?
    public let owner: String?
    public let permissions: String?

    public init(
        name: String,
        path: String,
        device: String,
        kind: String,
        size: UInt64?,
        modifiedTime: String?,
        owner: String?,
        permissions: String?
    ) {
        self.name = name
        self.path = path
        self.device = device
        self.kind = kind
        self.size = size
        self.modifiedTime = modifiedTime
        self.owner = owner
        self.permissions = permissions
    }

    public static func local(url: URL, device: String) -> FileWorkspaceProperties {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileType = attributes?[.type] as? FileAttributeType
        let size = (attributes?[.size] as? NSNumber)?.uint64Value
        let modified = attributes?[.modificationDate] as? Date
        let permissions = (attributes?[.posixPermissions] as? NSNumber).map {
            String(format: "%04o", $0.intValue & 0o7777)
        }
        return FileWorkspaceProperties(
            name: url.lastPathComponent,
            path: url.path,
            device: device,
            kind: fileType == .typeDirectory ? "文件夹" : "文件",
            size: fileType == .typeDirectory ? nil : size,
            modifiedTime: modified.map { ISO8601DateFormatter().string(from: $0) },
            owner: attributes?[.ownerAccountName] as? String,
            permissions: permissions
        )
    }

    public static func remote(entry: RemoteFileEntry, device: String) -> FileWorkspaceProperties {
        let kind: String
        switch entry.kind {
        case .file: kind = "文件"
        case .directory: kind = "文件夹"
        case .symlink: kind = "链接"
        }
        return FileWorkspaceProperties(
            name: (entry.path as NSString).lastPathComponent,
            path: entry.path,
            device: device,
            kind: kind,
            size: entry.kind == .directory ? nil : entry.size,
            modifiedTime: entry.modifiedTime,
            owner: entry.owner,
            permissions: entry.permissions
        )
    }
}

@MainActor
public final class FileWorkspacePropertiesWindowController: NSWindowController {
    public let properties: FileWorkspaceProperties
    private let permissionsField = NSTextField(string: "")
    private let applyPermissionsButton = NSButton(title: "应用", target: nil, action: nil)
    private let onApplyPermissions: ((String) -> Void)?

    public init(
        properties: FileWorkspaceProperties,
        allowsPermissionEditing: Bool,
        onApplyPermissions: ((String) -> Void)? = nil
    ) {
        self.properties = properties
        self.onApplyPermissions = onApplyPermissions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 330),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "属性 - \(properties.name)"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        configureContent(allowsPermissionEditing: allowsPermissionEditing)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        nil
    }

    public var permissionsValueForTesting: String {
        permissionsField.stringValue
    }

    public var permissionsAreEditableForTesting: Bool {
        permissionsField.isEditable && permissionsField.isEnabled
    }

    public func applyPermissionsForTesting(_ value: String) {
        permissionsField.stringValue = value
        applyPermissions()
    }

    private func configureContent(allowsPermissionEditing: Bool) {
        guard let contentView = window?.contentView else { return }
        StacioDesignSystem.applyWorkspaceSurface(contentView)

        let grid = NSGridView(views: [
            row("名称", properties.name),
            row("位置", properties.path),
            row("设备", properties.device),
            row("类型", properties.kind),
            row("大小", sizeText),
            row("修改时间", properties.modifiedTime ?? "-"),
            row("所有者", properties.owner ?? "-")
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 14
        grid.xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        permissionsField.stringValue = properties.permissions ?? ""
        permissionsField.placeholderString = "例如 0644"
        permissionsField.isEditable = allowsPermissionEditing
        permissionsField.isEnabled = allowsPermissionEditing
        permissionsField.setAccessibilityIdentifier("Stacio.FileWorkspaceProperties.permissions")
        StacioDesignSystem.styleTextField(permissionsField)

        applyPermissionsButton.target = self
        applyPermissionsButton.action = #selector(applyPermissions)
        applyPermissionsButton.isEnabled = allowsPermissionEditing && onApplyPermissions != nil
        applyPermissionsButton.bezelStyle = .rounded
        StacioDesignSystem.stylePrimaryButton(applyPermissionsButton)

        let permissionsLabel = NSTextField(labelWithString: "权限")
        permissionsLabel.alignment = .right
        permissionsLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        let permissionRow = NSStackView(views: [permissionsLabel, permissionsField, applyPermissionsButton])
        permissionRow.orientation = .horizontal
        permissionRow.alignment = .centerY
        permissionRow.spacing = 10
        permissionRow.translatesAutoresizingMaskIntoConstraints = false
        permissionsLabel.widthAnchor.constraint(equalToConstant: 82).isActive = true
        applyPermissionsButton.widthAnchor.constraint(equalToConstant: 72).isActive = true

        contentView.addSubview(grid)
        contentView.addSubview(permissionRow)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            permissionRow.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            permissionRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            permissionRow.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 18),
            permissionRow.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -24)
        ])
    }

    private var sizeText: String {
        guard let size = properties.size else { return "-" }
        return ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)
    }

    private func row(_ title: String, _ value: String) -> [NSView] {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.alignment = .right
        titleLabel.textColor = StacioDesignSystem.theme.secondaryTextColor
        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.maximumNumberOfLines = 2
        return [titleLabel, valueLabel]
    }

    @objc private func applyPermissions() {
        let value = permissionsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidMode(value) else {
            NSSound.beep()
            return
        }
        onApplyPermissions?(value)
    }

    private static func isValidMode(_ value: String) -> Bool {
        let digits = value.hasPrefix("0") ? String(value.dropFirst()) : value
        return (3...4).contains(digits.count) && digits.allSatisfy { ("0"..."7").contains(String($0)) }
    }
}
