#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  local output_file="$TMP_DIR/output-$RANDOM.log"
  set +e
  "$@" >"$output_file" 2>&1 &
  local pid="$!"
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null
      cat "$output_file"
      set -e
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
  local status="$?"
  cat "$output_file"
  set -e
  return "$status"
}

swift build --package-path "$ROOT_DIR" --product StacioVNCAdapter
ADAPTER="$ROOT_DIR/.build/debug/StacioVNCAdapter"

set +e
missing_output="$(run_with_timeout 3 "$ADAPTER")"
missing_status="$?"
set -e
test "$missing_status" -ne 0
grep -Fq "VNC 适配器需要目标地址，格式：host:port" <<<"$missing_output"

UNREACHABLE_PORT="$(/usr/bin/python3 - <<'PY'
import socket

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
PY
)"

set +e
unreachable_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$UNREACHABLE_PORT")"
unreachable_status="$?"
set -e
test "$unreachable_status" -ne 0
grep -Fq "VNC RFB 握手失败" <<<"$unreachable_output"

SERVER_PORT_FILE="$TMP_DIR/server-port"
SERVER_LOG_FILE="$TMP_DIR/server-log"
cat >"$TMP_DIR/rfb_server.py" <<'PY'
import socket
import sys

mode = sys.argv[1]
port_file = sys.argv[2]
log_file = sys.argv[3]

def recv_exact(conn, length):
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            raise RuntimeError("client closed")
        data += chunk
    return data

def assert_equal(actual, expected, label):
    if actual != expected:
        raise RuntimeError(f"{label}: expected {expected!r}, got {actual!r}")

SET_ENCODINGS_REQUEST = bytes([
    2, 0,
    0, 9,
    0, 0, 0, 0,
    0, 0, 0, 1,
    0, 0, 0, 2,
    0, 0, 0, 4,
    0, 0, 0, 5,
    0, 0, 0, 6,
    0, 0, 0, 16,
    255, 255, 255, 33,
    255, 255, 255, 32,
])
SET_ENCODINGS_LOG_VALUE = "raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect"

def read_set_encodings(conn):
    set_encodings = recv_exact(conn, len(SET_ENCODINGS_REQUEST))
    assert_equal(set_encodings, SET_ENCODINGS_REQUEST, "SetEncodings Raw+CopyRect+RRE+CoRRE+Hextile+Zlib+ZRLE+DesktopSize+LastRect")

def complete_standard_initial_request(conn, desktop_name):
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = desktop_name.encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")
    return client_version, selected_security, shared_flag

def send_server_init_and_read_initial_request(conn, desktop_name):
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = desktop_name.encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")
    read_set_encodings(conn)
    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")
    return shared_flag

def send_raw_1x1_update(conn):
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x11, 0x22, 0x33, 0x44]))

def write_standard_success_log(client_version, selected_security, shared_flag):
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"selected_security={selected_security[0]}\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")

