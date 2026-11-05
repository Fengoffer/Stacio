import Foundation

public enum AgentOperationalDomain: String, CaseIterable, Codable, Equatable {
    case host
    case application
    case web
    case container
    case kubernetes
    case database
    case deployment
    case network
    case security
    case logs

    var guidance: String {
        switch self {
        case .host:
            return "主机：识别操作系统、资源压力、磁盘/inode、进程、时间和系统日志。"
        case .application:
            return "应用：识别运行时、进程管理器、配置来源、依赖、健康端点和应用日志。"
        case .web:
            return "Web：检查反向代理配置、虚拟主机、监听端口、上游、HTTP 状态和证书。"
        case .container:
            return "容器：检查镜像、容器状态、Compose 配置、挂载、网络、健康检查和日志。"
        case .kubernetes:
            return "Kubernetes：检查 context/namespace、工作负载、Pod、事件、探针、Service/Ingress 和 rollout。"
        case .database:
            return "数据库：识别引擎和版本，检查连接、容量、锁/慢查询、复制；变更前使用原生备份。"
        case .deployment:
            return "部署：确认版本、依赖、配置差异、备份、发布步骤、健康验证和回滚路径。"
        case .network:
            return "网络：检查 DNS、路由、监听端口、防火墙、连通性、TLS 和代理链路。"
        case .security:
            return "安全：检查权限、证书、暴露面和审计证据；不得读取或输出秘密值。"
        case .logs:
            return "日志：先限定时间窗和组件，再关联错误、请求、系统事件与变更时间线。"
        }
    }
}

public enum AgentOperationalDomainClassifier {
    public static func domains(for text: String) -> [AgentOperationalDomain] {
        let value = text.lowercased()
        return AgentOperationalDomain.allCases.filter { domain in
            keywords[domain, default: []].contains { value.contains($0) }
        }
    }

    public static func guidance(for text: String) -> String? {
        let selected = domains(for: text)
        guard selected.isEmpty == false else { return nil }
        return (["任务能力画像（由 Stacio 根据目标自动选择）："] + selected.map { "- \($0.guidance)" })
            .joined(separator: "\n")
    }

    private static let keywords: [AgentOperationalDomain: [String]] = [
        .host: ["服务器", "主机", "cpu", "内存", "磁盘", "inode", "负载", "进程"],
        .application: ["应用", "接口", "api", "java", "node", "python", "php", "进程管理", "健康"],
        .web: ["nginx", "apache", "httpd", "caddy", "haproxy", "反向代理", "虚拟主机", "http"],
        .container: ["docker", "compose", "podman", "容器", "镜像"],
        .kubernetes: ["kubernetes", "kubectl", "k8s", "pod", "deployment", "statefulset", "ingress"],
        .database: ["postgres", "postgresql", "mysql", "mariadb", "mongodb", "redis", "数据库", "sql", "慢查询", "主从", "复制"],
        .deployment: ["部署", "发布", "升级", "回滚", "上线", "迁移"],
        .network: ["网络", "端口", "dns", "路由", "丢包", "防火墙", "连通性"],
        .security: ["安全", "tls", "ssl", "证书", "权限", "漏洞", "审计"],
        .logs: ["日志", "journal", "log", "报错", "错误记录"]
    ]
}
