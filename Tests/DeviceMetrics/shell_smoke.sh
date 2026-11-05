#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_SHELL_CHECK_DIR="$(mktemp -d /tmp/stacio-shell-check.XXXXXX)"
trap 'rm -rf "$STACIO_SHELL_CHECK_DIR"' EXIT
python3 - "$ROOT" "$STACIO_SHELL_CHECK_DIR" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Stacio/Services/DeviceMetricsInventoryManager.swift').read_text()
start = source.index('extension CoreBridgeDeviceMetricsProvider:')
end = source.index('public enum DeviceMetricsInventoryParser', start)
(out / 'InventoryModels.swift').write_text(source[:start] + source[end:])
PY
cat > "$STACIO_SHELL_CHECK_DIR/Commands.swift" <<'SWIFT'
import Foundation
@main struct Commands {
    static func main() throws {
        let literal = "单引号'与双引号\"、反斜杠\\n\\c、$HOME、$(printf unexpected)、`printf unexpected`、!history、\\0041、\\\\、\\0134、末尾\\"
        let serviceNames = ["review.service", "review@foo\\x2dbar.service", "review@foo\\x20bar.service",
                            "review@foo\\x5cbar.service", "review@foo\\x27bar.service"]
        var scripts = [
            "printf stacio-ok",
            "# Preserve script line boundaries\nprintf '%s\\n' " + DeviceMetricsInventoryCommands.quote(literal) + "\nprintf second",
            "IFS= read -r value\nprintf '%s' \"$value\"",
            "printf partial\nprintf diagnostic >&2\nexit 7",
            DeviceMetricsInventoryCommands.processes,
        ]
        scripts += try serviceNames.map {
            try DeviceMetricsInventoryCommands.service(.restart, name: $0, scope: "system")
        }
        let commands = scripts.map(DeviceMetricsInventoryCommands.boundedRemoteCommand)
        precondition(commands.allSatisfy { !$0.contains("\n") && !$0.contains("\r") && !$0.contains("!") })
        let data = try JSONSerialization.data(withJSONObject: ["commands": commands, "literal": literal, "serviceNames": serviceNames])
        FileHandle.standardOutput.write(data)
    }
}
SWIFT
STACIO_SHELL_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_SHELL_CHECK_SDK" -o "$STACIO_SHELL_CHECK_DIR/commands" \
  "$STACIO_SHELL_CHECK_DIR/InventoryModels.swift" "$STACIO_SHELL_CHECK_DIR/Commands.swift"
"$STACIO_SHELL_CHECK_DIR/commands" > "$STACIO_SHELL_CHECK_DIR/commands.json"
python3 - "$STACIO_SHELL_CHECK_DIR" <<'PY'
from pathlib import Path
import json, os, shutil, subprocess, sys
directory = Path(sys.argv[1])
data = json.loads((directory / 'commands.json').read_text())
scratch = directory / 'scratch'
scratch.mkdir()
fixtures = directory / 'bin'
fixtures.mkdir()
# Capture argv only; never operate a real service while checking shell quoting.
(fixtures / 'systemctl').write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
(fixtures / 'systemctl').chmod(0o755)
env = dict(os.environ, TMPDIR=str(scratch), PATH=str(fixtures) + ':/usr/bin:/bin:/usr/sbin:/sbin')
expected = [(0, 'stacio-ok'), (0, data['literal'] + '\nsecond'),
            (0, 'private input \' " \\ $'), (7, 'partialdiagnostic')]
shells = [p for p in ['/bin/sh', '/bin/bash', '/bin/zsh', '/bin/tcsh'] if Path(p).exists()]
assert '/bin/tcsh' in shells, 'The tcsh regression requires macOS /bin/tcsh'
fish = os.environ.get('STACIO_TEST_FISH') or shutil.which('fish')
if fish:
    assert Path(fish).is_file(), 'STACIO_TEST_FISH must name a fish executable'
    shells.append(fish)
else:
    print('SKIP: fish is unavailable; set STACIO_TEST_FISH to include its regression checks')
for shell in shells:
    for index, command in enumerate(data['commands']):
        arguments = [shell] + (['--no-config'] if shell == fish else []) + ['-c', command]
        result = subprocess.run(arguments, input=expected[2][1] + '\n',
                                capture_output=True, text=True, env=env, timeout=10)
        if index < len(expected):
            assert (result.returncode, result.stdout) == expected[index], (shell, index, result)
        elif index == 4:
            assert result.returncode == 0 and '__STACIO_PROCESS_FULL_PS__' in result.stdout, (shell, result)
            assert '__STACIO_PROCESS_PID__' in result.stdout
        else:
            name = data['serviceNames'][index - 5]
            assert (result.returncode, result.stdout) == (0, '--no-ask-password\nrestart\n--\n' + name + '\n'), (shell, name, result)
        assert result.stderr == '', (shell, index, result.stderr)
        assert not list(scratch.iterdir()), (shell, index, 'Leaked command scratch directory')
print('PASS: ' + '/'.join(Path(shell).name for shell in shells) + ', multiline/literal/service-name quoting, stdin, error status, real process collection, scratch cleanup')
PY