IP = [
    58, 50, 42, 34, 26, 18, 10, 2,
    60, 52, 44, 36, 28, 20, 12, 4,
    62, 54, 46, 38, 30, 22, 14, 6,
    64, 56, 48, 40, 32, 24, 16, 8,
    57, 49, 41, 33, 25, 17, 9, 1,
    59, 51, 43, 35, 27, 19, 11, 3,
    61, 53, 45, 37, 29, 21, 13, 5,
    63, 55, 47, 39, 31, 23, 15, 7,
]
FP = [
    40, 8, 48, 16, 56, 24, 64, 32,
    39, 7, 47, 15, 55, 23, 63, 31,
    38, 6, 46, 14, 54, 22, 62, 30,
    37, 5, 45, 13, 53, 21, 61, 29,
    36, 4, 44, 12, 52, 20, 60, 28,
    35, 3, 43, 11, 51, 19, 59, 27,
    34, 2, 42, 10, 50, 18, 58, 26,
    33, 1, 41, 9, 49, 17, 57, 25,
]
E = [
    32, 1, 2, 3, 4, 5,
    4, 5, 6, 7, 8, 9,
    8, 9, 10, 11, 12, 13,
    12, 13, 14, 15, 16, 17,
    16, 17, 18, 19, 20, 21,
    20, 21, 22, 23, 24, 25,
    24, 25, 26, 27, 28, 29,
    28, 29, 30, 31, 32, 1,
]
P = [
    16, 7, 20, 21,
    29, 12, 28, 17,
    1, 15, 23, 26,
    5, 18, 31, 10,
    2, 8, 24, 14,
    32, 27, 3, 9,
    19, 13, 30, 6,
    22, 11, 4, 25,
]
PC1 = [
    57, 49, 41, 33, 25, 17, 9,
    1, 58, 50, 42, 34, 26, 18,
    10, 2, 59, 51, 43, 35, 27,
    19, 11, 3, 60, 52, 44, 36,
    63, 55, 47, 39, 31, 23, 15,
    7, 62, 54, 46, 38, 30, 22,
    14, 6, 61, 53, 45, 37, 29,
    21, 13, 5, 28, 20, 12, 4,
]
PC2 = [
    14, 17, 11, 24, 1, 5,
    3, 28, 15, 6, 21, 10,
    23, 19, 12, 4, 26, 8,
    16, 7, 27, 20, 13, 2,
    41, 52, 31, 37, 47, 55,
    30, 40, 51, 45, 33, 48,
    44, 49, 39, 56, 34, 53,
    46, 42, 50, 36, 29, 32,
]
SHIFTS = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
SBOXES = [
    [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7],
        [0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8],
        [4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0],
        [15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
    ],
    [
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10],
        [3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5],
        [0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15],
        [13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
    ],
    [
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8],
        [13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1],
        [13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7],
        [1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
    ],
    [
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15],
        [13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9],
        [10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4],
        [3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
    ],
    [
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9],
        [14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6],
        [4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14],
        [11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
    ],
    [
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11],
        [10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8],
        [9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6],
        [4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
    ],
    [
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1],
        [13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6],
        [1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2],
        [6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
    ],
    [
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7],
        [1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2],
        [7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8],
        [2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ],
]

def bytes_to_bits(data):
    return [(byte >> shift) & 1 for byte in data for shift in range(7, -1, -1)]

def bits_to_bytes(bits):
    output = bytearray()
    for index in range(0, len(bits), 8):
        byte = 0
        for bit in bits[index:index + 8]:
            byte = (byte << 1) | bit
        output.append(byte)
    return bytes(output)

def permute(bits, table):
    return [bits[position - 1] for position in table]

def left_rotate(bits, amount):
    return bits[amount:] + bits[:amount]

def xor_bits(left, right):
    return [a ^ b for a, b in zip(left, right)]

def sbox_substitution(bits):
    output = []
    for index in range(8):
        chunk = bits[index * 6:(index + 1) * 6]
        row = (chunk[0] << 1) | chunk[5]
        column = (chunk[1] << 3) | (chunk[2] << 2) | (chunk[3] << 1) | chunk[4]
        value = SBOXES[index][row][column]
        output.extend([(value >> shift) & 1 for shift in range(3, -1, -1)])
    return output

def des_subkeys(key):
    bits = permute(bytes_to_bits(key), PC1)
    c = bits[:28]
    d = bits[28:]
    subkeys = []
    for shift in SHIFTS:
        c = left_rotate(c, shift)
        d = left_rotate(d, shift)
        subkeys.append(permute(c + d, PC2))
    return subkeys

def des_encrypt_block(block, key):
    bits = permute(bytes_to_bits(block), IP)
    left = bits[:32]
    right = bits[32:]
    for subkey in des_subkeys(key):
        expanded = permute(right, E)
        mixed = xor_bits(expanded, subkey)
        f_output = permute(sbox_substitution(mixed), P)
        left, right = right, xor_bits(left, f_output)
    return bits_to_bytes(permute(right + left, FP))

def reverse_bits(byte):
    value = 0
    for index in range(8):
        value = (value << 1) | ((byte >> index) & 1)
    return value

def vnc_password_response(password, challenge):
    key = bytearray(8)
    encoded = password.encode("latin-1")[:8]
    key[:len(encoded)] = encoded
    reversed_key = bytes(reverse_bits(byte) for byte in key)
    return des_encrypt_block(challenge[:8], reversed_key) + des_encrypt_block(challenge[8:], reversed_key)

server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.getsockname()[1]))

