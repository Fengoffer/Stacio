import Foundation
import UserNotifications

/// 系统通知呈现（oh-my-zsh 资源下载完成等）。用于设置窗口关闭时仍能提示用户。
public enum OhMyZshNotificationPresenter {
    private static let resourceReadyIdentifier = "cn.stacio.ohmyzsh.resourceReady"
    private static let remoteDeploymentFailedIdentifier = "cn.stacio.ohmyzsh.remoteDeploymentFailed"

    /// 资源下载并加载完成后发送系统通知（用户可关闭设置窗口后台等待）。
    public static func postResourceReady(version: String?) {
        guard shouldSuppressNotifications == false else {
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Oh My Zsh 资源已就绪"
            if let version, !version.isEmpty {
                content.body = "资源 v\(version) 已下载并加载完成。现在可以在设置中启用 Oh My Zsh 并配置主题与插件。"
            } else {
                content.body = "资源已下载并加载完成。现在可以在设置中启用 Oh My Zsh 并配置主题与插件。"
            }
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: resourceReadyIdentifier,
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    public static func postRemoteDeploymentFailed(host: String, message: String) {
        guard shouldSuppressNotifications == false else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "远程 Oh My Zsh 部署失败"
            content.body = "\(host)：\(message)"
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "\(remoteDeploymentFailedIdentifier).\(host)",
                content: content,
                trigger: nil
            )
            center.add(request)
        }
    }

    private static var shouldSuppressNotifications: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if NSClassFromString("XCTest.XCTestCase") != nil || NSClassFromString("XCTestCase") != nil {
            return true
        }
        return false
    }
}
