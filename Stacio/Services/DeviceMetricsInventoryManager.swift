import Foundation

public struct ManagedProcessInfo: Equatable {
    public let pid: UInt32
    public let parentPID: UInt32
    public let user: String
    public let state: String
    public var cpuPercent: Double
    public var hasCPUUsage: Bool = true
    public var memoryPercent: Double
    public var hasMemoryUsage: Bool = true
    public var processIdentity: String? = nil
    public var residentBytes: UInt64
    public let virtualBytes: UInt64
    public let elapsed: String
    public let command: String

    public var isRunning: Bool {
        let state = state.uppercased()
        return state.hasPrefix("R")
    }

    public var isStopped: Bool {
        state.uppercased().hasPrefix("T")
    }

    public var statusLabel: String {
        switch state.uppercased().first {
        case "R": return "运行中"
        case "S", "I": return "睡眠"
        case "D": return "等待 I/O"
        case "T": return "暂停"
        case "Z": return "僵尸"
        default: return "未知"
        }
    }
}

public struct ManagedPortInfo: Equatable {
    public let id: String
    public let protocolName: String
    public let address: String
    public let port: UInt16
    public let processName: String
    public let pid: UInt32?
    public var processIdentity: String? = nil
}

public struct ManagedServiceInfo: Equatable {
    public let name: String
    public let loadState: String
    public let activeState: String
    public let subState: String
    public let description: String
    public var scope: String = "system"
}

public struct ManagedContainerInfo: Equatable {
    public let engine: String
    public let id: String
    public let name: String
    public let image: String
    public let status: String
    public let isRunning: Bool
    public let isPaused: Bool

    public init(engine: String = "docker", id: String, name: String, image: String, status: String, isRunning: Bool, isPaused: Bool) {
        self.engine = engine
        self.id = id
        self.name = name
        self.image = image
        self.status = status
        self.isRunning = isRunning
        self.isPaused = isPaused
    }
}

public enum ManagedProcessAction: Equatable {
    case pause
    case resume
    case terminate
    case forceTerminate
    case renice(Int)
}

public enum ManagedServiceAction: String, Equatable {
    case start
    case stop
    case restart
}

public enum ManagedContainerAction: String, Equatable {
    case start
    case stop
    case restart
    case pause
    case unpause
    case kill
}

public protocol DeviceMetricsInventoryManaging: AnyObject {
    func listManagedProcesses(completion: @escaping (Result<[ManagedProcessInfo], Error>) -> Void)
    func listManagedPorts(completion: @escaping (Result<[ManagedPortInfo], Error>) -> Void)
    func listManagedServices(completion: @escaping (Result<[ManagedServiceInfo], Error>) -> Void)
    func listManagedContainers(completion: @escaping (Result<[ManagedContainerInfo], Error>) -> Void)
    func performProcessAction(_ action: ManagedProcessAction, pid: UInt32, completion: @escaping (Result<Void, Error>) -> Void)
    func performProcessAction(_ action: ManagedProcessAction, pid: UInt32, expectedIdentity: String?, completion: @escaping (Result<Void, Error>) -> Void)
    func performServiceAction(_ action: ManagedServiceAction, name: String, scope: String, completion: @escaping (Result<Void, Error>) -> Void)
    func performContainerAction(_ action: ManagedContainerAction, id: String, engine: String, completion: @escaping (Result<Void, Error>) -> Void)
}

// Managers must explicitly opt into checked mutations. A legacy provider must
// never turn a captured identity into an unchecked PID-only operation.
extension DeviceMetricsInventoryManaging {
    public func performProcessAction(_ action: ManagedProcessAction, pid: UInt32, expectedIdentity: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        completion(.failure(DeviceMetricsInventoryError.commandFailed("无法验证进程身份，请刷新后重试。")))
    }
}

enum DeviceMetricsInventoryError: LocalizedError {
    case commandFailed(String)
    case authorizationRequired(String)
    case partialContainerInventory([ManagedContainerInfo], String, requiresAuthorization: Bool)
    case partialPortInventory([ManagedPortInfo], String, requiresAuthorization: Bool)
    case invalidArgument
    case invalidResponse

    var requiresAuthorization: Bool {
        switch self {
        case .authorizationRequired: return true
        case let .partialContainerInventory(_, _, required): return required
        case let .partialPortInventory(_, _, required): return required
        default: return false
        }
    }

    var partialContainers: [ManagedContainerInfo]? {
        if case let .partialContainerInventory(values, _, _) = self { return values }
        return nil
    }

    var partialPorts: [ManagedPortInfo]? {
        if case let .partialPortInventory(values, _, _) = self { return values }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case let .commandFailed(message): return message.isEmpty ? "远端命令执行失败" : message
        case let .authorizationRequired(message): return "当前账户权限不足，请使用 sudo 提权后重试。\n\(message)"
        case let .partialContainerInventory(_, message, _): return "部分容器读取失败。\n\(message)"
        case let .partialPortInventory(_, message, _): return message
        case .invalidArgument: return "无效的管理操作参数"
        case .invalidResponse: return "远端返回的数据格式无法识别，请刷新重试"
        }
    }
}

/// The same scoped password is used by read operations and confirmed mutations.
/// Never borrow the SSH login password or write credentials into command strings.
protocol DeviceMetricsInventoryAuthorizing: AnyObject {
    func authorizeInventorySudo(_ password: String, completion: @escaping (Result<Void, Error>) -> Void)
    func setInventorySudoPassword(_ password: String)
    func retryInventoryAuthorization()
}

extension DeviceMetricsInventoryAuthorizing {
    func retryInventoryAuthorization() {}
}

