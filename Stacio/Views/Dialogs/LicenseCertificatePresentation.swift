import Foundation

extension LicenseCertificateContent {
    /// The caller supplies the already evaluated authorization state. Metadata is
    /// additionally signature-checked; raw token payloads never become certificate text.
    static func make(state: LicenseState, verifier: SignedLicenseTokenVerifying) -> Self {
        var result = Self()
        result.username = state.username.isEmpty ? "—" : state.username
        result.email = state.email.isEmpty ? "—" : state.email
        switch state.plan.lowercased() {
        case "professional", "pro": result.plan = "专业版"
        case "enterprise", "team", "internal": result.plan = "企业版"
        case "trial": result.plan = "试用版"
        case "": result.plan = "未授权"
        default: result.plan = state.plan
        }
        result.validity = validityText(state.expiresAt)
        result.validityDetail = validityDetail(state.expiresAt)
        // Signed-token offline licenses have no offlineToken/device payload.
        // Only device authorizations establish that the license is machine-bound.
        let deviceBound = state.offlineDeviceAuthorization != nil
        let source: LicenseActivationSource?
        if deviceBound || state.offlineToken != nil {
            source = .offline
        } else if let savedSource = state.activationSource {
            source = savedSource
        } else if state.status == .offlineActive {
            source = .offline
        } else if [.active, .trial].contains(state.status) {
            source = .online
        } else {
            // Historical terminal states may not contain enough provenance.
            source = nil
        }
        let offline = source == .offline
        let method: String
        switch source {
        case .offline: method = deviceBound ? "离线文件 · 本机绑定" : "离线授权"
        case .online: method = "在线激活"
        case nil: method = state.signedLicenseToken.isEmpty ? "本机许可" : "签名许可"
        }
        result.metadataValue = state.status == .inactive ? "尚未激活" : method
        result.status = state.status.displayName
        switch state.status {
        case .active, .offlineActive:
            result.tone = .valid
            result.status = "授权有效"
            result.statement = "兹确认以下用户已获得 Stacio \(result.plan)的软件使用授权。"
            result.verification = "许可已在本机验证  ·  \(offline ? "离线授权" : "在线激活")"
            result.note = "本许可仅授予软件使用权，授权范围以许可条款为准。"
        case .trial:
            result.tone = .trial
            result.title = "软件试用许可"
            result.subtitle = "SOFTWARE TRIAL LICENSE"
            result.statement = "以下用户可在试用有效期内体验 Stacio 已授权功能。"
            result.verification = "试用许可有效  ·  请留意试用期限"
            result.note = "试用结束后，可导入正式许可证继续使用专业功能。"
        case .offlineGrace:
            result.tone = .grace
            result.statement = "当前许可处于离线宽限期，请同步许可以确认最新授权状态。"
            result.verification = "离线宽限期  ·  尚未确认服务器的最新状态"
            result.note = state.graceUntil.map { "宽限截止：\(readableDate($0))。请在到期前同步许可。" }
                ?? "请连接网络后同步许可，确认最新授权状态。"
        case .inactive:
            result.tone = .inactive
            result.title = "激活软件许可证"
            result.subtitle = "ACTIVATE YOUR SOFTWARE LICENSE"
            result.statement = "在线激活或导入离线授权文件后，即可查看你的软件授权证书。"
            result.verification = "许可证未激活  ·  当前未获得专业功能授权"
            result.note = "请在下方填写授权信息，或导入离线授权文件。"
        case .expired:
            result.tone = .problem
            result.statement = "此许可证已超过有效期，请更新授权后继续使用专业功能。"
            result.verification = "许可已过期  ·  当前不可用"
            result.note = "你可以同步最新许可，或重新导入有效许可证。"
        case .revoked, .suspended, .invalid:
            result.tone = .problem
            result.statement = "此许可证\(state.status.displayName)，当前不能作为有效的软件使用授权。"
            result.verification = "\(state.status.displayName)  ·  当前不可用"
            result.note = "请核对授权信息，或重新导入有效许可证。"
        case .networkUnavailable:
            result.tone = .grace
            result.statement = "暂时无法确认当前授权状态，请检查网络后重新同步许可。"
            result.verification = "授权状态待确认  ·  网络不可用"
            result.note = "同步失败不代表已取得或恢复软件授权。"
        }
        if !state.signedLicenseToken.isEmpty,
           let claims = try? verifier.verifiedClaims(from: state.signedLicenseToken),
           claims.username == state.username, claims.email == state.email,
           claims.plan == state.plan,
           let expiration = state.expiresAt, abs(claims.expiresAt.timeIntervalSince(expiration)) < 1 {
            if !claims.licenseID.isEmpty {
                result.metadataTitle = "许可编号"
                result.metadataValue = claims.licenseID
            }
            // A refreshed token can have a new issuedAt. Do not call it the original purchase date.
            result.issueTitle = "本次签发"
            result.issueValue = readableDate(claims.issuedAt)
        } else if let authorization = state.offlineDeviceAuthorization,
                  let issued = OfflineLicenseFileCodec.date(from: authorization.issuedAt) {
            result.issueTitle = "本次签发"
            result.issueValue = readableDate(issued)
        } else if let token = state.offlineToken {
            result.issueTitle = "本次签发"
            result.issueValue = readableDate(token.issuedAt)
        }
        return result
    }

    static func validityText(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        if isPerpetual(date) { return "永久授权" }
        return readableDate(date, timeZone: timeZone)
    }

    static func validityDetail(_ date: Date?, timeZone: TimeZone = .current) -> String {
        guard let date else { return "—" }
        if isPerpetual(date) { return "永久授权" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS OOOO"
        return formatter.string(from: date)
    }

    private static func isPerpetual(_ date: Date) -> Bool {
        // Backend contract: 9999-12-31T23:59:59[.999]Z. Check in UTC so local
        // timezone conversion cannot roll the sentinel into the year 10000.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return parts.year == 9999 && parts.month == 12 && parts.day == 31
            && parts.hour == 23 && parts.minute == 59 && parts.second == 59
    }

    static func readableDate(_ date: Date, includeTime: Bool = true, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = includeTime ? "yyyy-MM-dd HH:mm" : "yyyy 年 M 月 d 日"
        return formatter.string(from: date)
    }
}
