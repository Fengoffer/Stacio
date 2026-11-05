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

BUILD_DIR="${STACIO_VNC_SMOKE_BUILD_DIR:-$ROOT_DIR/.build}"
swift build --package-path "$ROOT_DIR" --scratch-path "$BUILD_DIR" --product StacioVNCAdapter
ADAPTER="$BUILD_DIR/debug/StacioVNCAdapter"

set +e
missing_output="$(run_with_timeout 3 "$ADAPTER")"
missing_status="$?"
set -e
test "$missing_status" -ne 0
grep -Fq "VNC 适配器参数无效。用法" <<<"$missing_output"

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
grep -Fq "VNC 连接失败" <<<"$unreachable_output"

SERVER_PORT_FILE="$TMP_DIR/server-port"
SERVER_LOG_FILE="$TMP_DIR/server-log"
export STACIO_TIGHT_JPEG_FIXTURE="$ROOT_DIR/Stacio/Resources/About/wechat-qrcode.jpg"
cat >"$TMP_DIR/rfb_server.py" <<'PY'
import os
import socket
import sys
import zlib

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

def compact_length(value):
    if not 0 <= value <= 0x3FFFFF:
        raise ValueError("compact length out of range")
    first = value & 0x7F
    value >>= 7
    if value == 0:
        return bytes([first])
    second = value & 0x7F
    value >>= 7
    if value == 0:
        return bytes([first | 0x80, second])
    return bytes([first | 0x80, second | 0x80, value & 0xFF])

SET_ENCODINGS_REQUEST = bytes([
    2, 0,
    0, 13,
    0, 0, 0, 7,
    0, 0, 0, 16,
    0, 0, 0, 6,
    0, 0, 0, 5,
    0, 0, 0, 0,
    255, 255, 255, 230,
    255, 255, 255, 33,
    255, 255, 255, 32,
    255, 255, 255, 17,
    255, 255, 255, 24,
    255, 255, 254, 204,
    192, 161, 229, 206,
    255, 255, 254, 200,
])
SET_ENCODINGS_LOG_VALUE = "tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position+extended-desktop-size+extended-clipboard+fence"

def read_set_encodings(conn):
    set_encodings = recv_exact(conn, len(SET_ENCODINGS_REQUEST))
    assert_equal(set_encodings, SET_ENCODINGS_REQUEST, "SetEncodings Tight+ZRLE+Zlib+Hextile+Raw with quality")

def complete_standard_initial_request(conn, desktop_name, width=1024, height=768):
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 1, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = desktop_name.encode("utf-8")
    conn.sendall(width.to_bytes(2, "big"))
    conn.sendall(height.to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    set_pixel_format = recv_exact(conn, 20)
    assert_equal(set_pixel_format[0], 0, "SetPixelFormat message type")
    assert_equal(set_pixel_format[4], 32, "SetPixelFormat bitsPerPixel")
    assert_equal(set_pixel_format[5], 24, "SetPixelFormat depth")

    read_set_encodings(conn)

    update_request = recv_exact(conn, 10)
    expected_update_request = (
        bytes([3, 0])
        + (0).to_bytes(2, "big")
        + (0).to_bytes(2, "big")
        + width.to_bytes(2, "big")
        + height.to_bytes(2, "big")
    )
    assert_equal(update_request, expected_update_request, "FramebufferUpdateRequest")
    return client_version, selected_security, shared_flag

def send_server_init_and_read_initial_request(conn, desktop_name):
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 1, 1,
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
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 4, 0, 3, 0]), "FramebufferUpdateRequest")
    return shared_flag

def send_raw_1x1_update(conn):
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x11, 0x22, 0x33, 0x44]))

def send_extended_server_cut_text(conn, payload):
    conn.sendall(bytes([3, 0, 0, 0]))
    conn.sendall((-len(payload)).to_bytes(4, "big", signed=True))
    conn.sendall(payload)

def read_client_message(conn):
    message_type = recv_exact(conn, 1)
    if message_type == bytes([3]):
        return (3, message_type + recv_exact(conn, 9))
    if message_type == bytes([6]):
        padding = recv_exact(conn, 3)
        signed_length = int.from_bytes(recv_exact(conn, 4), "big", signed=True)
        payload = recv_exact(conn, abs(signed_length))
        return (6, (padding, signed_length, payload))
    if message_type == bytes([248]):
        padding = recv_exact(conn, 3)
        flags = int.from_bytes(recv_exact(conn, 4), "big")
        length = recv_exact(conn, 1)[0]
        payload = recv_exact(conn, length)
        return (248, (padding, flags, payload))
    raise RuntimeError(f"unexpected client message {message_type!r}")

def write_standard_success_log(client_version, selected_security, shared_flag):
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write(f"selected_security={selected_security[0]}\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1024x768\n")

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

server_family = socket.AF_INET6 if mode == "ipv6-success" else socket.AF_INET
server = socket.socket(server_family, socket.SOCK_STREAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
if server_family == socket.AF_INET6:
    server.bind(("::1", 0))
else:
    server.bind(("127.0.0.1", 0))
server.listen(1)
with open(port_file, "w", encoding="utf-8") as handle:
    handle.write(str(server.getsockname()[1]))

conn, _ = server.accept()
if mode == "stdin-before-handshake":
    with open(log_file + ".accepted", "w", encoding="utf-8") as handle:
        handle.write("accepted\n")
    conn.settimeout(0.5)
    try:
        pre_banner_traffic = conn.recv(4096)
    except socket.timeout:
        pre_banner_traffic = b""
    finally:
        conn.settimeout(None)
    assert_equal(pre_banner_traffic, b"", "client traffic before RFB banner")
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Handshake Isolation RFB",
    )
    key_event = None
    for _ in range(3):
        message_type = recv_exact(conn, 1)
        if message_type == bytes([4]):
            key_event = message_type + recv_exact(conn, 7)
            break
        if message_type == bytes([3]):
            recv_exact(conn, 9)
            continue
        raise RuntimeError(f"unexpected post-negotiation client message {message_type!r}")
    assert_equal(
        key_event,
        bytes([4, 1, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF]),
        "bounded UInt32 KeyEvent after RFB negotiation",
    )
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "success":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 1, 1,
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
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 4, 0, 3, 0]), "FramebufferUpdateRequest")

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
        handle.write("framebuffer_update_request=1024x768\n")
