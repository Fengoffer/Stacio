import Foundation

enum TerminalCurrentDirectoryReporter {
    static func localShellEnvironment(base: [String], shellName: String? = nil) -> [String] {
        environmentDictionary(base)
            .merging(osc7Environment(shellName: shellName), uniquingKeysWith: { _, newValue in newValue })
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }

    static func osc7ReportFunctionScript() -> String {
        #"__stacio_cached_hostname="${__stacio_cached_hostname:-$(hostname 2>/dev/null || printf localhost)}"; __stacio_report_cwd() { printf '\033]7;file://%s%s\033\\' "$__stacio_cached_hostname" "$PWD"; }"#
    }

    static func remoteBootstrapScript() -> String {
        [
            shellCompatibleBootstrapScript(),
            "__stacio_report_cwd"
        ].joined(separator: "\n")
    }

    static func quietRemoteBootstrapCommand() -> String {
        let script = shellCompatibleBootstrapScript(separator: "; ")
        return "{ \(script); stty echo 2>/dev/null || true; } >/dev/null 2>&1; __stacio_report_cwd 2>/dev/null || true; stty echo 2>/dev/null || true; printf '\\r\\033[K'\n"
    }

    static func localBootstrapScript(shellName: String?) -> String? {
        switch shellName {
        case "zsh", "bash":
            return [
                shellCompatibleBootstrapScript(),
                "__stacio_report_cwd"
            ].joined(separator: "\n")
        case "fish":
            return [
                "set -q __stacio_cached_hostname; or set -g __stacio_cached_hostname (hostname 2>/dev/null; or printf localhost)",
                "function __stacio_report_cwd",
                "  printf '\\033]7;file://%s%s\\033\\\\' \"$__stacio_cached_hostname\" \"$PWD\"",
                "end",
                "functions -q __stacio_original_fish_prompt; or functions -c fish_prompt __stacio_original_fish_prompt 2>/dev/null; or true",
                "functions -q __stacio_original_fish_prompt; and function fish_prompt; __stacio_report_cwd; __stacio_original_fish_prompt; end",
                "__stacio_report_cwd"
            ].joined(separator: "\n")
        default:
            return nil
        }
    }

    private static func shellCompatibleBootstrapScript(separator: String = "\n") -> String {
        [
            osc7ReportFunctionScript(),
            "if [ -n \"${ZSH_VERSION:-}\" ]; then eval 'typeset -ga precmd_functions 2>/dev/null || true; case \" ${precmd_functions[*]-} \" in *\" __stacio_report_cwd \"*) ;; *) precmd_functions+=(__stacio_report_cwd) ;; esac'; fi",
            "if [ -n \"${BASH_VERSION:-}\" ]; then case \";${PROMPT_COMMAND:-};\" in *\";__stacio_report_cwd;\"*) ;; *) PROMPT_COMMAND=\"${PROMPT_COMMAND:+${PROMPT_COMMAND%;};}__stacio_report_cwd\" ;; esac; fi"
        ].joined(separator: separator)
    }

    private static func environmentDictionary(_ entries: [String]) -> [String: String] {
        var values: [String: String] = [:]
        for entry in entries {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0]] = parts[1]
        }
        return values
    }

    private static func osc7Environment(shellName: String?) -> [String: String] {
        guard let bootstrap = localBootstrapScript(shellName: shellName) else {
            return [:]
        }
        return [
            "STACIO_OSC7_ENABLED": "1",
            "STACIO_OSC7_BOOTSTRAP": bootstrap
        ]
    }
}

public enum TerminalOSC7ShellIntegration {
    public static func localBootstrapScript(shellName: String) -> String? {
        TerminalCurrentDirectoryReporter.localBootstrapScript(shellName: shellName)
    }

    public static func remoteBootstrapScript() -> String {
        TerminalCurrentDirectoryReporter.remoteBootstrapScript()
    }

    public static func quietRemoteBootstrapCommand() -> String {
        TerminalCurrentDirectoryReporter.quietRemoteBootstrapCommand()
    }
}
