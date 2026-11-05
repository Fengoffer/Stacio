#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STACIO_TELNET_CHECK_DIR="$(mktemp -d /tmp/stacio-telnet-diagnostic.XXXXXX)"
python3 - "$ROOT" "$STACIO_TELNET_CHECK_DIR" <<'PY'
from pathlib import Path
import os
import sys
root, out = map(Path, sys.argv[1:])
pane_path = Path(os.environ.get('STACIO_TELNET_CHECK_PANE_SOURCE', root / 'Stacio/Views/Terminal/RemoteTerminalPaneViewController.swift'))
pane = pane_path.read_text()
generated = (root / 'Stacio/Bridge/Generated/Sources/stacio_core.swift').read_text()
l10n = (root / 'Stacio/App/L10n.swift').read_text()
telnet = (root / 'Stacio/Services/TelnetSessionCoordinator.swift').read_text()
security = (root / 'Stacio/Security/SSHConnectionCoordinator.swift').read_text()
def block(source, marker):
    start = source.rfind('\n', 0, source.index(marker)) + 1
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
models = '\n'.join([
    block(pane, 'enum RemoteTerminalConnectionKind:'),
    block(pane, 'enum RemoteTerminalLifecycleState:'),
    block(security, 'enum SSHConnectionCoordinatorError:'),
    block(telnet, 'enum TelnetSessionError:'),
    *[block(generated, marker) for marker in [
        'enum SshRuntimeError:', 'enum TerminalRuntimeError:',
        'extension SshRuntimeError: Foundation.LocalizedError',
        'extension TerminalRuntimeError: Foundation.LocalizedError',
        'func stacioUserFacingRuntimeMessage(', 'func prefixed('
    ]],
    'enum L10n {\n' + block(l10n, 'enum TerminalLifecycle {') + '\n' + block(l10n, 'enum Diagnostics {') + '\n}'
])
methods = '\n'.join(block(pane, 'func ' + name + '(').replace('private func ', 'func ', 1) for name in [
    'connectionDiagnosticMessage', 'displayConnectionFailure', 'pollRemoteOutputOnce',
    'pollRemoteOutputInBackground', 'handleStoppedRuntimeStatus',
    'setLifecycle', 'applyLifecyclePresentation', 'handleStoppedSessionInput', 'isReturnKey',
    'isTransientPollError', 'isTransientPollDiagnostic', 'closeTerminal'
])
template = (root / 'Tests/Terminal/TelnetDiagnosticChecks.swift').read_text()
(out / 'Checks.swift').write_text(template.replace('// PRODUCTION_MODELS', models)
    .replace('// PRODUCTION_PANE_METHODS', methods)
    .replace('// PRODUCTION_TELNET_METHODS', block(telnet, 'func diagnosticMessage(for error:')))
PY
STACIO_TELNET_CHECK_SDK="${STACIO_MACOS_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}"
swiftc -parse-as-library -sdk "$STACIO_TELNET_CHECK_SDK" \
  "$STACIO_TELNET_CHECK_DIR/Checks.swift" \
  "$ROOT/Stacio/Services/RuntimeDiagnosticFormatter.swift" \
  -o "$STACIO_TELNET_CHECK_DIR/check"
"$STACIO_TELNET_CHECK_DIR/check"