elif mode == "raw-padding-byte-zero":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Raw Padding Byte RFB",
    )
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    # The fourth byte is padding at depth=24 and may legally be zero.
    conn.sendall(bytes([0x00, 0x00, 0xFF, 0x00]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "one-outstanding-request":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Outstanding Request RFB",
    )
    conn.settimeout(0.35)
    try:
        unexpected_request = conn.recv(10)
    except socket.timeout:
        unexpected_request = b""
    finally:
        conn.settimeout(None)
    assert_equal(unexpected_request, b"", "second request before first response")

    send_raw_1x1_update(conn)
    next_request = recv_exact(conn, 10)
    assert_equal(
        next_request,
        bytes([3, 1, 0, 0, 0, 0, 4, 0, 3, 0]),
        "incremental request after first response",
    )
    conn.settimeout(0.25)
    try:
        duplicate_request = conn.recv(10)
    except socket.timeout:
        duplicate_request = b""
    finally:
        conn.settimeout(None)
    assert_equal(duplicate_request, b"", "duplicate outstanding incremental request")
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "ipv6-success":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio IPv6 RFB",
    )
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "oversized-server-init":
    conn.sendall(b"RFB 003.008\n")
    recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 1, 1,
        0, 255, 0, 255, 0, 255,
        16, 8, 0,
        0, 0, 0
    ])
    name = "Stacio Oversized ServerInit RFB".encode("utf-8")
    conn.sendall((8193).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall(pixel_format)
    conn.sendall(len(name).to_bytes(4, "big"))
    conn.sendall(name)
    conn.settimeout(1.0)
    try:
        conn.recv(4096)
    except (socket.timeout, ConnectionResetError):
        pass
elif mode == "server-cut-text-before-update":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio ServerCutText RFB")
    clipboard_text = "Stacio clipboard notice".encode("utf-8")
    conn.sendall(bytes([3, 0, 0, 0]))
    conn.sendall(len(clipboard_text).to_bytes(4, "big"))
    conn.sendall(clipboard_text)
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "extended-clipboard":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Extended Clipboard RFB",
    )
    local_text = "Stacio 本地剪贴板 🚀"
    remote_text = "Windows 远端剪贴板 ✓"
    text_flag = 1 << 0
    capabilities_flag = 1 << 24
    request_flag = 1 << 25
    peek_flag = 1 << 26
    notify_flag = 1 << 27
    provide_flag = 1 << 28
    action_flags = request_flag | peek_flag | notify_flag | provide_flag

    capabilities = (
        (capabilities_flag | action_flags | text_flag).to_bytes(4, "big")
        + (1_048_576).to_bytes(4, "big")
    )
    send_extended_server_cut_text(conn, capabilities)

    saw_client_capabilities = False
    for _ in range(12):
        kind, message = read_client_message(conn)
        if kind != 6:
            continue
        _, signed_length, payload = message
        if signed_length >= 0:
            # stdin can be delivered immediately after negotiation, before
            # the server's capabilities are processed. The adapter must cache
            # this value so a later Extended Clipboard Request can retrieve it.
            continue
        flags = int.from_bytes(payload[:4], "big")
        if flags & capabilities_flag:
            assert_equal(
                flags,
                capabilities_flag | action_flags | text_flag,
                "Extended Clipboard client capabilities",
            )
            saw_client_capabilities = True
            break
    assert_equal(saw_client_capabilities, True, "Extended Clipboard capabilities response")

    send_extended_server_cut_text(conn, (request_flag | text_flag).to_bytes(4, "big"))
    provided_local_text = None
    for _ in range(12):
        kind, message = read_client_message(conn)
        if kind != 6:
            continue
        _, signed_length, payload = message
        if signed_length >= 0:
            continue
        flags = int.from_bytes(payload[:4], "big")
        if flags & provide_flag:
            inflated = zlib.decompress(payload[4:])
            text_length = int.from_bytes(inflated[:4], "big")
            encoded_text = inflated[4:4 + text_length]
            assert_equal(encoded_text[-1:], bytes([0]), "Extended Clipboard UTF-8 terminator")
            provided_local_text = encoded_text[:-1].decode("utf-8")
            break
    assert_equal(provided_local_text, local_text, "Extended Clipboard local UTF-8 Provide")

    encoded_remote_text = remote_text.encode("utf-8") + bytes([0])
    remote_provide = (
        (provide_flag | text_flag).to_bytes(4, "big")
        + zlib.compress(len(encoded_remote_text).to_bytes(4, "big") + encoded_remote_text)
    )
    send_extended_server_cut_text(conn, remote_provide)
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "oversized-server-cut-text":
    complete_standard_initial_request(conn, "Stacio Oversized ServerCutText RFB")
    conn.sendall(bytes([3, 0, 0, 0]))
    conn.sendall((1_048_577).to_bytes(4, "big"))
    conn.settimeout(1.0)
    try:
        conn.recv(4096)
    except (socket.timeout, ConnectionResetError):
        pass
