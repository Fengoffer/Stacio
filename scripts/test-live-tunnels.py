#!/usr/bin/env python3
"""Exercise the real libssh2 tunnel runtime with disposable loopback sshd servers."""
import getpass
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time


def main():
    root = Path(__file__).resolve().parents[1]
    sshd = shutil.which("sshd") or "/usr/sbin/sshd"
    processes = []
    with tempfile.TemporaryDirectory(prefix="stacio-tunnel-fixture-") as directory:
        fixture = Path(directory)
        try:
            for name in ("host", "client"):
                subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(fixture / name)], check=True)
            for name, policy in (("port", "yes"), ("denied-port", "no")):
                with socket.socket() as reserved:
                    reserved.bind(("127.0.0.1", 0))
                    port = reserved.getsockname()[1]
                (fixture / name).write_text(str(port))
                config = fixture / f"{name}.conf"
                config.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey "{fixture / 'host'}"
PidFile "{fixture / (name + '.pid')}"
AuthorizedKeysFile "{fixture / 'client.pub'}"
StrictModes no
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
AllowUsers {getpass.getuser()}
AllowTcpForwarding {policy}
LogLevel VERBOSE
''')
                log = open(fixture / f"{name}.log", "w")
                try:
                    process = subprocess.Popen([sshd, "-D", "-e", "-f", str(config)], stderr=log)
                finally:
                    log.close()
                processes.append(process)
                deadline = time.monotonic() + 5
                while True:
                    if process.poll() is not None or time.monotonic() > deadline:
                        raise RuntimeError(f"Loopback sshd failed: {(fixture / (name + '.log')).read_text()}")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.02)
            env = dict(os.environ, STACIO_TUNNEL_FIXTURE_DIR=directory, USER=getpass.getuser())
            subprocess.run([
                "cargo", "test", "--manifest-path", str(root / "StacioCore/Cargo.toml"),
                "--test", "live_tunnel_round_trip", "--", "--ignored", "--nocapture",
            ], env=env, cwd=root, check=True)
        finally:
            for process in processes:
                process.terminate()
            for process in processes:
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