conn, _ = server.accept()
if mode == "success":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = "Stacio Fake RFB".encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")

    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x11, 0x22, 0x33, 0x44]))
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"selected_security={selected_security[0]}\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "server-cut-text-before-update":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio ServerCutText RFB")
    clipboard_text = "Stacio clipboard notice".encode("utf-8")
    conn.sendall(bytes([3, 0, 0, 0]))
    conn.sendall(len(clipboard_text).to_bytes(4, "big"))
    conn.sendall(clipboard_text)
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "bell-before-update":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Bell RFB")
    conn.sendall(bytes([2]))
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "copyrect":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = "Stacio CopyRect RFB".encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")

    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(4, "big", signed=True))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"selected_security={selected_security[0]}\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "rre":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio RRE RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((2).to_bytes(4, "big", signed=True))
    conn.sendall((0).to_bytes(4, "big"))
    conn.sendall(bytes([0x11, 0x22, 0x33, 0x44]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "corre":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio CoRRE RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((4).to_bytes(4, "big", signed=True))
    conn.sendall((0).to_bytes(4, "big"))
    conn.sendall(bytes([0x11, 0x22, 0x33, 0x44]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "zrle":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio ZRLE RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((16).to_bytes(4, "big", signed=True))
    payload = bytes([0x78, 0x9c, 0x03, 0x00])
    conn.sendall(len(payload).to_bytes(4, "big"))
    conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "zlib":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Zlib RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((6).to_bytes(4, "big", signed=True))
    payload = bytes([0x78, 0x9c, 0x63, 0x60, 0x00, 0x00])
    conn.sendall(len(payload).to_bytes(4, "big"))
    conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "hextile":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Hextile RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((5).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x01, 0x11, 0x22, 0x33, 0x44]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "desktop-size":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = "Stacio DesktopSize RFB".encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")

    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1280).to_bytes(2, "big"))
    conn.sendall((720).to_bytes(2, "big"))
    conn.sendall((-223).to_bytes(4, "big", signed=True))
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"selected_security={selected_security[0]}\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "last-rect":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio LastRect RFB")
    conn.sendall(bytes([0, 0, 0, 2]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x11, 0x22, 0x33, 0x44]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((-224).to_bytes(4, "big", signed=True))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "rfb-003-003-none":
    conn.sendall(b"RFB 003.003\n")
    client_version = recv_exact(conn, 12)
    conn.sendall((1).to_bytes(4, "big"))
    shared_flag = send_server_init_and_read_initial_request(conn, "Stacio RFB 003.003 None")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("security_type=1\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "rfb-003-007-none":
    conn.sendall(b"RFB 003.007\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    shared_flag = send_server_init_and_read_initial_request(conn, "Stacio RFB 003.007 None")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"selected_security={selected_security[0]}\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "rfb-003-003-password-auth-success":
    conn.sendall(b"RFB 003.003\n")
    client_version = recv_exact(conn, 12)
    conn.sendall((2).to_bytes(4, "big"))
    challenge = bytes([
        0xde, 0xad, 0xbe, 0xef, 0x01, 0x23, 0x45, 0x67,
        0x89, 0xab, 0xcd, 0xef, 0x10, 0x32, 0x54, 0x76,
    ])
    conn.sendall(challenge)
    response = recv_exact(conn, 16)
    expected = vnc_password_response("secretpw", challenge)
    assert_equal(response, expected, "RFB 003.003 VNCPassword challenge response")
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = "Stacio RFB 003.003 VNCPassword".encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write("security_type=2\n")
        handle.write("vnc_password_response=ok\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "rfb-003-007-password-auth-success":
    conn.sendall(b"RFB 003.007\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 2]))
    selected_security = recv_exact(conn, 1)
    assert_equal(selected_security, bytes([2]), "RFB 003.007 selected VNCPassword security")
    challenge = bytes([
        0x21, 0x43, 0x65, 0x87, 0xa9, 0xcb, 0xed, 0x0f,
        0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
    ])
    conn.sendall(challenge)
    response = recv_exact(conn, 16)
    expected = vnc_password_response("secretpw", challenge)
    assert_equal(response, expected, "RFB 003.007 VNCPassword challenge response")
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = send_server_init_and_read_initial_request(conn, "Stacio RFB 003.007 VNCPassword")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write("selected_security=2\n")
        handle.write("vnc_password_response=ok\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
elif mode == "non-rfb":
    conn.sendall(b"HELLO THERE\n")
elif mode == "no-none":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 16]))
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
elif mode == "password-auth":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 2]))
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
elif mode == "password-auth-success":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 2]))
    selected_security = recv_exact(conn, 1)
    assert_equal(selected_security, bytes([2]), "selected VNCPassword security")
    challenge = bytes([
        0x10, 0x32, 0x54, 0x76, 0x98, 0xba, 0xdc, 0xfe,
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
    ])
    conn.sendall(challenge)
    response = recv_exact(conn, 16)
    expected = vnc_password_response("secretpw", challenge)
    assert_equal(response, expected, "VNCPassword challenge response")
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 0, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = "Stacio VNCPassword RFB".encode("utf-8")
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 0, 1, 0, 1]), "FramebufferUpdateRequest")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write("selected_security=2\n")
        handle.write("vnc_password_response=ok\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1x1\n")