elif mode == "bounded-client-input":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Bounded Client Input RFB",
    )
    pointer_event = None
    for _ in range(20):
        message_type = recv_exact(conn, 1)
        if message_type == bytes([5]):
            pointer_event = message_type + recv_exact(conn, 5)
            break
        if message_type == bytes([3]):
            recv_exact(conn, 9)
            continue
        if message_type == bytes([6]):
            recv_exact(conn, 3)
            length = int.from_bytes(recv_exact(conn, 4), "big")
            raise RuntimeError(f"adapter forwarded oversized ClientCutText ({length} bytes)")
        if message_type == bytes([251]):
            raise RuntimeError("adapter forwarded oversized SetDesktopSize")
        raise RuntimeError(f"unexpected client message {message_type!r}")
    assert_equal(pointer_event, bytes([5, 1, 0, 12, 0, 34]), "pointer after bounded stdin lines")
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "scroll-input":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Scroll Input RFB",
    )
    send_raw_1x1_update(conn)
    pointer_events = []
    while len(pointer_events) < 5:
        message_type = recv_exact(conn, 1)
        if message_type == bytes([3]):
            recv_exact(conn, 9)
            continue
        if message_type == bytes([5]):
            pointer_events.append(message_type + recv_exact(conn, 5))
            continue
        raise RuntimeError(f"unexpected client message while waiting for scroll input {message_type!r}")
    x_bytes = (12).to_bytes(2, "big")
    y_bytes = (34).to_bytes(2, "big")
    assert_equal(
        pointer_events,
        [
            bytes([5, 1]) + x_bytes + y_bytes,
            bytes([5, 9]) + x_bytes + y_bytes,
            bytes([5, 1]) + x_bytes + y_bytes,
            bytes([5, 33]) + x_bytes + y_bytes,
            bytes([5, 1]) + x_bytes + y_bytes,
        ],
        "vertical and horizontal VNC wheel clicks",
    )
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "bell-before-update":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Bell RFB")
    conn.sendall(bytes([2]))
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "colour-map-before-update":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Colour Map RFB")
    conn.sendall(bytes([1, 0]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall(bytes([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00]))
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
        32, 24, 1, 1,
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
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 4, 0, 3, 0]), "FramebufferUpdateRequest")

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
        handle.write("framebuffer_update_request=1024x768\n")
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
    conn.sendall((65).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((16).to_bytes(4, "big", signed=True))
    compressor = zlib.compressobj()
    decoded = bytes([0]) + bytes([0x00, 0x00, 0xFF]) * 64 + bytes([1, 0x00, 0xFF, 0x00])
    payload = compressor.compress(decoded) + compressor.flush(zlib.Z_SYNC_FLUSH)
    conn.sendall(len(payload).to_bytes(4, "big"))
    conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "zrle-continuous-stream":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Continuous ZRLE RFB")
    compressor = zlib.compressobj()
    first_payload = compressor.compress(bytes([1, 0x00, 0x00, 0xFF])) + compressor.flush(zlib.Z_SYNC_FLUSH)
    second_payload = compressor.compress(bytes([1, 0x00, 0xFF, 0x00])) + compressor.flush(zlib.Z_SYNC_FLUSH)
    conn.sendall(bytes([0, 0, 0, 2]))
    for x, payload in ((0, first_payload), (8, second_payload)):
        conn.sendall(x.to_bytes(2, "big"))
        conn.sendall((0).to_bytes(2, "big"))
        conn.sendall((8).to_bytes(2, "big"))
        conn.sendall((8).to_bytes(2, "big"))
        conn.sendall((16).to_bytes(4, "big", signed=True))
        conn.sendall(len(payload).to_bytes(4, "big"))
        conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-fill":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Tight Fill RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((4).to_bytes(2, "big"))
    conn.sendall((4).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x80, 0xFF, 0x00, 0x00]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-fill-wide":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Wide Tight Fill RFB",
        width=4096,
        height=2,
    )
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((2049).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x80, 0xFF, 0x00, 0x00]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-fill-out-of-bounds":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Bounded Tight Fill RFB",
    )
    conn.sendall(bytes([0, 0, 0, 1]))
    # The rectangle header alone is invalid. The client must reject it before
    # reading or decoding any Tight payload.
    conn.sendall((1000).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((65535).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-copy-small":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Tight Copy RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x00, 0x00, 0xFF, 0x00]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-palette":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Tight Palette RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((8).to_bytes(2, "big"))
    conn.sendall((8).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([
        0x40, 0x01, 0x01,
        0xFF, 0x00, 0x00,
        0x00, 0xFF, 0x00,
        0x0F, 0x0F, 0x0F, 0x0F,
        0x0F, 0x0F, 0x0F, 0x0F,
    ]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-gradient":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Tight Gradient RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((2).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([
        0x40, 0x02,
        10, 20, 30, 5, 5, 5,
    ]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-continuous-stream":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Continuous Tight RFB")
    compressor = zlib.compressobj()
    first_pixels = bytes([0xFF, 0x00, 0x00]) * 64
    second_pixels = bytes([0x00, 0xFF, 0x00]) * 64
    first_payload = compressor.compress(first_pixels) + compressor.flush(zlib.Z_SYNC_FLUSH)
    second_payload = compressor.compress(second_pixels) + compressor.flush(zlib.Z_SYNC_FLUSH)
    conn.sendall(bytes([0, 0, 0, 2]))
    for x, payload in ((0, first_payload), (8, second_payload)):
        conn.sendall(x.to_bytes(2, "big"))
        conn.sendall((0).to_bytes(2, "big"))
        conn.sendall((8).to_bytes(2, "big"))
        conn.sendall((8).to_bytes(2, "big"))
        conn.sendall((7).to_bytes(4, "big", signed=True))
        conn.sendall(bytes([0x00]))
        conn.sendall(compact_length(len(payload)))
        conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "tight-jpeg":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Tight JPEG RFB")
    with open(os.environ["STACIO_TIGHT_JPEG_FIXTURE"], "rb") as handle:
        jpeg = handle.read()
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((344).to_bytes(2, "big"))
    conn.sendall((344).to_bytes(2, "big"))
    conn.sendall((7).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x90]))
    conn.sendall(compact_length(len(jpeg)))
    conn.sendall(jpeg)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "zlib":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Zlib RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((6).to_bytes(4, "big", signed=True))
    compressor = zlib.compressobj()
    payload = compressor.compress(bytes([0x11, 0x22, 0x33, 0x44])) + compressor.flush(zlib.Z_SYNC_FLUSH)
    conn.sendall(len(payload).to_bytes(4, "big"))
    conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "zlib-continuous-stream":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Continuous Zlib RFB")
    compressor = zlib.compressobj()
    first_pixels = bytes([0xFF, 0x00, 0x00, 0xFF]) * 64
    second_pixels = bytes([0x00, 0x00, 0xFF, 0xFF]) * 64
    first_payload = compressor.compress(first_pixels) + compressor.flush(zlib.Z_SYNC_FLUSH)
    second_payload = compressor.compress(second_pixels) + compressor.flush(zlib.Z_SYNC_FLUSH)

    conn.sendall(bytes([0, 0, 0, 2]))
    for x, payload in ((0, first_payload), (8, second_payload)):
        conn.sendall(x.to_bytes(2, "big"))
        conn.sendall((0).to_bytes(2, "big"))
        conn.sendall((8).to_bytes(2, "big"))
        conn.sendall((8).to_bytes(2, "big"))
        conn.sendall((6).to_bytes(4, "big", signed=True))
        conn.sendall(len(payload).to_bytes(4, "big"))
        conn.sendall(payload)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "fence":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Fence RFB")
    fence_payload = b"stacio-fence"
    conn.sendall(bytes([248, 0, 0, 0]))
    conn.sendall((0x80000000).to_bytes(4, "big"))
    conn.sendall(bytes([len(fence_payload)]))
    conn.sendall(fence_payload)

    fence_response = None
    for _ in range(3):
        message_type = recv_exact(conn, 1)
        if message_type == bytes([3]):
            recv_exact(conn, 9)
            continue
        if message_type == bytes([248]):
            padding = recv_exact(conn, 3)
            flags = int.from_bytes(recv_exact(conn, 4), "big")
            length = recv_exact(conn, 1)[0]
            payload = recv_exact(conn, length)
            fence_response = (padding, flags, payload)
            break
        raise RuntimeError(f"unexpected client message while waiting for Fence response {message_type!r}")
    assert_equal(fence_response, (bytes(3), 0, fence_payload), "Fence response")
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "no-fence-probe":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio No Fence RFB",
    )
    send_raw_1x1_update(conn)
    deadline = __import__("time").monotonic() + 11.0
    conn.settimeout(0.25)
    try:
        while __import__("time").monotonic() < deadline:
            try:
                message_type = conn.recv(1)
            except socket.timeout:
                continue
            if not message_type:
                break
            if message_type == bytes([3]):
                recv_exact(conn, 9)
                conn.sendall(bytes([0, 0, 0, 0]))
                continue
            if message_type == bytes([248]):
                raise RuntimeError("adapter sent ClientFence before server advertised Fence support")
            if message_type == bytes([6]):
                recv_exact(conn, 3)
                length = int.from_bytes(recv_exact(conn, 4), "big", signed=True)
                recv_exact(conn, abs(length))
                continue
            raise RuntimeError(f"unexpected client message while checking Fence gating {message_type!r}")
    finally:
        conn.settimeout(None)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "set-desktop-size-unsupported":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Unsupported SetDesktopSize RFB",
    )
    conn.settimeout(0.6)
    try:
        unexpected_request = conn.recv(24)
    except socket.timeout:
        unexpected_request = b""
    finally:
        conn.settimeout(None)
    if unexpected_request[:1] == bytes([251]):
        raise RuntimeError("adapter sent SetDesktopSize before server advertised ExtendedDesktopSize")
    assert_equal(unexpected_request, b"", "client resize traffic without ExtendedDesktopSize support")
    send_raw_1x1_update(conn)
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "set-desktop-size-request":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio SetDesktopSize RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall((-308).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([1, 0, 0, 0]))
    conn.sendall((0).to_bytes(4, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1024).to_bytes(2, "big"))
    conn.sendall((768).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big"))
    resize_request = None
    for _ in range(3):
        message_type = recv_exact(conn, 1)
        if message_type == bytes([3]):
            recv_exact(conn, 9)
            continue
        if message_type == bytes([251]):
            resize_request = message_type + recv_exact(conn, 23)
            break
        raise RuntimeError(f"unexpected client message while waiting for SetDesktopSize {message_type!r}")
    expected_resize_request = (
        bytes([251, 0])
        + (1280).to_bytes(2, "big")
        + (720).to_bytes(2, "big")
        + bytes([1, 0])
        + (0).to_bytes(4, "big")
        + (0).to_bytes(2, "big")
        + (0).to_bytes(2, "big")
        + (1280).to_bytes(2, "big")
        + (720).to_bytes(2, "big")
        + (0).to_bytes(4, "big")
    )
    assert_equal(resize_request, expected_resize_request, "SetDesktopSize request")
    send_raw_1x1_update(conn)
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
elif mode == "hextile-nibbles":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Hextile Nibbles RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((16).to_bytes(2, "big"))
    conn.sendall((16).to_bytes(2, "big"))
    conn.sendall((5).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([
        0x0E,
        0x00, 0x00, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
        0x01,
        0x11,
        0xDD,
    ]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "hextile-color-persistence":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Hextile Color Persistence RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((32).to_bytes(2, "big"))
    conn.sendall((16).to_bytes(2, "big"))
    conn.sendall((5).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([
        0x06,
        0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
        0x08,
        0x01,
        0x44,
        0x77,
    ]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "oversized-hextile":
    complete_standard_initial_request(
        conn,
        "Stacio Oversized Hextile RFB",
        width=8192,
        height=2049,
    )
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((8192).to_bytes(2, "big"))
    conn.sendall((2049).to_bytes(2, "big"))
    conn.sendall((5).to_bytes(4, "big", signed=True))
elif mode == "hextile-subrect-out-of-bounds":
    complete_standard_initial_request(conn, "Stacio Invalid Hextile Subrect RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((5).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([
        0x0E,
        0x00, 0x00, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
        0x01,
        0x11,
        0x00,
    ]))
elif mode == "hextile-reserved-bits":
    complete_standard_initial_request(conn, "Stacio Invalid Hextile Reserved Bits RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((5).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x20]))
elif mode == "desktop-size":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([1, 1]))
    selected_security = recv_exact(conn, 1)
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = recv_exact(conn, 1)
    pixel_format = bytes([
        32, 24, 1, 1,
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
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 4, 0, 3, 0]), "FramebufferUpdateRequest")

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
        handle.write("framebuffer_update_request=1024x768\n")
elif mode == "desktop-size-preserves-canvas":
    client_version, selected_security, shared_flag = complete_standard_initial_request(
        conn,
        "Stacio Preserved DesktopSize RFB",
        width=2,
        height=1,
    )
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((2).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x00, 0x00, 0xFF, 0xFF]) * 2)

    incremental_request = recv_exact(conn, 10)
    assert_equal(
        incremental_request,
        bytes([3, 1, 0, 0, 0, 0, 0, 2, 0, 1]),
        "incremental FramebufferUpdateRequest",
    )

    conn.sendall(bytes([0, 0, 0, 4]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((3).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((-223).to_bytes(4, "big", signed=True))
    for _ in range(3):
        conn.sendall((2).to_bytes(2, "big"))
        conn.sendall((0).to_bytes(2, "big"))
        conn.sendall((1).to_bytes(2, "big"))
        conn.sendall((1).to_bytes(2, "big"))
        conn.sendall((7).to_bytes(4, "big", signed=True))
        conn.sendall(bytes([0x80, 0x00, 0xFF, 0x00]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "oversized-desktop-size":
    complete_standard_initial_request(conn, "Stacio Oversized DesktopSize RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((8193).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((-223).to_bytes(4, "big", signed=True))
elif mode == "extended-desktop-size":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio ExtendedDesktopSize RFB")
    conn.sendall(bytes([0, 0, 0, 2]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1280).to_bytes(2, "big"))
    conn.sendall((720).to_bytes(2, "big"))
    conn.sendall((-308).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([1, 0, 0, 0]))
    conn.sendall((0).to_bytes(4, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((1280).to_bytes(2, "big"))
    conn.sendall((720).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big"))
    conn.sendall((1200).to_bytes(2, "big"))
    conn.sendall((700).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([0x00, 0x00, 0xFF, 0xFF]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "cursor-bitmap":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Cursor Bitmap RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((1).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((2).to_bytes(2, "big"))
    conn.sendall((2).to_bytes(2, "big"))
    conn.sendall((-239).to_bytes(4, "big", signed=True))
    conn.sendall(bytes([
        0x10, 0x20, 0x30, 0xFF,
        0x40, 0x50, 0x60, 0x80,
        0x70, 0x80, 0x90, 0xFF,
        0xA0, 0xB0, 0xC0, 0xFF,
        0x80,
        0x40,
    ]))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "empty-cursor":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio Empty Cursor RFB")
    conn.sendall(bytes([0, 0, 0, 1]))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((0).to_bytes(2, "big"))
    conn.sendall((-239).to_bytes(4, "big", signed=True))
    write_standard_success_log(client_version, selected_security, shared_flag)
elif mode == "last-rect":
    client_version, selected_security, shared_flag = complete_standard_initial_request(conn, "Stacio LastRect RFB")
    conn.sendall(bytes([0, 0, 0xFF, 0xFF]))
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
        handle.write("framebuffer_update_request=1024x768\n")
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
        handle.write("framebuffer_update_request=1024x768\n")
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
        32, 24, 1, 1,
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
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 4, 0, 3, 0]), "FramebufferUpdateRequest")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write("security_type=2\n")
        handle.write("vnc_password_response=ok\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1024x768\n")
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
        handle.write("framebuffer_update_request=1024x768\n")
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
        32, 24, 1, 1,
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
    assert_equal(update_request, bytes([3, 0, 0, 0, 0, 0, 4, 0, 3, 0]), "FramebufferUpdateRequest")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write("selected_security=2\n")
        handle.write("vnc_password_response=ok\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1024x768\n")
elif mode == "password-preferred-over-none":
    conn.sendall(b"RFB 003.008\n")
    client_version = recv_exact(conn, 12)
    conn.sendall(bytes([2, 1, 2]))
    selected_security = recv_exact(conn, 1)
    assert_equal(selected_security, bytes([2]), "password must be preferred when supplied")
    challenge = bytes(range(16))
    conn.sendall(challenge)
    response = recv_exact(conn, 16)
    assert_equal(response, vnc_password_response("secretpw", challenge), "preferred password response")
    conn.sendall((0).to_bytes(4, "big"))
    shared_flag = send_server_init_and_read_initial_request(conn, "Stacio Preferred Password RFB")
    send_raw_1x1_update(conn)
    with open(log_file, "w", encoding="utf-8") as handle:
        handle.write(f"client_version={client_version.decode('ascii')}")
        handle.write("selected_security=2\n")
        handle.write("vnc_password_response=ok\n")
        handle.write(f"shared_flag={shared_flag[0]}\n")
        handle.write("set_pixel_format=ok\n")
        handle.write(f"set_encodings={SET_ENCODINGS_LOG_VALUE}\n")
        handle.write("framebuffer_update_request=1024x768\n")
else:
    raise RuntimeError(f"unknown mode {mode}")
conn.close()
server.close()
PY

start_fake_rfb_server() {
  local mode="$1"
  rm -f "$SERVER_PORT_FILE" "$SERVER_LOG_FILE" "$SERVER_LOG_FILE.accepted"
  /usr/bin/python3 "$TMP_DIR/rfb_server.py" "$mode" "$SERVER_PORT_FILE" "$SERVER_LOG_FILE" &
  server_pid="$!"
  for _ in 1 2 3 4 5; do
    [ -s "$SERVER_PORT_FILE" ] && break
    sleep 1
  done
  SERVER_PORT="$(cat "$SERVER_PORT_FILE")"
}

assert_json_event() {
  local output="$1"
  local event_type="$2"
  if ! grep -Fq "\"type\":\"$event_type\"" <<<"$output"; then
    echo "expected JSON event type $event_type" >&2
    echo "$output"
    return 1
  fi
}

assert_json_string_field() {
  local output="$1"
  local field="$2"
  local value="$3"
  if ! grep -Fq "\"$field\":\"$value\"" <<<"$output"; then
    echo "expected JSON string field $field=$value" >&2
    echo "$output"
    return 1
  fi
}

assert_json_number_field() {
  local output="$1"
  local field="$2"
  local value="$3"
  if ! grep -Fq "\"$field\":$value" <<<"$output"; then
    echo "expected JSON number field $field=$value" >&2
    echo "$output"
    return 1
  fi
}

assert_frame_pixel() {
  local output="$1"
  local label="$2"
  local x="$3"
  local y="$4"
  local expected="$5"
  local selection="${6:-first}"
  local json_file="$TMP_DIR/frame-$label.jsonl"
  local jpeg_file="$TMP_DIR/frame-$label.jpg"
  local bmp_file="$TMP_DIR/frame-$label.bmp"

  printf '%s\n' "$output" >"$json_file"
  /usr/bin/python3 - "$json_file" "$jpeg_file" "$selection" <<'PY'
import base64
import json
import sys

json_path, jpeg_path, selection = sys.argv[1:]
if selection not in {"first", "last"}:
    raise RuntimeError(f"unknown frame selection {selection}")
frame = None
with open(json_path, "r", encoding="utf-8") as handle:
    for line in handle:
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if event.get("type") in {"frame", "frame_patch"} and event.get("encoding") == "jpeg":
            frame = event
            if selection == "first":
                break
if frame is None:
    raise RuntimeError("adapter output did not contain a JPEG frame")
with open(jpeg_path, "wb") as handle:
    handle.write(base64.b64decode(frame["data"], validate=True))
PY
  /usr/bin/sips -s format bmp "$jpeg_file" --out "$bmp_file" >/dev/null
  /usr/bin/python3 - "$bmp_file" "$x" "$y" "$expected" <<'PY'
import struct
import sys

path, raw_x, raw_y, expected = sys.argv[1:]
x = int(raw_x)
y = int(raw_y)
data = open(path, "rb").read()
if data[:2] != b"BM":
    raise RuntimeError("sips output is not BMP")
pixel_offset = struct.unpack_from("<I", data, 10)[0]
width = struct.unpack_from("<i", data, 18)[0]
height = struct.unpack_from("<i", data, 22)[0]
bits_per_pixel = struct.unpack_from("<H", data, 28)[0]
compression = struct.unpack_from("<I", data, 30)[0]
if bits_per_pixel not in (24, 32) or compression not in (0, 3):
    raise RuntimeError(f"unsupported BMP layout bpp={bits_per_pixel} compression={compression}")
absolute_height = abs(height)
if not (0 <= x < width and 0 <= y < absolute_height):
    raise RuntimeError(f"pixel ({x},{y}) outside {width}x{absolute_height}")
row = y if height < 0 else absolute_height - 1 - y
row_stride = ((width * bits_per_pixel + 31) // 32) * 4
bytes_per_pixel = bits_per_pixel // 8
value_offset = pixel_offset + row * row_stride + x * bytes_per_pixel

if bits_per_pixel == 24:
    blue, green, red = data[value_offset:value_offset + 3]
elif compression == 3:
    value = struct.unpack_from("<I", data, value_offset)[0]
    masks = [struct.unpack_from("<I", data, offset)[0] for offset in (54, 58, 62)]
    def component(mask):
        shift = (mask & -mask).bit_length() - 1
        maximum = mask >> shift
        return (((value & mask) >> shift) * 255 + maximum // 2) // maximum
    red, green, blue = (component(mask) for mask in masks)
else:
    value = struct.unpack_from("<I", data, value_offset)[0]
    blue = value & 0xFF
    green = (value >> 8) & 0xFF
    red = (value >> 16) & 0xFF

dominant = {
    "red": red >= 160 and red >= green + 80 and red >= blue + 80,
    "green": green >= 160 and green >= red + 80 and green >= blue + 80,
    "blue": blue >= 160 and blue >= red + 80 and blue >= green + 80,
    "black": max(red, green, blue) <= 70,
}
if expected not in dominant:
    raise RuntimeError(f"unknown expected color {expected}")
if not dominant[expected]:
    raise RuntimeError(f"pixel ({x},{y}) expected {expected}, got RGB=({red},{green},{blue})")
PY
}

start_fake_rfb_server stdin-before-handshake
HANDSHAKE_FIFO="$TMP_DIR/handshake-input"
HANDSHAKE_OUTPUT="$TMP_DIR/handshake-output"
mkfifo "$HANDSHAKE_FIFO"
exec 9<>"$HANDSHAKE_FIFO"
"$ADAPTER" "127.0.0.1:$SERVER_PORT" <&9 >"$HANDSHAKE_OUTPUT" 2>&1 &
handshake_adapter_pid="$!"
for _ in $(seq 1 100); do
  [ -s "$SERVER_LOG_FILE.accepted" ] && break
  sleep 0.02
done
test -s "$SERVER_LOG_FILE.accepted"
printf '%s\n' '{"type":"key","keysym":4294967296,"down":true}' >&9
printf '%s\n' '{"type":"key","keysym":-1,"down":true}' >&9
printf '%s\n' '{"type":"key","keysym":4294967295,"down":true}' >&9

elapsed=0
while kill -0 "$handshake_adapter_pid" 2>/dev/null && [ "$elapsed" -lt 50 ]; do
  sleep 0.1
  elapsed=$((elapsed + 1))
done
if kill -0 "$handshake_adapter_pid" 2>/dev/null; then
  kill "$handshake_adapter_pid" 2>/dev/null || true
fi
set +e
wait "$handshake_adapter_pid"
handshake_isolation_status="$?"
wait "$server_pid"
handshake_isolation_server_status="$?"
set -e
exec 9>&-
handshake_isolation_output="$(cat "$HANDSHAKE_OUTPUT")"
if [ "$handshake_isolation_status" -ne 0 ] || [ "$handshake_isolation_server_status" -ne 0 ]; then
  echo "$handshake_isolation_output"
  exit 1
fi
assert_json_event "$handshake_isolation_output" "connected"
assert_json_event "$handshake_isolation_output" "frame_patch"
assert_json_string_field "$handshake_isolation_output" "name" "Stacio Handshake Isolation RFB"

start_fake_rfb_server success
success_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$success_output" "connected"
assert_json_event "$success_output" "frame_patch"
assert_json_string_field "$success_output" "name" "Stacio Fake RFB"
assert_json_number_field "$success_output" "width" "1024"
assert_json_number_field "$success_output" "height" "768"
grep -Fq "client_version=RFB 003.008" "$SERVER_LOG_FILE"
grep -Fq "selected_security=1" "$SERVER_LOG_FILE"
grep -Fq "shared_flag=1" "$SERVER_LOG_FILE"
grep -Fq "set_pixel_format=ok" "$SERVER_LOG_FILE"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server raw-padding-byte-zero
raw_padding_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$raw_padding_output" "frame_patch"
assert_json_string_field "$raw_padding_output" "name" "Stacio Raw Padding Byte RFB"
assert_frame_pixel "$raw_padding_output" "raw-padding-byte-zero" 0 0 red

start_fake_rfb_server one-outstanding-request
set +e
one_outstanding_output="$(run_with_timeout 4 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
one_outstanding_status="$?"
wait "$server_pid"
one_outstanding_server_status="$?"
set -e
if [ "$one_outstanding_status" -ne 0 ] || [ "$one_outstanding_server_status" -ne 0 ]; then
  echo "$one_outstanding_output"
  exit 1
fi
assert_json_string_field "$one_outstanding_output" "name" "Stacio Outstanding Request RFB"
assert_json_event "$one_outstanding_output" "frame_patch"

start_fake_rfb_server ipv6-success
set +e
ipv6_output="$(run_with_timeout 4 "$ADAPTER" "[::1]:$SERVER_PORT")"
ipv6_status="$?"
wait "$server_pid"
ipv6_server_status="$?"
set -e
if [ "$ipv6_status" -ne 0 ] || [ "$ipv6_server_status" -ne 0 ]; then
  echo "$ipv6_output"
  exit 1
fi
assert_json_string_field "$ipv6_output" "name" "Stacio IPv6 RFB"
assert_json_event "$ipv6_output" "frame_patch"

start_fake_rfb_server oversized-server-init
set +e
oversized_server_init_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
oversized_server_init_status="$?"
wait "$server_pid"
oversized_server_init_server_status="$?"
set -e
test "$oversized_server_init_status" -ne 124
test "$oversized_server_init_server_status" -eq 0
assert_json_event "$oversized_server_init_output" "error"
grep -Fq "桌面尺寸超出支持范围" <<<"$oversized_server_init_output"

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

assert_json_event "$server_cut_text_output" "connected"
assert_json_event "$server_cut_text_output" "clipboard"
assert_json_event "$server_cut_text_output" "frame_patch"
assert_json_string_field "$server_cut_text_output" "name" "Stacio ServerCutText RFB"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server extended-clipboard
EXTENDED_CLIPBOARD_INPUT_FILE="$TMP_DIR/extended-clipboard-input.jsonl"
/usr/bin/python3 - "$EXTENDED_CLIPBOARD_INPUT_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"type": "clipboard", "text": "Stacio 本地剪贴板 🚀"}, ensure_ascii=False) + "\n")
PY
set +e
extended_clipboard_output="$(
  run_with_timeout 4 /bin/sh -c 'exec "$1" "$2" < "$3"' sh \
    "$ADAPTER" "127.0.0.1:$SERVER_PORT" "$EXTENDED_CLIPBOARD_INPUT_FILE"
)"
extended_clipboard_status="$?"
wait "$server_pid"
extended_clipboard_server_status="$?"
set -e
if [ "$extended_clipboard_status" -ne 0 ] || [ "$extended_clipboard_server_status" -ne 0 ]; then
  echo "$extended_clipboard_output"
  exit 1
fi
assert_json_event "$extended_clipboard_output" "clipboard"
assert_json_string_field "$extended_clipboard_output" "name" "Stacio Extended Clipboard RFB"
grep -Fq 'Windows 远端剪贴板 ✓' <<<"$extended_clipboard_output"

start_fake_rfb_server oversized-server-cut-text
set +e
oversized_server_cut_text_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
oversized_server_cut_text_status="$?"
wait "$server_pid"
oversized_server_cut_text_server_status="$?"
set -e
test "$oversized_server_cut_text_status" -ne 124
test "$oversized_server_cut_text_server_status" -eq 0
grep -Fq "剪贴板文本过长" <<<"$oversized_server_cut_text_output"

start_fake_rfb_server bounded-client-input
BOUNDED_INPUT_FILE="$TMP_DIR/bounded-client-input.jsonl"
/usr/bin/python3 - "$BOUNDED_INPUT_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps({"type": "clipboard", "text": "x" * 1_048_577}) + "\n")
    handle.write("z" * 2_097_153 + "\n")
    handle.write(json.dumps({"type": "resize_request", "width": 8_193, "height": 1}) + "\n")
    handle.write(json.dumps({"type": "pointer", "x": 12, "y": 34, "buttons": 1}) + "\n")
PY
set +e
bounded_client_input_output="$(
  run_with_timeout 4 /bin/sh -c 'exec "$1" "$2" < "$3"' sh \
    "$ADAPTER" "127.0.0.1:$SERVER_PORT" "$BOUNDED_INPUT_FILE"
)"
bounded_client_input_status="$?"
wait "$server_pid"
bounded_client_input_server_status="$?"
set -e
if [ "$bounded_client_input_status" -ne 0 ] || [ "$bounded_client_input_server_status" -ne 0 ]; then
  echo "$bounded_client_input_output"
  exit 1
fi
assert_json_event "$bounded_client_input_output" "frame_patch"
assert_json_string_field "$bounded_client_input_output" "name" "Stacio Bounded Client Input RFB"

start_fake_rfb_server scroll-input
SCROLL_INPUT_FILE="$TMP_DIR/scroll-input.jsonl"
printf '%s\n' '{"type":"pointer","x":12,"y":34,"buttons":1,"scroll_dx":-1,"scroll_dy":1}' >"$SCROLL_INPUT_FILE"
set +e
scroll_input_output="$(
  run_with_timeout 4 /bin/sh -c 'exec "$1" "$2" < "$3"' sh \
    "$ADAPTER" "127.0.0.1:$SERVER_PORT" "$SCROLL_INPUT_FILE"
)"
scroll_input_status="$?"
wait "$server_pid"
scroll_input_server_status="$?"
set -e
if [ "$scroll_input_status" -ne 0 ] || [ "$scroll_input_server_status" -ne 0 ]; then
  echo "$scroll_input_output"
  exit 1
fi
assert_json_string_field "$scroll_input_output" "name" "Stacio Scroll Input RFB"
assert_json_event "$scroll_input_output" "frame_patch"

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

assert_json_event "$bell_output" "connected"
assert_json_event "$bell_output" "frame_patch"
assert_json_string_field "$bell_output" "name" "Stacio Bell RFB"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server colour-map-before-update
set +e
colour_map_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
colour_map_status="$?"
set -e
wait "$server_pid"
if [ "$colour_map_status" -ne 0 ]; then
  echo "$colour_map_output"
  exit "$colour_map_status"
fi

assert_json_event "$colour_map_output" "connected"
assert_json_event "$colour_map_output" "frame_patch"
assert_json_string_field "$colour_map_output" "name" "Stacio Colour Map RFB"

start_fake_rfb_server hextile
hextile_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$hextile_output" "connected"
assert_json_event "$hextile_output" "frame_patch"
assert_json_string_field "$hextile_output" "name" "Stacio Hextile RFB"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server hextile-nibbles
hextile_nibbles_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$hextile_nibbles_output" "frame_patch"
assert_json_string_field "$hextile_nibbles_output" "name" "Stacio Hextile Nibbles RFB"
assert_frame_pixel "$hextile_nibbles_output" "hextile-nibbles" 7 7 red

start_fake_rfb_server hextile-color-persistence
hextile_color_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$hextile_color_output" "frame_patch"
assert_json_string_field "$hextile_color_output" "name" "Stacio Hextile Color Persistence RFB"
assert_frame_pixel "$hextile_color_output" "hextile-color-background" 17 1 green
assert_frame_pixel "$hextile_color_output" "hextile-color-foreground" 23 7 red

start_fake_rfb_server oversized-hextile
set +e
oversized_hextile_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
oversized_hextile_status="$?"
wait "$server_pid"
oversized_hextile_server_status="$?"
set -e
test "$oversized_hextile_status" -ne 124
test "$oversized_hextile_server_status" -eq 0
grep -Fq "Hextile 矩形过大" <<<"$oversized_hextile_output"

start_fake_rfb_server hextile-subrect-out-of-bounds
set +e
hextile_subrect_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
hextile_subrect_status="$?"
wait "$server_pid"
hextile_subrect_server_status="$?"
set -e
test "$hextile_subrect_status" -ne 124
test "$hextile_subrect_server_status" -eq 0
grep -Fq "Hextile 子矩形越界" <<<"$hextile_subrect_output"

start_fake_rfb_server hextile-reserved-bits
set +e
hextile_reserved_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
hextile_reserved_status="$?"
wait "$server_pid"
hextile_reserved_server_status="$?"
set -e
test "$hextile_reserved_status" -ne 124
test "$hextile_reserved_server_status" -eq 0
grep -Fq "Hextile 子编码包含保留位" <<<"$hextile_reserved_output"

start_fake_rfb_server zlib
zlib_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$zlib_output" "connected"
assert_json_event "$zlib_output" "frame_patch"
assert_json_string_field "$zlib_output" "name" "Stacio Zlib RFB"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server zrle
zrle_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$zrle_output" "frame_patch"
assert_json_string_field "$zrle_output" "name" "Stacio ZRLE RFB"
assert_frame_pixel "$zrle_output" "zrle-raw" 0 0 red
assert_frame_pixel "$zrle_output" "zrle-solid" 64 0 green

start_fake_rfb_server zrle-continuous-stream
zrle_continuous_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_string_field "$zrle_continuous_output" "name" "Stacio Continuous ZRLE RFB"
zrle_continuous_frame_count="$(grep -c '\"type\":\"frame_patch\"' <<<"$zrle_continuous_output" || true)"
test "$zrle_continuous_frame_count" -eq 2

start_fake_rfb_server tight-fill
tight_fill_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$tight_fill_output" "frame_patch"
assert_frame_pixel "$tight_fill_output" "tight-fill" 0 0 red

start_fake_rfb_server tight-fill-wide
tight_fill_wide_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$tight_fill_wide_output" "frame_patch"
assert_json_string_field "$tight_fill_wide_output" "name" "Stacio Wide Tight Fill RFB"
assert_frame_pixel "$tight_fill_wide_output" "tight-fill-wide" 2048 0 red

start_fake_rfb_server tight-fill-out-of-bounds
set +e
tight_fill_bounds_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
tight_fill_bounds_status="$?"
wait "$server_pid"
tight_fill_bounds_server_status="$?"
set -e
test "$tight_fill_bounds_status" -ne 124
test "$tight_fill_bounds_server_status" -eq 0
assert_json_event "$tight_fill_bounds_output" "disconnected"
grep -Fq "帧缓冲矩形越界" <<<"$tight_fill_bounds_output"

start_fake_rfb_server tight-copy-small
tight_copy_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$tight_copy_output" "frame_patch"
assert_frame_pixel "$tight_copy_output" "tight-copy" 0 0 green

start_fake_rfb_server tight-palette
tight_palette_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$tight_palette_output" "frame_patch"
assert_frame_pixel "$tight_palette_output" "tight-palette" 6 4 green

start_fake_rfb_server tight-gradient
tight_gradient_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$tight_gradient_output" "frame_patch"

start_fake_rfb_server tight-continuous-stream
tight_continuous_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_string_field "$tight_continuous_output" "name" "Stacio Continuous Tight RFB"
tight_continuous_frame_count="$(grep -c '\"type\":\"frame_patch\"' <<<"$tight_continuous_output" || true)"
test "$tight_continuous_frame_count" -eq 2

start_fake_rfb_server tight-jpeg
tight_jpeg_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$tight_jpeg_output" "frame_patch"
assert_json_string_field "$tight_jpeg_output" "name" "Stacio Tight JPEG RFB"

start_fake_rfb_server zlib-continuous-stream
zlib_continuous_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_string_field "$zlib_continuous_output" "name" "Stacio Continuous Zlib RFB"
zlib_continuous_frame_count="$(grep -c '\"type\":\"frame_patch\"' <<<"$zlib_continuous_output" || true)"
if [ "$zlib_continuous_frame_count" -ne 2 ]; then
  echo "expected 2 continuous Zlib frame patches, got $zlib_continuous_frame_count" >&2
  echo "$zlib_continuous_output"
  exit 1
fi
if grep -Fq "Zlib 解压失败" <<<"$zlib_continuous_output"; then
  echo "$zlib_continuous_output"
  exit 1
fi

start_fake_rfb_server fence
set +e
fence_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
fence_status="$?"
wait "$server_pid"
fence_server_status="$?"
set -e
if [ "$fence_status" -ne 0 ] || [ "$fence_server_status" -ne 0 ]; then
  echo "$fence_output"
  exit 1
fi
assert_json_event "$fence_output" "frame_patch"
assert_json_string_field "$fence_output" "name" "Stacio Fence RFB"
if grep -Fq "未知服务端消息类型" <<<"$fence_output"; then
  echo "$fence_output"
  exit 1
fi

start_fake_rfb_server no-fence-probe
set +e
no_fence_output="$(run_with_timeout 13 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
no_fence_status="$?"
wait "$server_pid"
no_fence_server_status="$?"
set -e
if [ "$no_fence_status" -ne 0 ] || [ "$no_fence_server_status" -ne 0 ]; then
  echo "$no_fence_output"
  exit 1
fi
assert_json_event "$no_fence_output" "frame_patch"
assert_json_string_field "$no_fence_output" "name" "Stacio No Fence RFB"

RESIZE_INPUT_FILE="$TMP_DIR/resize-input.jsonl"
printf '%s\n' '{"type":"resize_request","width":1280,"height":720}' >"$RESIZE_INPUT_FILE"
start_fake_rfb_server set-desktop-size-unsupported
set +e
unsupported_resize_output="$(
  run_with_timeout 3 /bin/sh -c 'exec "$1" "$2" < "$3"' sh \
    "$ADAPTER" "127.0.0.1:$SERVER_PORT" "$RESIZE_INPUT_FILE"
)"
unsupported_resize_status="$?"
wait "$server_pid"
unsupported_resize_server_status="$?"
set -e
if [ "$unsupported_resize_status" -ne 0 ] || [ "$unsupported_resize_server_status" -ne 0 ]; then
  echo "$unsupported_resize_output"
  exit 1
fi
assert_json_event "$unsupported_resize_output" "frame_patch"
assert_json_string_field "$unsupported_resize_output" "name" "Stacio Unsupported SetDesktopSize RFB"

start_fake_rfb_server set-desktop-size-request
set +e
set_desktop_size_output="$(
  run_with_timeout 3 /bin/sh -c 'exec "$1" "$2" < "$3"' sh \
    "$ADAPTER" "127.0.0.1:$SERVER_PORT" "$RESIZE_INPUT_FILE"
)"
set_desktop_size_status="$?"
wait "$server_pid"
set_desktop_size_server_status="$?"
set -e
if [ "$set_desktop_size_status" -ne 0 ] || [ "$set_desktop_size_server_status" -ne 0 ]; then
  echo "$set_desktop_size_output"
  exit 1
fi
assert_json_event "$set_desktop_size_output" "frame_patch"
assert_json_string_field "$set_desktop_size_output" "name" "Stacio SetDesktopSize RFB"

start_fake_rfb_server desktop-size
desktop_size_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$desktop_size_output" "connected"
assert_json_event "$desktop_size_output" "resize"
assert_json_string_field "$desktop_size_output" "name" "Stacio DesktopSize RFB"
assert_json_number_field "$desktop_size_output" "width" "1280"
assert_json_number_field "$desktop_size_output" "height" "720"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server desktop-size-preserves-canvas
desktop_size_preserved_output="$(run_with_timeout 4 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"
assert_json_event "$desktop_size_preserved_output" "resize"
assert_json_string_field "$desktop_size_preserved_output" "name" "Stacio Preserved DesktopSize RFB"
assert_frame_pixel "$desktop_size_preserved_output" "desktop-size-preserved" 0 0 red last

start_fake_rfb_server oversized-desktop-size
set +e
oversized_desktop_size_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
oversized_desktop_size_status="$?"
wait "$server_pid"
oversized_desktop_size_server_status="$?"
set -e
test "$oversized_desktop_size_status" -ne 124
test "$oversized_desktop_size_server_status" -eq 0
grep -Fq "桌面尺寸超出支持范围" <<<"$oversized_desktop_size_output"

start_fake_rfb_server extended-desktop-size
extended_desktop_size_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$extended_desktop_size_output" "connected"
assert_json_event "$extended_desktop_size_output" "resize"
assert_json_event "$extended_desktop_size_output" "frame_patch"
assert_json_string_field "$extended_desktop_size_output" "name" "Stacio ExtendedDesktopSize RFB"
assert_json_number_field "$extended_desktop_size_output" "width" "1280"
assert_json_number_field "$extended_desktop_size_output" "height" "720"
assert_frame_pixel "$extended_desktop_size_output" "extended-desktop-size-new-area" 0 0 red

start_fake_rfb_server cursor-bitmap
cursor_bitmap_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$cursor_bitmap_output" "pointer_bitmap"
assert_json_string_field "$cursor_bitmap_output" "name" "Stacio Cursor Bitmap RFB"
assert_json_number_field "$cursor_bitmap_output" "width" "2"
assert_json_number_field "$cursor_bitmap_output" "height" "2"
assert_json_number_field "$cursor_bitmap_output" "hotspot_x" "1"
assert_json_number_field "$cursor_bitmap_output" "hotspot_y" "0"
assert_json_string_field "$cursor_bitmap_output" "data" "MCAQ\\/2BQQACQgHAAwLCg\\/w=="
cursor_frame_count="$(grep -Ec '\"type\":\"frame(_patch)?\"' <<<"$cursor_bitmap_output" || true)"
if [ "$cursor_frame_count" -ne 0 ]; then
  echo "expected cursor-only update to emit 0 framebuffer images, got $cursor_frame_count" >&2
  exit 1
fi

start_fake_rfb_server empty-cursor
empty_cursor_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$empty_cursor_output" "pointer_visibility"
assert_json_string_field "$empty_cursor_output" "name" "Stacio Empty Cursor RFB"
grep -Fq '"visible":false' <<<"$empty_cursor_output"

start_fake_rfb_server last-rect
last_rect_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$last_rect_output" "connected"
assert_json_event "$last_rect_output" "frame_patch"
assert_json_string_field "$last_rect_output" "name" "Stacio LastRect RFB"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
grep -Fq "framebuffer_update_request=1024x768" "$SERVER_LOG_FILE"

start_fake_rfb_server rfb-003-003-none
rfb_003_003_none_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$rfb_003_003_none_output" "connected"
assert_json_event "$rfb_003_003_none_output" "frame_patch"
assert_json_string_field "$rfb_003_003_none_output" "name" "Stacio RFB 003.003 None"
grep -Fq "client_version=RFB 003.003" "$SERVER_LOG_FILE"
grep -Fq "security_type=1" "$SERVER_LOG_FILE"
grep -Fq "shared_flag=1" "$SERVER_LOG_FILE"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"
start_fake_rfb_server rfb-003-007-none
rfb_003_007_none_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
wait "$server_pid"

assert_json_event "$rfb_003_007_none_output" "connected"
assert_json_event "$rfb_003_007_none_output" "frame_patch"
assert_json_string_field "$rfb_003_007_none_output" "name" "Stacio RFB 003.007 None"
grep -Fq "client_version=RFB 003.007" "$SERVER_LOG_FILE"
grep -Fq "selected_security=1" "$SERVER_LOG_FILE"
grep -Fq "shared_flag=1" "$SERVER_LOG_FILE"
grep -Fq "set_encodings=tight+zrle+zlib+hextile+raw+quality-7+desktop-size+last-rect+cursor+cursor-position" "$SERVER_LOG_FILE"

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
assert_json_event "$rfb_003_003_password_output" "connected"
assert_json_string_field "$rfb_003_003_password_output" "name" "Stacio RFB 003.003 VNCPassword"
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
assert_json_event "$rfb_003_007_password_output" "connected"
assert_json_string_field "$rfb_003_007_password_output" "name" "Stacio RFB 003.007 VNCPassword"
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
assert_json_event "$non_rfb_output" "error"
grep -Fq '服务端不是 RFB\/VNC 协议' <<<"$non_rfb_output"

start_fake_rfb_server no-none
set +e
no_none_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
no_none_status="$?"
set -e
wait "$server_pid"
test "$no_none_status" -ne 0
assert_json_event "$no_none_output" "error"
grep -Fq "不支持的安全类型：16" <<<"$no_none_output"

start_fake_rfb_server password-auth
set +e
password_auth_output="$(run_with_timeout 3 "$ADAPTER" "127.0.0.1:$SERVER_PORT")"
password_auth_status="$?"
set -e
wait "$server_pid"
test "$password_auth_status" -ne 0
assert_json_event "$password_auth_output" "error"
grep -Fq "VNC 密码认证" <<<"$password_auth_output"
grep -Fq "未提供密码" <<<"$password_auth_output"

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
assert_json_event "$password_auth_success_output" "connected"
assert_json_event "$password_auth_success_output" "frame_patch"
assert_json_string_field "$password_auth_success_output" "name" "Stacio VNCPassword RFB"
grep -Fq "selected_security=2" "$SERVER_LOG_FILE"
grep -Fq "vnc_password_response=ok" "$SERVER_LOG_FILE"
if grep -Fq "secretpw" <<<"$password_auth_success_output"; then
  echo "VNC adapter leaked password in stdout" >&2
  exit 1
fi

start_fake_rfb_server password-preferred-over-none
set +e
password_preferred_output="$(
  run_with_timeout 4 /usr/bin/env STACIO_VNC_PASSWORD=secretpw \
    "$ADAPTER" "127.0.0.1:$SERVER_PORT"
)"
password_preferred_status="$?"
wait "$server_pid"
password_preferred_server_status="$?"
set -e
if [ "$password_preferred_status" -ne 0 ] || [ "$password_preferred_server_status" -ne 0 ]; then
  echo "$password_preferred_output"
  exit 1
fi
assert_json_string_field "$password_preferred_output" "name" "Stacio Preferred Password RFB"
grep -Fq "selected_security=2" "$SERVER_LOG_FILE"
grep -Fq "vnc_password_response=ok" "$SERVER_LOG_FILE"

echo "vnc_adapter_rfb_handshake_test passed"
