import Foundation

/// Build one POSIX terminal operation, including the existence check on the target host.
enum AgentConfigurationWrite {
    static func command(arguments: String) -> String? {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let path = args["path"] as? String, validPath(path),
              let expected = args["expected_sha256"] as? String,
              expected == "absent" || expected.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { return nil }
        guard let source = args["source"] as? String, validPath(source), source != path else { return nil }
        let script = #"""
        set -eu;
        p=$1; src=$2; expected=$3; dir=$(dirname "$p");
        [ -d "$dir" ] && [ -x "$dir" ] || { echo '无法读取暂存文件或访问目标目录' >&2; exit 1; };
        [ ! -L "$p" ] || { echo '请解析配置符号链接后使用实际文件路径' >&2; exit 1; };
        umask 077; tmp=$(mktemp -d "$dir/.stacio-config.XXXXXXXX"); trap 'rm -rf "$tmp"' 0;
        [ -f "$src" ] && [ -r "$src" ] || exit 1;
        conflict() { echo STACIO_CONFIG_CONFLICT; exit 1; };
        if [ -e "$p" ]; then
          [ -f "$p" ] || { echo '目标不是普通配置文件' >&2; exit 1; };
          cp -p "$p" "$tmp/original" && cmp -s "$p" "$tmp/original" || exit 1;
          [ "$expected" != absent ] || conflict;
          if command -v sha256sum >/dev/null; then digest=$(sha256sum < "$tmp/original"); else digest=$(shasum -a 256 < "$tmp/original"); fi;
          [ "${digest%% *}" = "$expected" ] || conflict;
          backup=$p.bak; if [ -e "$backup" ] || [ -L "$backup" ]; then backup=$p.bak.$(date +%Y%m%d-%H%M%S).$$; fi;
          link "$tmp/original" "$backup" || exit 1; printf 'STACIO_CONFIG_BACKUP %s\n' "$backup";
          cp -p "$p" "$tmp/new"; cat "$src" > "$tmp/new";
          cmp -s "$src" "$tmp/new" && cmp -s "$p" "$backup" || exit 1;
          mv -f "$tmp/new" "$p"; echo STACIO_CONFIG_WRITTEN;
        else
          [ "$expected" = absent ] || conflict; cat "$src" > "$tmp/new"; cmp -s "$src" "$tmp/new" && link "$tmp/new" "$p" || exit 1;
          echo STACIO_CONFIG_CREATED;
        fi
        """#
        return shell(script, [path, source, expected], args)
    }

    static func prepare(arguments: String) -> String? {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let path = args["path"] as? String, validPath(path) else { return nil }
        let script = #"""
        set -eu; p=$1; umask 077; [ -x "$(dirname "$p")" ] && [ ! -L "$p" ] || exit 1;
        tmp=$(mktemp -d /tmp/stacio-draft.XXXXXXXX); trap 'rm -rf "$tmp"' 0;
        if [ -e "$p" ]; then
          [ -f "$p" ] || exit 1; cat "$p" > "$tmp/draft";
          if command -v sha256sum >/dev/null; then digest=$(sha256sum < "$tmp/draft"); else digest=$(shasum -a 256 < "$tmp/draft"); fi;
        else digest=absent; : > "$tmp/draft"; fi;
        set -- $digest; printf 'STACIO_CONFIG_BASE %s\nSTACIO_CONFIG_DRAFT %s/draft\n' "$1" "$tmp"; trap - 0
        """#
        return shell(script, [path], args)
    }

    private static func shell(_ script: String, _ operands: [String], _ args: [String: Any]) -> String {
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let prefix = args["sudo"] as? Bool == true ? "sudo -n " : ""
        return prefix + "sh -c " + quote(script.components(separatedBy: "\n").joined(separator: " ")) + " stacio-config " + operands.map(quote).joined(separator: " ")
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.hasSuffix("/") && path.rangeOfCharacter(from: .controlCharacters) == nil
    }

    /// Only allow known receipts for this exact destination through the transcript filter.
    static func receipt(arguments: String, output: String) -> [String: String] {
        guard let args = try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any],
              let path = args["path"] as? String, validPath(path) else { return [:] }
        var result = ["path": path, "status": "unconfirmed"]
        for line in output.components(separatedBy: .newlines) {
            switch line {
            case "STACIO_CONFIG_CONFLICT": result["status"] = "conflict"
            case "STACIO_CONFIG_CREATED": result["status"] = "created"
            case "STACIO_CONFIG_WRITTEN": result["status"] = "written"
            case _ where line.range(of: #"\ASTACIO_CONFIG_BASE (?:absent|[0-9a-f]{64})\z"#, options: .regularExpression) != nil:
                result["expected_sha256"] = String(line.dropFirst("STACIO_CONFIG_BASE ".count))
            case _ where line.range(of: #"\ASTACIO_CONFIG_DRAFT /tmp/stacio-draft\.[A-Za-z0-9]{8}/draft\z"#, options: .regularExpression) != nil:
                result["source"] = String(line.dropFirst("STACIO_CONFIG_DRAFT ".count))
            default:
                let prefix = "STACIO_CONFIG_BACKUP " + path + ".bak"
                guard line.hasPrefix(prefix) else { continue }
                let suffix = String(line.dropFirst(prefix.count))
                if suffix.isEmpty || suffix.range(of: #"\A\.[0-9]{8}-[0-9]{6}\.[0-9]+\z"#, options: .regularExpression) != nil {
                    result["backup_path"] = path + ".bak" + suffix
                }
            }
        }
        if result["expected_sha256"] != nil && result["source"] != nil { result["status"] = "prepared" }
        return result
    }

    static func requiresStaging(_ command: String) -> Bool {
        let operand = #"[^\s;&|<>]+"#
        let target = #"[\x22']?(?:/(?:usr/local/)?etc/[^\s;&|<>]+|[^\s;&|<>]+\.(?:conf|config|ini|toml|yaml|yml|properties|env|json)[\x22']?(?=\s|$|[;&|]))"#
        let patterns = [
            #">{1,2}\s*"# + target,
            #"\btee\s+(?:-[\w-]+\s+)*"# + target,
            #"\b(?:sed|perl)\s+(?:[^;&|]*?\s)?-\w*i[^;&|]*?\s"# + target,
            #"(?:^|[;&|]\s*)(?:sudo\s+)?(?:cp|mv|install)\s+(?:"# + operand + #"\s+)+"# + target + #"(?=\s*(?:[;&|]|$))"#,
            #"\bdd\s+[^;&|]*?of="# + target,
            #"\btruncate\s+[^;&|]*?\s"# + target
        ]
        return patterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }
}