else:
    raise RuntimeError(f"unknown mode {mode}")
conn.close()
server.close()
PY

start_fake_rfb_server() {
  local mode="$1"
  rm -f "$SERVER_PORT_FILE" "$SERVER_LOG_FILE"
  /usr/bin/python3 "$TMP_DIR/rfb_server.py" "$mode" "$SERVER_PORT_FILE" "$SERVER_LOG_FILE" &
  server_pid="$!"
  for _ in 1 2 3 4 5; do
    [ -s "$SERVER_PORT_FILE" ] && break
    sleep 1
  done
  SERVER_PORT="$(cat "$SERVER_PORT_FILE")"
}

start_fake_rfb_server success
success_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$success_output"
grep -Fq "协议版本：RFB 003.008" <<<"$success_output"
grep -Fq "安全类型：None" <<<"$success_output"
grep -Fq "桌面：Stacio Fake RFB" <<<"$success_output"
grep -Fq "尺寸：1024x768" <<<"$success_output"
grep -Fq "首帧更新：1 个矩形" <<<"$success_output"
grep -Fq "编码：Raw" <<<"$success_output"
grep -Fq "字节：4" <<<"$success_output"
grep -Fq "client_version=RFB 003.008" "$SERVER_LOG_FILE"
grep -Fq "selected_security=1" "$SERVER_LOG_FILE"
grep -Fq "shared_flag=1" "$SERVER_LOG_FILE"
grep -Fq "set_pixel_format=ok" "$SERVER_LOG_FILE"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server server-cut-text-before-update
set +e
server_cut_text_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
server_cut_text_status="$?"
set -e
wait "$server_pid"
if [ "$server_cut_text_status" -ne 0 ]; then
  echo "$server_cut_text_output"
  exit "$server_cut_text_status"
fi

grep -Fq "VNC RFB 握手成功" <<<"$server_cut_text_output"
grep -Fq "桌面：Stacio ServerCutText RFB" <<<"$server_cut_text_output"
grep -Fq "编码：Raw" <<<"$server_cut_text_output"
grep -Fq "字节：4" <<<"$server_cut_text_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server bell-before-update
set +e
bell_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
bell_status="$?"
set -e
wait "$server_pid"
if [ "$bell_status" -ne 0 ]; then
  echo "$bell_output"
  exit "$bell_status"
fi

grep -Fq "VNC RFB 握手成功" <<<"$bell_output"
grep -Fq "桌面：Stacio Bell RFB" <<<"$bell_output"
grep -Fq "编码：Raw" <<<"$bell_output"
grep -Fq "字节：4" <<<"$bell_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server copyrect
copyrect_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$copyrect_output"
grep -Fq "桌面：Stacio CopyRect RFB" <<<"$copyrect_output"
grep -Fq "编码：CopyRect" <<<"$copyrect_output"
grep -Fq "字节：4" <<<"$copyrect_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server rre
rre_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$rre_output"
grep -Fq "桌面：Stacio RRE RFB" <<<"$rre_output"
grep -Fq "编码：RRE" <<<"$rre_output"
grep -Fq "字节：8" <<<"$rre_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server corre
corre_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$corre_output"
grep -Fq "桌面：Stacio CoRRE RFB" <<<"$corre_output"
grep -Fq "编码：CoRRE" <<<"$corre_output"
grep -Fq "字节：8" <<<"$corre_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server hextile
hextile_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$hextile_output"
grep -Fq "桌面：Stacio Hextile RFB" <<<"$hextile_output"
grep -Fq "编码：Hextile" <<<"$hextile_output"
grep -Fq "字节：5" <<<"$hextile_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server zrle
zrle_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$zrle_output"
grep -Fq "桌面：Stacio ZRLE RFB" <<<"$zrle_output"
grep -Fq "编码：ZRLE" <<<"$zrle_output"
grep -Fq "字节：4" <<<"$zrle_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server zlib
zlib_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$zlib_output"
grep -Fq "桌面：Stacio Zlib RFB" <<<"$zlib_output"
grep -Fq "编码：Zlib" <<<"$zlib_output"
grep -Fq "字节：6" <<<"$zlib_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server desktop-size
desktop_size_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$desktop_size_output"
grep -Fq "桌面：Stacio DesktopSize RFB" <<<"$desktop_size_output"
grep -Fq "编码：DesktopSize" <<<"$desktop_size_output"
grep -Fq "桌面尺寸更新：1280x720" <<<"$desktop_size_output"
grep -Fq "字节：0" <<<"$desktop_size_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server last-rect
last_rect_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$last_rect_output"
grep -Fq "桌面：Stacio LastRect RFB" <<<"$last_rect_output"
grep -Fq "首帧更新：2 个矩形" <<<"$last_rect_output"
grep -Fq "编码：Raw" <<<"$last_rect_output"
grep -Fq "字节：4" <<<"$last_rect_output"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1x1" "$SERVER_LOG_FILE"