enum DeviceMetricsInventoryCommands {
    // Bound the ps/socket observation with process birth identities. If a PID
    // exits or is reused while collecting, its row remains readable but cannot
    // become a management target until a consistent refresh is available.
    private static let observations = #"""
    stacio_observe() {
      printf '__STACIO_IDENTITIES_%s__\n' "$1"
      if [ -r /proc/stat ] && command -v awk >/dev/null 2>&1; then
        awk -v memory="${2:-}" 'BEGIN {
          while ((getline < "/proc/stat") > 0) if ($1 == "btime") boot = $2
          close("/proc/stat")
          if (memory != "") while ((getline < "/proc/meminfo") > 0) if ($1 == "MemTotal:") total = $2
          close("/proc/meminfo")
          if (boot !~ /^[0-9]+$/) exit
          printf "boot %s %.0f\n", boot, total
          for (i = 1; i < ARGC; i++) {
            line = ""
            while ((getline part < ARGV[i]) > 0) line = line (line == "" ? "" : " ") part
            close(ARGV[i])
            pid = line; sub(/ .*/, "", pid); sub(/^.*\) /, "", line)
            n = split(line, f, /[ \t]+/)
            if (pid !~ /^[0-9]+$/ || n < 20 || f[20] !~ /^[0-9]+$/) continue
            rss = "-"
            path = ARGV[i]; sub(/stat$/, "status", path)
            if (memory != "") while ((getline part < path) > 0) {
              m = split(part, v, /[ \t]+/)
              if (v[1] == "VmRSS:" && v[2] ~ /^[0-9]+$/) rss = v[2]
            }
            close(path)
            printf "%s %s %s\n", pid, f[20], rss
          }
        }' /proc/[0-9]*/stat 2>/dev/null || true
      fi
      printf '__STACIO_IDENTITIES_END__\n'
    }
    """#

    static let processes = observations + "\n" + """
    umask 077
    stacio_process_owns_tmp=0
    if [ -n "${STACIO_COMMAND_TMPDIR:-}" ] && [ -d "$STACIO_COMMAND_TMPDIR" ]; then
      stacio_process_tmp="$STACIO_COMMAND_TMPDIR"
    elif command -v mktemp >/dev/null 2>&1; then
      stacio_process_owns_tmp=1
      stacio_process_tmp=$(mktemp -d "${TMPDIR:-/tmp}/stacio-processes.XXXXXX") || exit 1
    else
      stacio_process_owns_tmp=1
      stacio_process_tmp="${TMPDIR:-/tmp}/stacio-processes.$$"
      mkdir "$stacio_process_tmp" || exit 1
    fi
    trap 'rm -f "$stacio_process_tmp/out" "$stacio_process_tmp/identity"; [ "$stacio_process_owns_tmp" -eq 0 ] || rmdir "$stacio_process_tmp" 2>/dev/null || true' 0
    trap 'exit 130' 1 2 15
    stacio_observe BEFORE > "$stacio_process_tmp/identity"
    stacio_process_full_ps() {
      if "$@" > "$stacio_process_tmp/out" 2>/dev/null; then :; else return "$?"; fi
      # Minimal BusyBox ps can ignore every option and still exit successfully.
      # A custom PID header proves that the requested -o layout was honored.
      IFS=' \t' read -r stacio_process_header stacio_process_extra < "$stacio_process_tmp/out" || return 1
      [ "$stacio_process_header" = __STACIO_PROCESS_PID__ ] && [ -z "$stacio_process_extra" ] || return 1
      printf '__STACIO_PROCESS_FULL_PS__\\n'
      cat "$stacio_process_tmp/out"
    }
    stacio_process_collect() { printf '%s\\n' "$1"; shift; "$@" 2>/dev/null; }
    stacio_process_full_ps ps -eww -o pid=__STACIO_PROCESS_PID__ -o ppid= -o user= -o stat= -o pcpu= -o pmem= -o rss= -o vsz= -o etime= -o args= ||
    stacio_process_full_ps ps -eo pid=__STACIO_PROCESS_PID__ -o ppid= -o user= -o stat= -o pcpu= -o pmem= -o rss= -o vsz= -o etime= -o args= ||
    stacio_process_collect __STACIO_PROCESS_TOP__ top -b -n 1 ||
    stacio_process_collect __STACIO_PROCESS_PS__ ps ww ||
    stacio_process_collect __STACIO_PROCESS_PS__ ps
    stacio_process_status=$?
    [ "$stacio_process_status" -eq 0 ] || exit "$stacio_process_status"
    cat "$stacio_process_tmp/identity"
    printf '__STACIO_PROCESS_CPU_COUNTERS__\\n'
    if [ -r /proc/stat ] && command -v awk >/dev/null 2>&1; then
      # One awk process reads all counters; unreadable or exited processes are
      # skipped without spawning a shell or command for every PID.
      awk 'BEGIN {
        while ((getline line < "/proc/stat") > 0) {
          n = split(line, f, /[ \t]+/)
          if (f[1] == "cpu") { for (j = 2; j <= 9 && j <= n; j++) total += f[j] }
          else if (f[1] ~ /^cpu[0-9]+$/) { cores++; ids = ids (ids == "" ? "" : ",") f[1] }
          else if (f[1] == "btime") boot = f[2]
        }
        close("/proc/stat")
        if (cores < 1 || boot !~ /^[0-9]+$/ || total <= 0) exit
        printf "cpu %.0f %d %s %s\\n", total, cores, boot, ids
        for (i = 1; i < ARGC; i++) {
          line = ""
          while ((getline part < ARGV[i]) > 0) line = line (line == "" ? "" : " ") part
          if (line != "") {
            pid = line; sub(/ .*/, "", pid)
            # comm may contain spaces and parentheses; its final closing
            # parenthesis precedes the fixed numeric stat fields.
            sub(/^.*\\) /, "", line)
            n = split(line, f, /[ \t]+/)
            if (pid ~ /^[0-9]+$/ && n >= 20 && f[12] ~ /^[0-9]+$/ && f[13] ~ /^[0-9]+$/ && f[20] ~ /^[0-9]+$/)
              printf "%s %s %s %s\\n", pid, f[20], f[12], f[13]
          }
          close(ARGV[i])
        }
      }' /proc/[0-9]*/stat 2>/dev/null || true
    fi
    printf '__STACIO_PROCESS_CPU_COUNTERS_END__\\n'
    stacio_observe AFTER memory
    """
    static let ports = observations + "\n" + """
    stacio_port_owns_tmp=0
    if [ -n "${STACIO_COMMAND_TMPDIR:-}" ] && [ -d "$STACIO_COMMAND_TMPDIR" ]; then
      stacio_port_tmp="$STACIO_COMMAND_TMPDIR"
    elif command -v mktemp >/dev/null 2>&1; then
      stacio_port_owns_tmp=1
      stacio_port_tmp=$(mktemp -d "${TMPDIR:-/tmp}/stacio-ports.XXXXXX") || exit 1
    else
      stacio_port_owns_tmp=1
      stacio_port_tmp="${TMPDIR:-/tmp}/stacio-ports.$$"
      (umask 077; mkdir "$stacio_port_tmp") || exit 1
    fi
    trap 'rm -f "$stacio_port_tmp/out" "$stacio_port_tmp/err" "$stacio_port_tmp/errors" "$stacio_port_tmp/results"; [ "$stacio_port_owns_tmp" -eq 0 ] || rmdir "$stacio_port_tmp" 2>/dev/null || true' 0
    trap 'exit 130' 1 2 15
    : > "$stacio_port_tmp/errors"
    stacio_observe BEFORE > "$stacio_port_tmp/results"
    stacio_port_complete=0
    stacio_port_command() {
      if "$@" > "$stacio_port_tmp/out" 2> "$stacio_port_tmp/err"; then return 0; else stacio_port_status=$?; fi
      if [ "$1" = lsof ] && [ "$stacio_port_status" -eq 1 ] && [ ! -s "$stacio_port_tmp/out" ] && [ ! -s "$stacio_port_tmp/err" ]; then return 0; fi
      printf '%s (exit %s): ' "$*" "$stacio_port_status" >> "$stacio_port_tmp/errors"
      if [ -s "$stacio_port_tmp/err" ]; then cat "$stacio_port_tmp/err" >> "$stacio_port_tmp/errors"; else printf 'port collection failed\\n' >> "$stacio_port_tmp/errors"; fi
      return 1
    }
    stacio_port_emit() { { printf '%s\\n' "$1" "$2"; cat "$stacio_port_tmp/out"; printf '\\n'; } >> "$stacio_port_tmp/results"; }
    if command -v ss >/dev/null 2>&1; then
      stacio_ss4=0; stacio_ss6=0
      if stacio_port_command ss -H -4 -tulnp || stacio_port_command ss -4 -tulnp || stacio_port_command ss -H -f inet -tulnp || stacio_port_command ss -f inet -tulnp; then
        stacio_ss4=1; stacio_port_emit '__STACIO_SS__' '__STACIO_IPV4__'
      fi
      if stacio_port_command ss -H -6 -tulnp || stacio_port_command ss -6 -tulnp || stacio_port_command ss -H -f inet6 -tulnp || stacio_port_command ss -f inet6 -tulnp; then
        stacio_ss6=1; stacio_port_emit '__STACIO_SS__' '__STACIO_IPV6__'
      fi
      if [ "$stacio_ss4" -eq 1 ] && [ "$stacio_ss6" -eq 1 ]; then stacio_port_complete=1; fi
    fi
    if [ "$stacio_port_complete" -eq 0 ] && command -v netstat >/dev/null 2>&1; then
      if stacio_port_command netstat -lntup; then
        stacio_port_complete=1; stacio_port_emit '__STACIO_NETSTAT__' '__STACIO_IPV4__'
      else
        stacio_netstat_tcp=0; stacio_netstat_udp=0
        if stacio_port_command netstat -lntp || stacio_port_command netstat -anv -p tcp; then
          stacio_netstat_tcp=1; stacio_port_emit '__STACIO_NETSTAT__' '__STACIO_IPV4__'
        fi
        if stacio_port_command netstat -lnup || stacio_port_command netstat -anv -p udp; then
          stacio_netstat_udp=1; stacio_port_emit '__STACIO_NETSTAT__' '__STACIO_IPV4__'
        fi
        if [ "$stacio_netstat_tcp" -eq 1 ] && [ "$stacio_netstat_udp" -eq 1 ]; then
          stacio_port_complete=1
        elif stacio_port_command netstat -anp || stacio_port_command netstat -an; then
          stacio_port_complete=1; stacio_port_emit '__STACIO_NETSTAT__' '__STACIO_IPV4__'
        fi
      fi
    fi
    if [ "$stacio_port_complete" -eq 0 ] && command -v lsof >/dev/null 2>&1; then
      stacio_lsof_tcp=0; stacio_lsof_udp=0
      if stacio_port_command lsof -nP -iTCP -sTCP:LISTEN; then
        stacio_lsof_tcp=1; stacio_port_emit '__STACIO_LSOF__' '__STACIO_IPV4__'
      fi
      if stacio_port_command lsof -nP -iUDP; then
        stacio_lsof_udp=1; stacio_port_emit '__STACIO_LSOF__' '__STACIO_IPV4__'
      fi
      if [ "$stacio_lsof_tcp" -eq 1 ] && [ "$stacio_lsof_udp" -eq 1 ]; then stacio_port_complete=1; fi
    fi
    if [ "$stacio_port_complete" -eq 0 ]; then
      if [ -s "$stacio_port_tmp/errors" ]; then cat "$stacio_port_tmp/errors" >&2; else printf 'No supported port collection tool is available\\n' >&2; fi
      exit 1
    fi
    printf '__STACIO_PORTS_BEGIN__\\n'
    printf '__STACIO_PORT_UID__=%s\\n' "$(id -u 2>/dev/null || true)"
    cat "$stacio_port_tmp/results"
    printf '__STACIO_PORTS_END__\\n'
    stacio_observe AFTER
    """
    static let services = """
    printf '__STACIO_SERVICES_BEGIN__\\n'
    printf '__STACIO_SYSTEM__\\n'
    if command -v systemctl >/dev/null 2>&1; then
      systemctl list-units --type=service --all --no-legend --no-pager --plain --full 2>/dev/null || systemctl list-units --type=service --all --no-legend --no-pager --full 2>/dev/null || printf '__STACIO_SERVICES_ERROR__\\n'
    else
      printf '__STACIO_SERVICES_ERROR__\\n'
    fi
    printf '__STACIO_USER__\\n'
    systemctl --user list-units --type=service --all --no-legend --no-pager --plain --full 2>/dev/null || systemctl --user list-units --type=service --all --no-legend --no-pager --full 2>/dev/null || true
    printf '__STACIO_SERVICES_END__\\n'
    """
    static let containerEngines = """
    stacio_docker=$(command -v docker 2>/dev/null || true)
    stacio_podman=$(command -v podman 2>/dev/null || true)
    if [ -n "$stacio_docker" ]; then
      stacio_docker_is_podman=0
      if [ -n "$stacio_podman" ]; then
        if [ "$stacio_docker" -ef "$stacio_podman" ]; then
          stacio_docker_is_podman=1
        else
          case "$(docker --version 2>/dev/null)" in 'podman version '[0-9]*) stacio_docker_is_podman=1 ;; esac
        fi
      fi
      [ "$stacio_docker_is_podman" -eq 1 ] || printf 'docker\\n'
    fi
    [ -z "$stacio_podman" ] || printf 'podman\\n'
    """

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private static let commandTreeFunctions = """
    __stacio_kill_tree() { __stacio_children=''; if [ -r "/proc/$1/task/$1/children" ]; then __stacio_children=$(cat "/proc/$1/task/$1/children" 2>/dev/null || true); elif command -v pgrep >/dev/null 2>&1; then __stacio_children=$(pgrep -P "$1" 2>/dev/null || true); else __stacio_children=$(ps -o pid= --ppid "$1" 2>/dev/null || true); fi; for __stacio_child in $__stacio_children; do __stacio_kill_tree "$__stacio_child"; done; kill -KILL "$1" 2>/dev/null || true; }
    __stacio_kill_command() { if [ "$2" = 1 ]; then kill -KILL "-$1" 2>/dev/null || __stacio_kill_tree "$1"; else __stacio_kill_tree "$1"; fi; }
    """

    /// The privileged supervisor owns its private directory and survives the
    /// collector's timeout/SIGKILL. Its absolute deadline is earlier than the
    /// outer deadline, which still bounds sudo authentication itself.
    static func privilegedCollector(_ collector: String) -> String {
        let supervisor = """
        umask 077
        __stacio_script=$1; __stacio_deadline=$2
        case "$__stacio_deadline" in ''|*[!0-9]*) exit 125 ;; esac
        __stacio_now=$(date +%s) || exit 125
        case "$__stacio_now" in ''|*[!0-9]*) exit 125 ;; esac
        __stacio_delay=$((__stacio_deadline - __stacio_now))
        [ "$__stacio_delay" -gt 0 ] || exit 124
        [ "$__stacio_delay" -le 23 ] || __stacio_delay=23
        __stacio_tmp=$(mktemp -d /tmp/stacio-privileged.XXXXXX) || exit 125
        export STACIO_COMMAND_TMPDIR="$__stacio_tmp"
        __stacio_command_pid=''; __stacio_watchdog_pid=''; __stacio_command_reaped=0
        \(commandTreeFunctions)
        __stacio_cleanup() {
          trap - 0 1 2 15
          if [ -n "$__stacio_watchdog_pid" ]; then __stacio_kill_tree "$__stacio_watchdog_pid"; wait "$__stacio_watchdog_pid" 2>/dev/null || true; fi
          if [ -n "$__stacio_command_pid" ]; then
            if [ "$__stacio_command_reaped" -eq 0 ]; then __stacio_kill_command "$__stacio_command_pid" "$__stacio_command_group"; wait "$__stacio_command_pid" 2>/dev/null || true
            elif [ "$__stacio_command_group" -eq 1 ]; then kill -KILL "-$__stacio_command_pid" 2>/dev/null || true; fi
          fi
          rm -rf "$__stacio_tmp"
        }
        trap '__stacio_cleanup' 0
        trap 'exit 130' 1 2 15
        __stacio_now=$(date +%s) || exit 125
        case "$__stacio_now" in ''|*[!0-9]*) exit 125 ;; esac
        __stacio_delay=$((__stacio_deadline - __stacio_now))
        [ "$__stacio_delay" -gt 0 ] || exit 124
        [ "$__stacio_delay" -le 23 ] || __stacio_delay=23
        exec 3<&0
        if command -v setsid >/dev/null 2>&1; then
          setsid sh -c "$__stacio_script" <&3 3<&- & __stacio_command_group=1
        else
          # These process/port collectors run tools synchronously and never
          # daemonize. Without setsid, the watchdog kills their live tree.
          sh -c "$__stacio_script" <&3 3<&- & __stacio_command_group=0
        fi
        __stacio_command_pid=$!; exec 3<&-
        (sleep "$__stacio_delay"; printf timeout > "$__stacio_tmp/timedout"; __stacio_kill_command "$__stacio_command_pid" "$__stacio_command_group") >/dev/null 2>&1 & __stacio_watchdog_pid=$!
        wait "$__stacio_command_pid"; __stacio_status=$?; __stacio_command_reaped=1
        [ ! -f "$__stacio_tmp/timedout" ] || { printf 'Collector timed out\\n' >&2; exit 124; }
        exit "$__stacio_status"
        """
        // Keep the large collector as a separate argv word rather than
        // embedding it inside another already-quoted shell program.
        return "sh -c " + quote(supervisor) + " stacio-supervisor " + quote(collector) + " \"$STACIO_COMMAND_DEADLINE\""
    }

    /// Resolve under the login account before sudo applies secure_path. Keep
    /// the discovered executable as one argv word, never as shell source, and
    /// preserve sudoers rules that permit the engine but not a root shell.
    static func resolvedContainerCommand(_ command: String, engine: String, elevated: Bool, usesPassword: Bool) throws -> String {
        guard ["docker", "podman"].contains(engine), command.hasPrefix(engine + " ") else {
            throw DeviceMetricsInventoryError.invalidArgument
        }
        let arguments = command.dropFirst(engine.count + 1)
        let prefix = elevated ? (usesPassword ? "sudo -S -p '' " : "sudo -n ") : ""
        return """
        stacio_engine_executable=$(command -v \(engine) 2>/dev/null) || { printf 'Container executable unavailable\\n' >&2; exit 127; }
        case "$stacio_engine_executable" in /*) ;; *) stacio_engine_executable="$(pwd -P)/$stacio_engine_executable" ;; esac
        [ -f "$stacio_engine_executable" ] && [ -x "$stacio_engine_executable" ] || { printf 'Container executable unavailable\\n' >&2; exit 127; }
        \(prefix)"$stacio_engine_executable" \(arguments)
        """
    }

    static func boundedRemoteCommand(_ command: String) -> String {
        let script = "export LC_ALL=C LANG=C SYSTEMD_COLORS=0; export PATH=\"$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"; \(command)"
        let quoted = quote(script)
        // Isolate and cap output so descendants cannot keep the SSH pipe open
        // or grow memory without bound. `ulimit -f` uses 512-byte blocks.
        // Keep the script in the timeout runner only once. Duplicating it
        // across both timeout branches multiplies nested shell quoting; the
        // sudo collector otherwise exceeds libssh2's 34 KB request limit.
        let runner = "if command -v timeout >/dev/null 2>&1; then set -- timeout 25s; else set --; fi; exec \"$@\" sh -c \(quoted)"
        let quotedRunner = quote(runner)
        let wrapper = [
            "umask 077",
            "__stacio_started=$(date +%s) || exit 125; case \"$__stacio_started\" in ''|*[!0-9]*) exit 125 ;; esac; export STACIO_COMMAND_DEADLINE=$((__stacio_started + 23))",
            "if command -v mktemp >/dev/null 2>&1; then __stacio_tmp=$(mktemp -d \"${TMPDIR:-/tmp}/stacio-command.XXXXXX\" 2>/dev/null) || exit 125; else __stacio_tmp=\"${TMPDIR:-/tmp}/stacio-command.$$\"; mkdir \"$__stacio_tmp\" 2>/dev/null || exit 125; fi",
            // Ordinary collectors reuse this private directory. Privileged
            // collectors use their own same-UID supervisor and private scratch.
            "export STACIO_COMMAND_TMPDIR=\"$__stacio_tmp\"",
            // A non-interactive shell replaces stdin with /dev/null for an
            // asynchronous command unless it has an explicit redirection.
            "exec 3<&0",
            commandTreeFunctions,
            "__stacio_runner=\(quotedRunner)",
            "if command -v setsid >/dev/null 2>&1; then (ulimit -f 32768 2>/dev/null || true; exec setsid sh -c \"$__stacio_runner\") <&3 3<&- >\"$__stacio_tmp/output\" 2>&1 & __stacio_command_group=1; else (ulimit -f 32768 2>/dev/null || true; exec sh -c \"$__stacio_runner\") <&3 3<&- >\"$__stacio_tmp/output\" 2>&1 & __stacio_command_group=0; fi",
            "__stacio_command_pid=$!",
            "exec 3<&-",
            "(sleep 25; __stacio_kill_command \"$__stacio_command_pid\" \"$__stacio_command_group\") >/dev/null 2>&1 & __stacio_watchdog_pid=$!",
            "wait \"$__stacio_command_pid\"; __stacio_status=$?",
            "__stacio_kill_tree \"$__stacio_watchdog_pid\"; wait \"$__stacio_watchdog_pid\" 2>/dev/null || true",
            "cat \"$__stacio_tmp/output\" 2>/dev/null || true; rm -rf \"$__stacio_tmp\"",
            "exit \"$__stacio_status\"",
        ].joined(separator: "; ")
        // SSH exec starts in the account's login shell. Keep that command on
        // one line: csh/tcsh reject literal newlines even inside quoted words.
        // tcsh also expands ! for history inside single quotes.
        // fish consumes doubled backslashes even inside single quotes. Use
        // printf's portable octal escapes, which each login shell preserves,
        // and decode only in POSIX sh. Keep sudo credentials on separate stdin.
        let encoded = wrapper.replacingOccurrences(of: "\\", with: "\\0134")
            .replacingOccurrences(of: "\n", with: "\\0012")
            .replacingOccurrences(of: "\r", with: "\\0015")
            .replacingOccurrences(of: "!", with: "\\0041")
        return "exec sh -c " + quote("exec sh -c \"$(printf '%b' \"$1\")\"") + " stacio " + quote(encoded)
    }

    static func service(_ action: ManagedServiceAction, name: String, scope: String) throws -> String {
        guard ["system", "user"].contains(scope), name.hasSuffix(".service"), !name.hasPrefix("-"), name.count < 256,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || ".-_@:\\".contains($0)) })
        else { throw DeviceMetricsInventoryError.invalidArgument }
        return "systemctl \(scope == "user" ? "--user " : "")--no-ask-password \(action.rawValue) -- \(quote(name))"
    }

    static func container(_ action: ManagedContainerAction, id: String, engine: String) throws -> String {
        guard ["docker", "podman"].contains(engine), !id.isEmpty, id.count <= 64,
              id.allSatisfy({ $0.isASCII && $0.isHexDigit })
        else { throw DeviceMetricsInventoryError.invalidArgument }
        return "\(engine) \(action.rawValue) \(quote(id))"
    }

    static func process(_ action: ManagedProcessAction, pid: UInt32) throws -> String {
        guard pid > 1 else { throw DeviceMetricsInventoryError.invalidArgument }
        switch action {
        case .pause: return "kill -STOP \(pid)"
        case .resume: return "kill -CONT \(pid)"
        case .terminate: return "kill -TERM \(pid)"
        case .forceTerminate: return "kill -KILL \(pid)"
        case let .renice(value):
            guard (-20...19).contains(value) else { throw DeviceMetricsInventoryError.invalidArgument }
            return "renice \(value) -p \(pid)"
        }
    }

    static func checkedProcess(_ action: ManagedProcessAction, pid: UInt32, expectedIdentity: String?) throws -> String {
        let operation = try process(action, pid: pid)
        guard let expectedIdentity else {
            throw DeviceMetricsInventoryError.commandFailed("无法验证进程身份，请刷新后重试。")
        }
        let fields = expectedIdentity.split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              fields.allSatisfy({ UInt64($0) != nil }) else { throw DeviceMetricsInventoryError.invalidArgument }
        // Recheck immediately before each attempt, including sudo retries. The
        // expected birth identity was captured with the selected row, never
        // replaced by a lookup after a confirmation sheet has been open.
        let script = """
        stacio_identity=$(awk 'BEGIN { while ((getline < "/proc/stat") > 0) if ($1 == "btime") boot = $2; close("/proc/stat"); line = ""; while ((getline part < "/proc/\(pid)/stat") > 0) line = line (line == "" ? "" : " ") part; sub(/^.*\\) /, "", line); n = split(line, f, /[ \t]+/); if (boot ~ /^[0-9]+$/ && n >= 20 && f[20] ~ /^[0-9]+$/) printf "%s:%s", boot, f[20] }' 2>/dev/null)
        if [ "$stacio_identity" != \(quote(expectedIdentity)) ]; then printf '进程已退出、身份已变化或无法验证，请刷新后重试。\\n' >&2; exit 1; fi
        \(operation)
        """
        return "sh -c " + quote(script)
    }

    static func isPermissionError(_ value: String) -> Bool {
        let lower = value.lowercased()
        return ["permission denied", "operation not permitted", "access denied", "authentication is required",
                "interactive authentication required", "not authorized", "a password is required",
                "no password was provided"].contains { lower.contains($0) }
    }

    static func failureMessage(stdout: String, stderr: String) -> String {
        // The bounded runner merges the child's diagnostic stream into stdout.
        [stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    static func isSudoAuthenticationFailure(_ message: String) -> Bool {
        // Match sudo/sudo-rs diagnostics exactly rather than interpreting a
        // managed command's business error as a rejected credential.
        message.split(whereSeparator: \.isNewline).contains { line in
            let diagnostic = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return diagnostic == "sudo: a password is required"
                || diagnostic == "sudo: no password was provided"
                || diagnostic == "sudo: interactive authentication is required"
                || diagnostic == "sudo: Authentication required but not attempted"
                || diagnostic == "sudo: Incorrect authentication attempt"
                || diagnostic.range(of: #"^sudo: [0-9]+ incorrect password attempts?$"#, options: .regularExpression) != nil
                || diagnostic.range(of: #"^sudo: maximum [0-9]+ incorrect authentication attempts$"#, options: .regularExpression) != nil
        }
    }
}

/// Session-scoped interval counters for the management list. The lifetime
/// percentages from ps/top remain parser compatibility data, never live CPU.
final class ManagedProcessCPUSampler {
    private struct ProcessCounter {
        let startTime: UInt64
        let user: UInt64
        let system: UInt64
    }

    private struct Snapshot {
        let total: UInt64
        let cores: UInt32
        let bootTime: UInt64
        let coreIdentity: String
        let processes: [UInt32: ProcessCounter]

        init?(_ output: String) {
            let lines = output.split(whereSeparator: \.isNewline)
            guard let begin = lines.firstIndex(of: "__STACIO_PROCESS_CPU_COUNTERS__"),
                  let end = lines[lines.index(after: begin)...].firstIndex(of: "__STACIO_PROCESS_CPU_COUNTERS_END__"),
                  lines.distance(from: begin, to: end) >= 2 else { return nil }
            let headerIndex = lines.index(after: begin)
            let header = lines[headerIndex].split(whereSeparator: \.isWhitespace)
            guard header.count == 5, header[0] == "cpu", let total = UInt64(header[1]), total > 0,
                  let cores = UInt32(header[2]), cores > 0, let bootTime = UInt64(header[3]), bootTime > 0 else { return nil }
            let coreIDs = header[4].split(separator: ",")
            guard coreIDs.count == Int(cores), Set(coreIDs).count == coreIDs.count,
                  coreIDs.allSatisfy({ $0.hasPrefix("cpu") && UInt32($0.dropFirst(3)) != nil }) else { return nil }
            var processes: [UInt32: ProcessCounter] = [:]
            for line in lines[lines.index(after: headerIndex)..<end] {
                let fields = line.split(whereSeparator: \.isWhitespace)
                guard fields.count == 4, let pid = UInt32(fields[0]), pid > 0,
                      let startTime = UInt64(fields[1]), let user = UInt64(fields[2]), let system = UInt64(fields[3]),
                      processes[pid] == nil else { return nil }
                processes[pid] = ProcessCounter(startTime: startTime, user: user, system: system)
            }
            self.total = total
            self.cores = cores
            self.bootTime = bootTime
            self.coreIdentity = String(header[4])
            self.processes = processes
        }
    }

    private let lock = NSLock()
    private var nextRequest: UInt64 = 0
    private var lastAppliedRequest: UInt64 = 0
    private var previous: Snapshot?

    func beginRequest() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        nextRequest &+= 1
        return nextRequest
    }

    func fail(request: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard request > lastAppliedRequest else { return }
        lastAppliedRequest = request
        previous = nil
    }

    func apply(_ output: String, to values: [ManagedProcessInfo], request: UInt64) -> [ManagedProcessInfo] {
        let current = Snapshot(output)
        lock.lock()
        defer { lock.unlock() }
        // Concurrent SSH completions cannot rewind a newer baseline.
        guard request > lastAppliedRequest else { return withoutCPU(values) }
        lastAppliedRequest = request
        let old = previous
        previous = current
        guard let old, let current, old.bootTime == current.bootTime, old.cores == current.cores,
              old.coreIdentity == current.coreIdentity, current.total > old.total else { return withoutCPU(values) }
        let totalDelta = current.total - old.total
        return values.map { original in
            var value = original
            value.cpuPercent = 0
            value.hasCPUUsage = false
            guard let before = old.processes[value.pid], let after = current.processes[value.pid],
                  before.startTime == after.startTime, after.user >= before.user, after.system >= before.system else { return value }
            let (processDelta, overflow) = (after.user - before.user).addingReportingOverflow(after.system - before.system)
            // A process cannot consume more CPU time than all logical cores
            // together. Reject inconsistent samples instead of clamping them.
            guard !overflow, processDelta <= totalDelta else { return value }
            value.cpuPercent = Double(processDelta) / Double(totalDelta) * 100
            value.hasCPUUsage = true
            return value
        }
    }

    private func withoutCPU(_ values: [ManagedProcessInfo]) -> [ManagedProcessInfo] {
        values.map { original in
            var value = original
            value.cpuPercent = 0
            value.hasCPUUsage = false
            return value
        }
    }
}

/// Keep permission retries bounded while continuing to refresh visible listeners.
/// A reset or a newer request prevents old completions from replacing new state.
final class ManagedPortOwnershipState {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var preferElevation = false
    private var failure: DeviceMetricsInventoryError?

    func begin() -> (generation: UInt64, preferElevation: Bool, failure: DeviceMetricsInventoryError?) {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return (generation, preferElevation, failure)
    }

    func complete(_ request: UInt64, preferElevation: Bool, failure: DeviceMetricsInventoryError?) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == request else { return }
        self.preferElevation = preferElevation
        self.failure = failure
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        failure = nil
    }
}

extension CoreBridgeDeviceMetricsProvider: DeviceMetricsInventoryManaging, DeviceMetricsInventoryAuthorizing {
    public func authorizeInventorySudo(_ password: String, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !password.isEmpty, password.utf8.count < 4096,
              !password.contains("\n"), !password.contains("\r"), !password.contains("\0") else {
            DispatchQueue.main.async { completion(.failure(DeviceMetricsInventoryError.invalidArgument)) }
            return
        }
        inventoryStateLock.lock()
        inventorySudoAuthorizationGeneration &+= 1
        let generation = inventorySudoAuthorizationGeneration
        inventoryStateLock.unlock()
        inventoryOperation(completion) {
            // With -v, -k ignores an existing timestamp for this validation;
            // it does not invalidate unrelated tickets like a standalone -K.
            // A successful validation shares a credential, never a blanket
            // permission or a different rootless container identity.
            let result = try self.inventoryRunCommand("sudo -k -S -p '' -v", input: password + "\n")
            guard result.exitCode == 0 else {
                let message = DeviceMetricsInventoryCommands.failureMessage(stdout: result.stdout, stderr: result.stderr)
                if DeviceMetricsInventoryCommands.isSudoAuthenticationFailure(message) {
                    throw DeviceMetricsInventoryError.authorizationRequired(String(message.prefix(1500)))
                }
                throw DeviceMetricsInventoryError.commandFailed(message.isEmpty
                    ? "sudo 授权验证失败，退出码：\(result.exitCode)" : String(message.prefix(1500)))
            }
            self.inventoryStateLock.lock()
            guard self.inventorySudoAuthorizationGeneration == generation else {
                self.inventoryStateLock.unlock()
                throw DeviceMetricsInventoryError.commandFailed("授权请求已更新，请重试。")
            }
            // Publishing is a new credential generation as well: commands
            // started while validation was pending still used the old value,
            // even when the newly validated password has the same text.
            self.inventorySudoAuthorizationGeneration &+= 1
            self.inventorySudoPassword = password
            self.inventoryContainerAuthorizationFailures.removeAll()
            self.inventoryContainerAuthorizationGeneration &+= 1
            self.inventoryStateLock.unlock()
            self.inventoryPortOwnershipState.reset()
        }
    }

    public func setInventorySudoPassword(_ password: String) {
        inventoryStateLock.lock()
        inventorySudoAuthorizationGeneration &+= 1
        inventorySudoPassword = password
        inventoryContainerAuthorizationFailures.removeAll()
        inventoryContainerAuthorizationGeneration &+= 1
        inventoryStateLock.unlock()
        inventoryPortOwnershipState.reset()
    }

    public func retryInventoryAuthorization() {
        inventoryStateLock.lock()
        inventoryContainerAuthorizationFailures.removeAll()
        inventoryContainerAuthorizationGeneration &+= 1
        inventoryStateLock.unlock()
        inventoryPortOwnershipState.reset()
    }

    public func listManagedProcesses(completion: @escaping (Result<[ManagedProcessInfo], Error>) -> Void) {
        let request = inventoryProcessCPUSampler.beginRequest()
        inventoryOperation(completion) {
            do {
                self.inventoryStateLock.lock()
                let elevated = self.inventorySudoPassword != nil
                self.inventoryStateLock.unlock()
                let command = elevated ? DeviceMetricsInventoryCommands.privilegedCollector(DeviceMetricsInventoryCommands.processes)
                    : DeviceMetricsInventoryCommands.processes
                let output = try self.inventoryExecute(command, mayElevate: elevated,
                    fixedElevation: elevated, cacheElevation: false)
                let values = DeviceMetricsInventoryParser.processes(output)
                guard output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !values.isEmpty else {
                    throw DeviceMetricsInventoryError.invalidResponse
                }
                return self.inventoryProcessCPUSampler.apply(output, to: values, request: request)
            } catch {
                self.inventoryProcessCPUSampler.fail(request: request)
                throw error
            }
        }
    }

    public func listManagedPorts(completion: @escaping (Result<[ManagedPortInfo], Error>) -> Void) {
        let request = inventoryPortOwnershipState.begin()
        inventoryOperation(completion) {
            func collect(elevated: Bool) throws -> (values: [ManagedPortInfo], isRoot: Bool) {
                // The collector is a shell program, not an executable name.
                // Quote it as one sh argument before applying sudo exactly once.
                let command = elevated ? DeviceMetricsInventoryCommands.privilegedCollector(DeviceMetricsInventoryCommands.ports)
                    : DeviceMetricsInventoryCommands.ports
                let output = try self.inventoryExecute(command, mayElevate: elevated,
                    fixedElevation: elevated, cacheElevation: false)
                guard output.contains("__STACIO_PORTS_BEGIN__"), output.contains("__STACIO_PORTS_END__"),
                      !output.contains("__STACIO_PORTS_ERROR__") else {
                    throw DeviceMetricsInventoryError.invalidResponse
                }
                return (DeviceMetricsInventoryParser.ports(output),
                        output.split(whereSeparator: \.isNewline).contains("__STACIO_PORT_UID__=0"))
            }
            func partial(_ values: [ManagedPortInfo], error: DeviceMetricsInventoryError) -> DeviceMetricsInventoryError {
                let message = error.requiresAuthorization
                    ? "当前账户无法获取部分端口的进程信息。可通过 sudo 提权后重试。"
                    : error.localizedDescription
                return .partialPortInventory(values, message, requiresAuthorization: error.requiresAuthorization)
            }
            func finishElevated(_ values: [ManagedPortInfo]) throws -> [ManagedPortInfo] {
                let missing = values.contains { $0.pid == nil }
                let failure: DeviceMetricsInventoryError? = missing
                    ? .commandFailed("已以管理员权限读取，部分端口仍未返回进程信息。") : nil
                // A successful privileged read remains useful even when some
                // sockets have no visible owner. Keep that scope on refresh so
                // already-resolved root-owned processes do not disappear.
                self.inventoryPortOwnershipState.complete(request.generation, preferElevation: true, failure: nil)
                if let failure { throw partial(values, error: failure) }
                return values
            }
            var ownershipFailure = request.failure
            if request.preferElevation && ownershipFailure == nil {
                do {
                    let result = try collect(elevated: true)
                    return try finishElevated(result.values)
                } catch let error as DeviceMetricsInventoryError where error.partialPorts != nil {
                    throw error
                } catch {
                    ownershipFailure = (error as? DeviceMetricsInventoryError)
                        ?? .commandFailed("管理员读取失败：\(error.localizedDescription)")
                    self.inventoryPortOwnershipState.complete(request.generation, preferElevation: false, failure: ownershipFailure)
                }
            }
            let normal = try collect(elevated: false)
            guard normal.values.contains(where: { $0.pid == nil }) else {
                self.inventoryPortOwnershipState.complete(request.generation, preferElevation: false, failure: nil)
                return normal.values
            }
            if normal.isRoot {
                throw partial(normal.values, error: .commandFailed("当前采集工具未返回部分端口的进程信息。"))
            }
            if let ownershipFailure { throw partial(normal.values, error: ownershipFailure) }
            do {
                return try finishElevated(collect(elevated: true).values)
            } catch let error as DeviceMetricsInventoryError where error.partialPorts != nil {
                throw error
            } catch {
                let failure = (error as? DeviceMetricsInventoryError)
                    ?? .commandFailed("进程信息补充读取失败：\(error.localizedDescription)")
                self.inventoryPortOwnershipState.complete(request.generation, preferElevation: false, failure: failure)
                throw partial(normal.values, error: failure)
            }
        }
    }

    public func listManagedServices(completion: @escaping (Result<[ManagedServiceInfo], Error>) -> Void) {
        inventoryOperation(completion) {
            let output = try self.inventoryExecute(DeviceMetricsInventoryCommands.services)
            guard output.contains("__STACIO_SERVICES_BEGIN__"), output.contains("__STACIO_SERVICES_END__"),
                  !output.contains("__STACIO_SERVICES_ERROR__") else {
                throw DeviceMetricsInventoryError.invalidResponse
            }
            return DeviceMetricsInventoryParser.services(output)
        }
    }

    public func listManagedContainers(completion: @escaping (Result<[ManagedContainerInfo], Error>) -> Void) {
        inventoryOperation(completion) {
            let engines = try self.availableContainerEngines()
            var containers: [ManagedContainerInfo] = []
            var failures: [(engine: String, error: Error)] = []
            var successfulEngines = 0
            for engine in engines {
                self.inventoryStateLock.lock()
                let identity = self.inventoryContainerReadIdentity[engine]
                let authorizationFailure = self.inventoryContainerAuthorizationFailures[engine]
                let authorizationGeneration = self.inventoryContainerAuthorizationGeneration
                self.inventoryStateLock.unlock()
                if let authorizationFailure {
                    failures.append((engine, authorizationFailure))
                    continue
                }
                do {
                    var successfulElevation = false
                    let output = try self.inventoryExecute(engine + " ps -a --no-trunc --format '{{json .}}'", mayElevate: true, containerEngine: engine,
                        fixedElevation: identity, cacheElevation: false, didSucceed: { successfulElevation = $0 })
                    let normalizedOutput = DeviceMetricsInventoryParser.normalizedContainerOutput(output, engine: engine)
                    let values = DeviceMetricsInventoryParser.containers(normalizedOutput, engine: engine)
                    guard normalizedOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !values.isEmpty else {
                        throw DeviceMetricsInventoryError.invalidResponse
                    }
                    self.inventoryStateLock.lock()
                    self.inventoryContainerReadIdentity[engine] = successfulElevation
                    self.inventoryStateLock.unlock()
                    successfulEngines += 1
                    containers.append(contentsOf: values)
                } catch {
                    if let authorizationError = error as? DeviceMetricsInventoryError, authorizationError.requiresAuthorization {
                        self.inventoryStateLock.lock()
                        if authorizationGeneration == self.inventoryContainerAuthorizationGeneration {
                            self.inventoryContainerAuthorizationFailures[engine] = authorizationError
                        }
                        self.inventoryStateLock.unlock()
                    }
                    failures.append((engine, error))
                }
            }
            if !failures.isEmpty {
                let diagnostic = failures.map { "\($0.engine.capitalized)：\($0.error.localizedDescription)" }.joined(separator: "\n")
                let requiresAuthorization = failures.contains { ($0.error as? DeviceMetricsInventoryError)?.requiresAuthorization == true }
                if successfulEngines > 0 {
                    // Retain usable rows without claiming a complete inventory or
                    // losing the authorization path for the failed engine.
                    throw DeviceMetricsInventoryError.partialContainerInventory(containers, diagnostic, requiresAuthorization: requiresAuthorization)
                }
                if requiresAuthorization { throw DeviceMetricsInventoryError.authorizationRequired(diagnostic) }
                throw DeviceMetricsInventoryError.commandFailed(diagnostic)
            }
            return containers
        }
    }

    public func performProcessAction(_ action: ManagedProcessAction, pid: UInt32, completion: @escaping (Result<Void, Error>) -> Void) {
        performProcessAction(action, pid: pid, expectedIdentity: nil, completion: completion)
    }

    public func performProcessAction(_ action: ManagedProcessAction, pid: UInt32, expectedIdentity: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        inventoryOperation(completion) {
            let command = try DeviceMetricsInventoryCommands.checkedProcess(action, pid: pid, expectedIdentity: expectedIdentity)
            self.inventoryStateLock.lock()
            let elevated = self.inventorySudoPassword != nil
            self.inventoryStateLock.unlock()
            _ = try self.inventoryExecute(command, mayElevate: true,
                fixedElevation: elevated ? true : nil, cacheElevation: false)
        }
    }

    public func performServiceAction(_ action: ManagedServiceAction, name: String, scope: String, completion: @escaping (Result<Void, Error>) -> Void) {
        inventoryOperation(completion) {
            _ = try self.inventoryExecute(DeviceMetricsInventoryCommands.service(action, name: name, scope: scope), mayElevate: scope != "user")
        }
    }

    public func performContainerAction(_ action: ManagedContainerAction, id: String, engine: String, completion: @escaping (Result<Void, Error>) -> Void) {
        inventoryOperation(completion) {
            let command = try DeviceMetricsInventoryCommands.container(action, id: id, engine: engine)
            self.inventoryStateLock.lock()
            let identity = self.inventoryContainerReadIdentity[engine] ?? false
            self.inventoryStateLock.unlock()
            _ = try self.inventoryExecute(command, mayElevate: true, containerEngine: engine, fixedElevation: identity, cacheElevation: false)
        }
    }

    private func availableContainerEngines() throws -> [String] {
        let output = try inventoryExecute(DeviceMetricsInventoryCommands.containerEngines)
        let engines = output.split(whereSeparator: \.isNewline).map(String.init).filter { ["docker", "podman"].contains($0) }
        guard !engines.isEmpty else {
            throw DeviceMetricsInventoryError.commandFailed("未安装 Docker 或 Podman")
        }
        return engines
    }

    private func inventoryOperation<T>(_ completion: @escaping (Result<T, Error>) -> Void, operation: @escaping () throws -> T) {
        inventoryWorkerQueue.async {
            self.inventoryRequestSlots.wait()
            defer { self.inventoryRequestSlots.signal() }
            let result = Result(catching: operation)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func inventoryRunCommand(_ command: String, input: String? = nil) throws -> RemoteCommandResult {
        let boundedCommand = DeviceMetricsInventoryCommands.boundedRemoteCommand(command)
        // Leave headroom below libssh2's single-packet exec request limit.
        guard boundedCommand.utf8.count <= 32 * 1024 else {
            throw DeviceMetricsInventoryError.commandFailed("远程命令过长，无法通过 SSH 发送。")
        }
        return try CoreBridge.runLiveRemoteCommand(
            config: context.config, secret: context.secret,
            expectedFingerprintSHA256: context.expectedFingerprintSHA256,
            command: boundedCommand, standardInput: input
        )
    }

    private func inventoryExecute(_ command: String, mayElevate: Bool = false, containerEngine: String? = nil,
                                  fixedElevation: Bool? = nil, cacheElevation: Bool = true,
                                  didSucceed: ((Bool) -> Void)? = nil) throws -> String {
        let family = String(command.prefix { !$0.isWhitespace })
        inventoryStateLock.lock()
        var password = inventorySudoPassword
        var passwordGeneration = inventorySudoAuthorizationGeneration
        let elevated = fixedElevation ?? (mayElevate && cacheElevation && inventoryElevationRequired.contains(family))
        inventoryStateLock.unlock()
        func invocation(elevated: Bool, usesPassword: Bool) throws -> String {
            if let containerEngine {
                return try DeviceMetricsInventoryCommands.resolvedContainerCommand(command, engine: containerEngine,
                    elevated: elevated, usesPassword: usesPassword)
            }
            return elevated ? (usesPassword ? "sudo -S -p '' \(command)" : "sudo -n \(command)") : command
        }
        var result = try inventoryRunCommand(invocation(elevated: elevated, usesPassword: password != nil),
                                 input: elevated ? password.map { $0 + "\n" } : nil)
        var attemptedElevation = elevated
        if result.exitCode == 0 { didSucceed?(elevated); return result.stdout }
        let initialError = DeviceMetricsInventoryCommands.failureMessage(stdout: result.stdout, stderr: result.stderr)
        // A successful account-level container read pins the store. Retrying
        // that store's operations with sudo would target a different engine
        // context, so a permission failure must stay in its original scope.
        if !elevated && mayElevate && fixedElevation != false && DeviceMetricsInventoryCommands.isPermissionError(initialError) {
            inventoryStateLock.lock()
            if cacheElevation { inventoryElevationRequired.insert(family) }
            password = inventorySudoPassword
            passwordGeneration = inventorySudoAuthorizationGeneration
            inventoryStateLock.unlock()
            attemptedElevation = true
            result = try inventoryRunCommand(invocation(elevated: true, usesPassword: false))
            if result.exitCode == 0 { didSucceed?(true); return result.stdout }
            if DeviceMetricsInventoryCommands.isSudoAuthenticationFailure(DeviceMetricsInventoryCommands.failureMessage(stdout: result.stdout, stderr: result.stderr)), let password {
                result = try inventoryRunCommand(invocation(elevated: true, usesPassword: true), input: password + "\n")
                if result.exitCode == 0 { didSucceed?(true); return result.stdout }
            }
        }
        let message = DeviceMetricsInventoryCommands.failureMessage(stdout: result.stdout, stderr: result.stderr)
        if attemptedElevation && DeviceMetricsInventoryCommands.isSudoAuthenticationFailure(message) {
            inventoryStateLock.lock()
            // A stale request must not erase a password entered while its
            // remote command was still running.
            if inventorySudoAuthorizationGeneration == passwordGeneration && inventorySudoPassword == password {
                inventorySudoPassword = nil
            }
            inventoryStateLock.unlock()
            throw DeviceMetricsInventoryError.authorizationRequired(String(message.prefix(1500)))
        }
        throw DeviceMetricsInventoryError.commandFailed(message.isEmpty ? "远端命令退出码：\(result.exitCode)" : String(message.prefix(1500)))
    }
}

public enum DeviceMetricsInventoryParser {
    private struct ProcessObservation {
        let boot: UInt64
        let memoryKB: UInt64
        let rows: [UInt32: (start: UInt64, rssKB: UInt64?)]
    }

    private static func processObservation(_ output: String, phase: String) -> ProcessObservation? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let begin = lines.firstIndex(of: Substring("__STACIO_IDENTITIES_\(phase)__")),
              let end = lines[lines.index(after: begin)...].firstIndex(of: "__STACIO_IDENTITIES_END__"),
              lines.distance(from: begin, to: end) >= 2 else { return nil }
        let headerIndex = lines.index(after: begin)
        let header = lines[headerIndex].split(whereSeparator: \.isWhitespace)
        guard header.count == 3, header[0] == "boot", let boot = UInt64(header[1]), boot > 0,
              let memoryKB = UInt64(header[2]) else { return nil }
        var rows: [UInt32: (start: UInt64, rssKB: UInt64?)] = [:]
        for line in lines[lines.index(after: headerIndex)..<end] {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, let pid = UInt32(fields[0]), pid > 0, let start = UInt64(fields[1]),
                  fields[2] == "-" || UInt64(fields[2]) != nil, rows[pid] == nil else { return nil }
            rows[pid] = (start, UInt64(fields[2]))
        }
        return ProcessObservation(boot: boot, memoryKB: memoryKB, rows: rows)
    }

    private static func verifiedProcessObservations(_ output: String) -> [UInt32: (identity: String, rss: UInt64?, percent: Double?)] {
        guard let before = processObservation(output, phase: "BEFORE"),
              let after = processObservation(output, phase: "AFTER"), before.boot == after.boot else { return [:] }
        var result: [UInt32: (identity: String, rss: UInt64?, percent: Double?)] = [:]
        for (pid, value) in after.rows where before.rows[pid]?.start == value.start {
            let rss = value.rssKB.flatMap { $0 <= UInt64.max / 1024 ? $0 * 1024 : nil }
            result[pid] = ("\(after.boot):\(value.start)", rss,
                after.memoryKB > 0 ? value.rssKB.map { Double($0) / Double(after.memoryKB) * 100 } : nil)
        }
        return result
    }

    private enum ProcessFormat {
        case automatic, fullPS, top, ps, busyBoxPS, simplePS
    }

    // BusyBox prints a three-character STAT and five-character VSZ before
    // adjacent numeric fields. Parse the variable PID/user prefix separately.
    private static let fixedTopPrefix = try? NSRegularExpression(
        pattern: #"^\s*(\d+)\s+(\d+)\s+(\S+)\s+([RSDTtXZWPINUK][A-Za-z<+ ]{2})  (.{5})(.*)$"#
    )

    private struct TopProcessColumns {
        let memory: Int
        let cpu: Int?
        let core: Int?
        let command: Int
        let fixedTail: NSRegularExpression?

        init?(_ header: [String]) {
            guard let memory = header.firstIndex(of: "%VSZ"),
                  let command = header.firstIndex(of: "COMMAND"),
                  memory > 4, memory < command, command == header.count - 1 else { return nil }
            self.memory = memory
            cpu = header.firstIndex(of: "%CPU")
            core = header.firstIndex(of: "CPU")
            self.command = command
            // These are top.c's %3u.%c / %4u%% and optional " %3d"
            // fields. At 100.0, adjacent fields have no separating space.
            let percent = #"((?: {2}[0-9]| [1-9][0-9]|[1-9][0-9]{2,})\.[0-9]|(?: {3}[0-9]| {2}[1-9][0-9]| [1-9][0-9]{2}|[1-9][0-9]{3,})%)"#
            let processor = #" ( {2}[0-9]| [1-9][0-9]|[1-9][0-9]{2,})"#
            let expected = ["PID", "PPID", "USER", "STAT", "VSZ", "%VSZ"]
                + (core == nil ? [] : ["CPU"]) + (cpu == nil ? [] : ["%CPU"]) + ["COMMAND"]
            fixedTail = header == expected
                ? try? NSRegularExpression(pattern: "^" + percent + (core == nil ? "" : processor)
                    + (cpu == nil ? "" : percent) + #" (.+)$"#)
                : nil
        }
    }

    public static func processes(_ output: String) -> [ManagedProcessInfo] {
        var format = ProcessFormat.automatic
        var topColumns: TopProcessColumns?
        var sawTopHeader = false
        var values: [ManagedProcessInfo] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            // Counter records deliberately use a separate schema and must not
            // fall through to one of the permissive ps compatibility parsers.
            if line == "__STACIO_PROCESS_CPU_COUNTERS__" { break }
            let source: ProcessFormat?
            switch line {
            case "__STACIO_PROCESS_FULL_PS__": source = .fullPS
            case "__STACIO_PROCESS_TOP__": source = .top
            case "__STACIO_PROCESS_PS__": source = .ps
            default: source = nil
            }
            if let source {
                // Every fallback starts a fresh result. A failed collector may
                // have written partial stdout before returning nonzero.
                format = source
                topColumns = nil
                sawTopHeader = false
                values.removeAll(keepingCapacity: true)
                continue
            }
            let header = line.split(whereSeparator: \.isWhitespace).map { $0.uppercased() }
            if header.first == "PID" {
                if header.starts(with: ["PID", "USER", "VSZ", "STAT"]) { format = .busyBoxPS }
                else if header.starts(with: ["PID", "STAT", "TIME"]) { format = .simplePS }
                else if header.starts(with: ["PID", "PPID", "USER", "STAT", "VSZ"]) {
                    format = .top
                    sawTopHeader = true
                    topColumns = TopProcessColumns(header)
                }
                continue
            }
            if format == .top, sawTopHeader {
                // BusyBox builds configure CPU core and CPU usage columns
                // independently. Only %CPU is a utilization measurement.
                if let topColumns, let value = parseTopLine(String(rawLine), columns: topColumns) { values.append(value) }
            } else if let value = parseProcessLine(line, format: format) {
                values.append(value)
            }
        }
        let observations = verifiedProcessObservations(output)
        return values.map { original in
            var value = original
            if let observation = observations[value.pid] {
                value.processIdentity = observation.identity
                if let rss = observation.rss, let percent = observation.percent {
                    value.residentBytes = rss
                    value.memoryPercent = percent
                    value.hasMemoryUsage = true
                }
            }
            return value
        }
    }

    private static func parseTopLine(_ line: String, columns: TopProcessColumns) -> ManagedProcessInfo? {
        let fields: [String]
        if let fixedTopPrefix, let fixedTail = columns.fixedTail,
           let prefix = regexGroups(fixedTopPrefix, in: line),
           let tail = regexGroups(fixedTail, in: prefix[5]), let command = tail.last {
            // Match the entire numeric layout before splitting any joined
            // columns; keep the command remainder unchanged.
            fields = prefix.prefix(5).map { $0.trimmingCharacters(in: .whitespaces) }
                + tail.dropLast().map { $0.trimmingCharacters(in: .whitespaces) } + [command]
        } else {
            fields = splitFields(line, count: columns.command)
        }
        guard fields.count > columns.command,
              let pid = UInt32(fields[0]), let parentPID = UInt32(fields[1]),
              looksLikeProcessState(fields[3]), sizeBytes(fields[4]) != nil,
              percentage(fields[columns.memory]) != nil else { return nil }
        if let core = columns.core, UInt32(fields[core]) == nil { return nil }
        let cpu: Double
        if let index = columns.cpu {
            guard let value = percentage(fields[index]) else { return nil }
            cpu = max(0, value)
        } else {
            cpu = 0
        }
        return ManagedProcessInfo(pid: pid, parentPID: parentPID, user: fields[2], state: fields[3],
                                  cpuPercent: cpu, hasCPUUsage: columns.cpu != nil, memoryPercent: 0, hasMemoryUsage: false,
                                  residentBytes: 0, virtualBytes: kilobytes(fields[4]), elapsed: "", command: fields[columns.command])
    }

    private static func parseProcessLine(_ line: String, format: ProcessFormat) -> ManagedProcessInfo? {
        let fields = splitFields(line, count: 9)
        if format == .fullPS || format == .automatic {
            if fields.count >= 10,
               let pid = UInt32(fields[0]),
               let parentPID = UInt32(fields[1]),
               looksLikeProcessState(fields[3]),
               let cpu = percentage(fields[4]),
               let memory = percentage(fields[5]),
               sizeBytes(fields[6]) != nil, sizeBytes(fields[7]) != nil,
               looksLikeElapsed(fields[8]) {
                return ManagedProcessInfo(
                    pid: pid, parentPID: parentPID, user: fields[2], state: fields[3],
                    cpuPercent: max(0, cpu), memoryPercent: max(0, memory),
                    residentBytes: kilobytes(fields[6]), virtualBytes: kilobytes(fields[7]),
                    elapsed: fields[8], command: fields[9...].joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            // Production collectors declare the format, so malformed metrics
            // cannot fall through and be interpreted as another ps/top layout.
            if format == .fullPS { return nil }
            // Compatibility for old, unmarked snapshots only. Command words
            // such as ffmpeg must not be mistaken for full-ps metric columns.
            if fields.count >= 10, UInt32(fields[1]) != nil,
               looksLikeProcessState(fields[3]), looksLikeElapsed(fields[8]),
               Double(fields[4]) != nil || Double(fields[5]) != nil { return nil }
        }

        // Compatibility for older snapshots without a top header. Live top
        // output takes the explicit column mapping above.
        if (format == .top || format == .automatic),
           let groups = regexGroups(#"^(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\d+(?:[.,]\d+)?[kmgtpezy]?)\s+([\d.,]+)%?\s+(?:\d+\s+)?([\d.,]+)%?\s+(.+)$"#, in: line),
           groups.count == 8,
           let pid = UInt32(groups[0]), let parentPID = UInt32(groups[1]),
           sizeBytes(groups[4]) != nil,
           percentage(groups[5]) != nil, let cpu = percentage(groups[6]) {
            return ManagedProcessInfo(
                pid: pid, parentPID: parentPID, user: groups[2], state: groups[3],
                cpuPercent: max(0, cpu), memoryPercent: 0, hasMemoryUsage: false, residentBytes: 0,
                virtualBytes: kilobytes(groups[4]), elapsed: "", command: groups[7]
            )
        }

        // BusyBox `ps` variants expose either PID USER VSZ STAT COMMAND or
        // PID STAT TIME COMMAND. Keep command as the final remainder.
        let busyBoxPS = splitFields(line, count: 4)
        if (format == .ps || format == .busyBoxPS || format == .automatic),
           busyBoxPS.count >= 5, let pid = UInt32(busyBoxPS[0]),
           sizeBytes(busyBoxPS[2]) != nil, looksLikeProcessState(busyBoxPS[3]) {
            return ManagedProcessInfo(pid: pid, parentPID: 0, user: busyBoxPS[1], state: busyBoxPS[3], cpuPercent: 0, hasCPUUsage: false,
                                      memoryPercent: 0, hasMemoryUsage: false, residentBytes: 0, virtualBytes: kilobytes(busyBoxPS[2]), elapsed: "",
                                      command: busyBoxPS[4].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let simple = splitFields(line, count: 3)
        guard format == .ps || format == .simplePS || format == .automatic,
              simple.count >= 4, let pid = UInt32(simple[0]),
              looksLikeProcessState(simple[1]), looksLikeElapsed(simple[2]) else { return nil }
        return ManagedProcessInfo(pid: pid, parentPID: 0, user: "", state: simple[1], cpuPercent: 0, hasCPUUsage: false,
                                  memoryPercent: 0, hasMemoryUsage: false, residentBytes: 0, virtualBytes: 0, elapsed: simple[2],
                                  command: simple[3].trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private struct DarwinPortOwnerLayout {
        let ownerIndex: Int
        let trailingColumnCount: Int
        let includesProcessName: Bool
        let hasStateColumn: Bool

        init?(header: String) {
            let columns = header.lowercased()
                .replacingOccurrences(of: #"local\s+address"#, with: "local-address", options: .regularExpression)
                .replacingOccurrences(of: #"foreign\s+address"#, with: "foreign-address", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).map(String.init)
            guard columns.starts(with: ["proto", "recv-q", "send-q", "local-address", "foreign-address"]),
                  columns.contains("rhiwat"), columns.contains("shiwat"),
                  let index = columns.firstIndex(of: "process:pid") ?? columns.firstIndex(of: "pid") else { return nil }
            ownerIndex = index
            trailingColumnCount = columns.count - index - 1
            includesProcessName = columns[index] == "process:pid"
            hasStateColumn = columns[..<index].contains("(state)")
        }

        func owner(in parts: [String], localIndex: Int) -> (name: String, pid: UInt32)? {
            // Darwin leaves the TCP state column blank on UDP rows. Count
            // trailing columns so a process name containing spaces stays whole.
            let index = ownerIndex - (hasStateColumn && parts[0].lowercased().hasPrefix("udp") ? 1 : 0)
            let end = parts.count - trailingColumnCount
            guard localIndex == 3, index > localIndex + 1, index < end, end <= parts.count else { return nil }
            if includesProcessName {
                let value = parts[index..<end].joined(separator: " ")
                guard let colon = value.lastIndex(of: ":"), colon > value.startIndex,
                      let pid = UInt32(value[value.index(after: colon)...]), pid > 0 else { return nil }
                return (String(value[..<colon]), pid)
            }
            guard end == index + 1, let pid = UInt32(parts[index]), pid > 0 else { return nil }
            return ("", pid)
        }
    }

    public static func ports(_ output: String) -> [ManagedPortInfo] {
        var ipv6 = false
        var darwinOwnerLayout: DarwinPortOwnerLayout?
        var values: [ManagedPortInfo] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line == "__STACIO_IPV6__" { ipv6 = true; continue }
            if ["__STACIO_IPV4__", "__STACIO_SS__", "__STACIO_NETSTAT__", "__STACIO_LSOF__"].contains(line) {
                ipv6 = false
                darwinOwnerLayout = nil
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            if parts.first?.lowercased() == "proto" {
                darwinOwnerLayout = DarwinPortOwnerLayout(header: line)
                continue
            }
            guard parts.count >= 4,
                  !parts[0].lowercased().hasPrefix("netid"),
                  !parts[0].lowercased().hasPrefix("proto")
            else { continue }
            guard let localIndex = listeningSocketLocalIndex(parts) else { continue }
            let endpoint = parts[localIndex]
            let (address, port) = splitEndpoint(endpoint)
            guard let port else { continue }
            let rawProtocol = parts[0].lowercased()
            guard ["tcp", "tcp4", "tcp6", "tcp46", "udp", "udp4", "udp6", "udp46"].contains(rawProtocol) else { continue }
            var protocolName = rawProtocol.hasSuffix("46") ? String(rawProtocol.dropLast(2)) + "6" : rawProtocol.replacingOccurrences(of: "4", with: "").uppercased()
            protocolName = protocolName.uppercased()
            if (ipv6 || address.contains(":")), !protocolName.hasSuffix("6") { protocolName += "6" }
            // Expand every ss owner while the row's address-family marker is
            // still available. A dual-stack IPv6 wildcard is printed as "*".
            let ownerField = parts.dropFirst(localIndex + 2).joined(separator: " ")
            let users = localIndex == 4
                ? ownerField.range(of: "users:(").map { String(ownerField[$0.upperBound...]) } ?? "" : ""
            // iproute2 before the labelled pid/fd format printed
            // ("name",pid,fd). Only recognize that tuple inside users:(...).
            let pairs = (users.isEmpty ? [] : regexPairs(#"\("([^"]*)",pid=(\d+)"#, in: users)
                + regexPairs(#"\("([^"]*)",(\d+),\d+\)"#, in: users))
                .filter { UInt32($0.pid).map { $0 > 0 } == true }
            if pairs.isEmpty {
                let processName: String
                let pid: UInt32?
                if let darwinOwnerLayout {
                    let owner = darwinOwnerLayout.owner(in: parts, localIndex: localIndex)
                    processName = owner?.name ?? ""
                    pid = owner?.pid
                } else if localIndex == 3 {
                    // Linux/BusyBox netstat ends with PID/Program name. The
                    // command may contain spaces; do not scan endpoints or
                    // later command words for something resembling a PID.
                    let ownerIndex = localIndex + (rawProtocol.hasPrefix("udp") ? 2 : 3)
                    let fields = splitFields(line, count: ownerIndex)
                    if fields.count > ownerIndex,
                       let slash = fields[ownerIndex].firstIndex(of: "/"),
                       let ownerPID = UInt32(fields[ownerIndex][..<slash]), ownerPID > 0 {
                        processName = String(fields[ownerIndex][fields[ownerIndex].index(after: slash)...])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        pid = ownerPID
                    } else {
                        processName = ""
                        pid = nil
                    }
                } else {
                    processName = ""
                    pid = nil
                }
                values.append(ManagedPortInfo(id: "\(protocolName):\(endpoint):\(pid.map(String.init) ?? "-")", protocolName: protocolName, address: address, port: port, processName: processName, pid: pid))
            } else {
                for pair in pairs {
                    values.append(ManagedPortInfo(id: protocolName + ":" + endpoint + ":" + pair.pid, protocolName: protocolName, address: address, port: port, processName: pair.name, pid: UInt32(pair.pid)))
                }
            }
        }
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard parts.count >= 9, let rawPID = UInt32(parts[1]),
                  ["ipv4", "ipv6"].contains(parts[4].lowercased()),
                  ["tcp", "udp"].contains(parts[7].lowercased()) else { continue }
            // lsof's default columns are COMMAND PID USER FD TYPE DEVICE
            // SIZE/OFF NODE NAME. COMMAND and USER may themselves be tcp/udp.
            let rawProtocol = parts[7].lowercased()
            let endpoint = parts[8]
            let trailing = parts.dropFirst(9).map { $0.lowercased() }
            if rawProtocol == "tcp" && !trailing.contains("(listen)") { continue }
            if rawProtocol == "udp" && endpoint.contains("->") { continue }
            let (address, port) = splitEndpoint(endpoint)
            guard let port else { continue }
            let isIPv6 = parts[4].lowercased() == "ipv6" || address.contains(":")
            let protocolName = rawProtocol.uppercased() + (isIPv6 ? "6" : "")
            let pid = rawPID > 0 ? rawPID : nil
            values.append(ManagedPortInfo(
                id: protocolName + ":" + endpoint + ":" + (pid.map(String.init) ?? "-"),
                protocolName: protocolName,
                address: address,
                port: port,
                processName: pid == nil ? "" : parts[0],
                pid: pid
            ))
        }
        var unique: [String: ManagedPortInfo] = [:]
        var socketsWithOwners = Set<String>()
        for value in values {
            let normalizedAddress = ["0.0.0.0", "::"].contains(value.address) ? "*" : value.address
            let socketKey = value.protocolName + "|" + normalizedAddress + "|" + String(value.port)
            if let pid = value.pid {
                socketsWithOwners.insert(socketKey)
                unique.removeValue(forKey: socketKey + "|-")
                let key = socketKey + "|" + String(pid)
                if let existing = unique[key], !existing.processName.isEmpty, value.processName.isEmpty {
                    continue
                }
                unique[key] = value
            } else if !socketsWithOwners.contains(socketKey) {
                unique[socketKey + "|-"] = value
            }
        }
        let observations = verifiedProcessObservations(output)
        return unique.values.map { original in
            var value = original
            value.processIdentity = value.pid.flatMap { observations[$0]?.identity }
            return value
        }.sorted { $0.port == $1.port ? $0.id < $1.id : $0.port < $1.port }
    }

    public static func services(_ output: String) -> [ManagedServiceInfo] {
        var scope = "system"
        var values: [String: ManagedServiceInfo] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "__STACIO_SYSTEM__" { scope = "system"; continue }
            if line == "__STACIO_USER__" { scope = "user"; continue }
            let fields = splitFields(line.hasPrefix("●") ? String(line.dropFirst()) : line, count: 4)
            guard fields.count >= 4, fields[0].hasSuffix(".service") else { continue }
            // Match Netcatty's merged inventory: system units take precedence over names shared with user units.
            if values[fields[0]]?.scope == "system" { continue }
            values[fields[0]] = ManagedServiceInfo(name: fields[0], loadState: fields[1], activeState: fields[2], subState: fields[3], description: fields.dropFirst(4).joined(separator: " "), scope: scope)
        }
        return values.values.sorted {
            if ($0.activeState == "failed") != ($1.activeState == "failed") { return $0.activeState == "failed" }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static let podmanDockerCompatibilityWarning =
        "Emulate Docker CLI using podman. Create /etc/containers/nodocker to quiet msg."

    static func normalizedContainerOutput(_ output: String, engine: String = "docker") -> String {
        guard engine == "docker" else { return output }
        return output.split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter {
                let line = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                return line != podmanDockerCompatibilityWarning
            }
            .joined(separator: "\n")
    }

    public static func containers(_ output: String, engine: String = "docker") -> [ManagedContainerInfo] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            if let data = line.data(using: .utf8), let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let id = (value["ID"] ?? value["Id"]) as? String, !id.isEmpty {
                let name = value["Names"] as? String ?? (value["Names"] as? [String])?.joined(separator: ", ") ?? String(id.prefix(12))
                let state = (value["State"] as? String ?? "").lowercased()
                let status = value["Status"] as? String ?? state
                let paused = state == "paused" || status.lowercased().contains("paused")
                return ManagedContainerInfo(engine: engine, id: id, name: name, image: value["Image"] as? String ?? "", status: status,
                    isRunning: !paused && (state == "running" || (state.isEmpty && status.lowercased().hasPrefix("up"))), isPaused: paused)
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { return nil }
            let status = fields[3]
            let lower = status.lowercased()
            return ManagedContainerInfo(
                engine: engine, id: fields[0], name: fields[1], image: fields[2], status: status,
                isRunning: lower.hasPrefix("up") && !lower.contains("paused"),
                isPaused: lower.contains("paused")
            )
        }
    }

    private static func percentage(_ value: String) -> Double? {
        let normalized = value.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: CharacterSet(charactersIn: "%"))
        guard let number = Double(normalized), number.isFinite else { return nil }
        return number
    }

    private static func looksLikeElapsed(_ value: String) -> Bool {
        value.range(of: #"^(?:\d+-)?(?:\d{1,2}:)?\d{1,2}:\d{2}$"#, options: .regularExpression) != nil
    }

    private static func looksLikeProcessState(_ value: String) -> Bool {
        value.range(of: #"^[RSDTtXZWPINUK][A-Za-z<+]*$"#, options: .regularExpression) != nil
    }

    private static func listeningSocketLocalIndex(_ parts: [String]) -> Int? {
        guard parts.count >= 5 else { return nil }
        let isUDP = parts[0].lowercased().hasPrefix("udp")
        // ss puts state before the queue sizes; netstat puts TCP state after
        // the endpoints. UDP has no LISTEN state, so its peer must be unbound.
        let hasLeadingState = UInt64(parts[1]) == nil
        let localIndex = hasLeadingState ? 4 : 3
        guard parts.indices.contains(localIndex + 1),
              UInt64(parts[localIndex - 2]) != nil,
              UInt64(parts[localIndex - 1]) != nil else { return nil }
        if hasLeadingState {
            let state = parts[1].lowercased()
            guard isUDP ? ["unconn", "idle", "listen"].contains(state) : state == "listen" else { return nil }
        } else if !isUDP {
            guard parts.indices.contains(localIndex + 2), parts[localIndex + 2].lowercased() == "listen" else { return nil }
        }
        if isUDP {
            let peer = parts[localIndex + 1]
            guard ["*.*", "*:*", "0.0.0.0:*", ":::*", "[::]:*", "*."].contains(peer) else { return nil }
        }
        return localIndex
    }

    private static func kilobytes(_ value: String) -> UInt64 {
        guard let number = sizeBytes(value), number <= UInt64.max / 1024 else { return 0 }
        return number * 1024
    }

    private static func sizeBytes(_ value: String) -> UInt64? {
        let normalized = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        let suffix = normalized.last
        let numberText = suffix.map { "kmgtpezy".contains($0) ? String(normalized.dropLast()) : normalized } ?? normalized
        guard let number = Double(numberText), number.isFinite, number >= 0 else {
            return UInt64(normalized)
        }
        let multiplier: Double
        switch suffix {
        case "m": multiplier = 1024
        case "g": multiplier = 1024 * 1024
        case "t": multiplier = 1024 * 1024 * 1024
        case "k": multiplier = 1
        default: multiplier = 1
        }
        let result = number * multiplier
        // Double(UInt64.max) rounds up to 2^64. Comparing with that value
        // before a trapping conversion still accepts an out-of-range value.
        return UInt64(exactly: result.rounded())
    }

    private static func splitFields(_ line: String, count: Int) -> [String] {
        var result: [String] = []
        var index = line.startIndex
        while result.count < count, index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
            guard index < line.endIndex else { break }
            let start = index
            while index < line.endIndex, !line[index].isWhitespace { index = line.index(after: index) }
            result.append(String(line[start..<index]))
        }
        if index < line.endIndex {
            while index < line.endIndex, line[index].isWhitespace { index = line.index(after: index) }
            result.append(String(line[index...]))
        }
        return result
    }

    private static func splitEndpoint(_ endpoint: String) -> (String, UInt16?) {
        if endpoint.hasPrefix("[") {
            guard let close = endpoint.lastIndex(of: "]") else { return (endpoint, nil) }
            let address = String(endpoint[endpoint.index(after: endpoint.startIndex)..<close])
            let port = UInt16(endpoint[endpoint.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: ":")))
            return (address, port)
        }
        if let separator = endpoint.lastIndex(of: "."),
           separator > endpoint.startIndex,
           let port = UInt16(endpoint[endpoint.index(after: separator)...]) {
            return (String(endpoint[..<separator]), port)
        }
        guard let separator = endpoint.lastIndex(of: ":") else { return (endpoint, nil) }
        return (String(endpoint[..<separator]), UInt16(endpoint[endpoint.index(after: separator)...]))
    }

    private static func regexCapture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value)
        else { return nil }
        return String(value[range])
    }

    private static func regexGroups(_ pattern: String, in value: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regexGroups(regex, in: value)
    }

    private static func regexGroups(_ regex: NSRegularExpression, in value: String) -> [String]? {
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return String(value[range])
        }
    }

    private static func regexPairs(_ pattern: String, in value: String) -> [(name: String, pid: String)] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..., in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 2,
                  let nameRange = Range(match.range(at: 1), in: value),
                  let pidRange = Range(match.range(at: 2), in: value)
            else { return nil }
            return (String(value[nameRange]), String(value[pidRange]))
        }
    }
}