start_fake_rfb_server rfb-003-003-none
rfb_003_003_none_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$rfb_003_003_none_output"
grep -Fq "协议版本：RFB 003.003" <<<"$rfb_003_003_none_output"
grep -Fq "服务端版本：RFB 003.003" <<<"$rfb_003_003_none_output"
grep -Fq "安全类型：None" <<<"$rfb_003_003_none_output"
grep -Fq "桌面：Stacio RFB 003.003 None" <<<"$rfb_003_003_none_output"
grep -Fq "编码：Raw" <<<"$rfb_003_003_none_output"
grep -Fq "字节：4" <<<"$rfb_003_003_none_output"
grep -Fq "client_version=RFB 003.003" "$SERVER_LOG_FILE"
grep -Fq "security_type=1" "$SERVER_LOG_FILE"
grep -Fq "shared_flag=1" "$SERVER_LOG_FILE"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"
if grep -Fq "认证能力：VNCPassword(2) 未实现" <<<"$rfb_003_003_none_output"; then
  exit 1
fi

start_fake_rfb_server rfb-003-007-none
rfb_003_007_none_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

grep -Fq "VNC RFB 握手成功" <<<"$rfb_003_007_none_output"
grep -Fq "协议版本：RFB 003.007" <<<"$rfb_003_007_none_output"
grep -Fq "服务端版本：RFB 003.007" <<<"$rfb_003_007_none_output"
grep -Fq "安全类型：None" <<<"$rfb_003_007_none_output"
grep -Fq "桌面：Stacio RFB 003.007 None" <<<"$rfb_003_007_none_output"
grep -Fq "编码：Raw" <<<"$rfb_003_007_none_output"
grep -Fq "字节：4" <<<"$rfb_003_007_none_output"
grep -Fq "client_version=RFB 003.007" "$SERVER_LOG_FILE"
grep -Fq "selected_security=1" "$SERVER_LOG_FILE"
grep -Fq "shared_flag=1" "$SERVER_LOG_FILE"
grep -Fq "set_encodings=raw+copyrect+rre+corre+hextile+zlib+zrle+desktop-size+last-rect" "$SERVER_LOG_FILE"

start_fake_rfb_server rfb-003-003-password-auth-success
set +e
rfb_003_003_password_output="$(run_with_timeout 3 "$ADAPTER" --password secretpw "127.0.0.1:$SERVER_PORT")"
rfb_003_003_password_status="$?"
set -e
if kill -0 "$server_pid" 2>/dev/null; then
  kill "$server_pid" 2>/dev/null || true
fi
wait "$server_pid" 2>/dev/null || true
if [ "$rfb_003_003_password_status" -ne 0 ]; then
  echo "$rfb_003_003_password_output"
  exit "$rfb_003_003_password_status"
fi
grep -Fq "VNC RFB 握手成功" <<<"$rfb_003_003_password_output"
grep -Fq "协议版本：RFB 003.003" <<<"$rfb_003_003_password_output"
grep -Fq "安全类型：VNCPassword" <<<"$rfb_003_003_password_output"
grep -Fq "桌面：Stacio RFB 003.003 VNCPassword" <<<"$rfb_003_003_password_output"
grep -Fq "security_type=2" "$SERVER_LOG_FILE"
grep -Fq "vnc_password_response=ok" "$SERVER_LOG_FILE"
if grep -Fq "secretpw" <<<"$rfb_003_003_password_output"; then
  echo "VNC adapter leaked RFB 003.003 password in stdout" >&2
  exit 1
fi

start_fake_rfb_server rfb-003-007-password-auth-success
set +e
rfb_003_007_password_output="$(run_with_timeout 3 "$ADAPTER" --password secretpw "127.0.0.1:$SERVER_PORT")"
rfb_003_007_password_status="$?"
set -e
if kill -0 "$server_pid" 2>/dev/null; then
  kill "$server_pid" 2>/dev/null || true
fi
wait "$server_pid" 2>/dev/null || true
if [ "$rfb_003_007_password_status" -ne 0 ]; then
  echo "$rfb_003_007_password_output"
  exit "$rfb_003_007_password_status"
fi
grep -Fq "VNC RFB 握手成功" <<<"$rfb_003_007_password_output"
grep -Fq "协议版本：RFB 003.007" <<<"$rfb_003_007_password_output"
grep -Fq "安全类型：VNCPassword" <<<"$rfb_003_007_password_output"
grep -Fq "桌面：Stacio RFB 003.007 VNCPassword" <<<"$rfb_003_007_password_output"
grep -Fq "selected_security=2" "$SERVER_LOG_FILE"
grep -Fq "vnc_password_response=ok" "$SERVER_LOG_FILE"
if grep -Fq "secretpw" <<<"$rfb_003_007_password_output"; then
  echo "VNC adapter leaked RFB 003.007 password in stdout" >&2
  exit 1
fi

start_fake_rfb_server non-rfb
set +e
non_rfb_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
non_rfb_status="$?"
set -e
wait "$server_pid"
test "$non_rfb_status" -ne 0
grep -Fq "VNC RFB 握手失败" <<<"$non_rfb_output"
grep -Fq "服务端不是 RFB/VNC 协议" <<<"$non_rfb_output"

start_fake_rfb_server no-none
set +e
no_none_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
no_none_status="$?"
set -e
wait "$server_pid"
test "$no_none_status" -ne 0
grep -Fq "VNC RFB 握手失败" <<<"$no_none_output"
grep -Fq "服务端未提供 None(1) 或 VNCPassword(2) 安全类型" <<<"$no_none_output"
grep -Fq "需要后续实现更多 VNC 认证支持" <<<"$no_none_output"

start_fake_rfb_server password-auth
set +e
password_auth_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
password_auth_status="$?"
set -e
wait "$server_pid"
test "$password_auth_status" -ne 0
grep -Fq "VNC RFB 握手失败" <<<"$password_auth_output"
grep -Fq "VNC 密码认证" <<<"$password_auth_output"
grep -Fq "security type 2" <<<"$password_auth_output"
grep -Fq "未提供密码" <<<"$password_auth_output"
if grep -Fq "认证能力：VNCPassword(2) 未实现" <<<"$password_auth_output"; then
  exit 1
fi

start_fake_rfb_server password-auth-success
set +e
password_auth_success_output="$(run_with_timeout 3 "$ADAPTER" --password secretpw "127.0.0.1:$SERVER_PORT")"
password_auth_success_status="$?"
set -e
if kill -0 "$server_pid" 2>/dev/null; then
  kill "$server_pid" 2>/dev/null || true
fi
wait "$server_pid" 2>/dev/null || true
if [ "$password_auth_success_status" -ne 0 ]; then
  echo "$password_auth_success_output"
  exit "$password_auth_success_status"
fi
grep -Fq "VNC RFB 握手成功" <<<"$password_auth_success_output"
grep -Fq "安全类型：VNCPassword" <<<"$password_auth_success_output"
grep -Fq "桌面：Stacio VNCPassword RFB" <<<"$password_auth_success_output"
grep -Fq "编码：Raw" <<<"$password_auth_success_output"
grep -Fq "字节：4" <<<"$password_auth_success_output"
grep -Fq "selected_security=2" "$SERVER_LOG_FILE"
grep -Fq "vnc_password_response=ok" "$SERVER_LOG_FILE"
if grep -Fq "secretpw" <<<"$password_auth_success_output"; then
  echo "VNC adapter leaked password in stdout" >&2
  exit 1
fi

echo "vnc_adapter_rfb_handshake_test passed"
