#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Travis Wichert
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Image behavior smoke test for the Janus HPB container.
set -euo pipefail

image="${1:-ansible-role-mash-nextcloud-talk-hpb:local}"

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
dockerfile="${DOCKERFILE:-$repo_root/build/janus/Dockerfile}"

expected_version=$(sed -n 's/^ARG JANUS_VERSION=\(.*\)$/\1/p' "$dockerfile" | head -n 1)
if [ -z "$expected_version" ]; then
    echo "FAIL: cannot read 'ARG JANUS_VERSION=' from $dockerfile" >&2
    exit 1
fi

turn_secret=smoke-secret
container="janus-smoke-$$"
tmp_dir=$(mktemp -d)
overrides_dir="$tmp_dir/overrides"

cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    rm -rf "$tmp_dir"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

in_image() {
    docker run --rm --entrypoint sh "$image" -c "$1"
}

in_container() {
    docker exec "$container" sh -c "$1"
}

echo "== image: $image (expected Janus $expected_version)"

# --- 1. filesystem and plugin layout -----------------------------------------
[ "$(in_image 'id -u')" = "10001" ] || fail "image user is not 10001"
in_image 'test -x /opt/janus/bin/janus' || fail "/opt/janus/bin/janus is not executable"
if in_image 'test -e /opt/janus/bin/janus-pp-rec'; then
    fail "janus-pp-rec is present (post-processing must be disabled)"
fi

plugin_bases=$(in_image 'ls /opt/janus/lib/janus/plugins' | sed 's/\.so.*$//' | sort -u | tr '\n' ' ')
[ "$plugin_bases" = "libjanus_videoroom " ] || fail "unexpected plugin set: $plugin_bases"

transport_bases=$(in_image 'ls /opt/janus/lib/janus/transports' | sed 's/\.so.*$//' | sort -u | tr '\n' ' ')
[ "$transport_bases" = "libjanus_http libjanus_websockets " ] || fail "unexpected transport set: $transport_bases"

event_bases=$(in_image 'ls /opt/janus/lib/janus/events' | sed 's/\.so.*$//' | sort -u | tr '\n' ' ')
[ "$event_bases" = "libjanus_wsevh " ] || fail "unexpected events set: $event_bases"
pass "non-root 10001, VideoRoom-only plugin set, HTTP/WS transports, wsevh events"

# --- 2. dynamic linking ------------------------------------------------------
ldd_report=$(in_image 'find /opt/janus /usr/local -type f \( -name "*.so" -o -name "*.so.*" -o -path "/opt/janus/bin/*" \) -print0 | xargs -0 -r ldd 2>/dev/null; exit 0')
if printf '%s\n' "$ldd_report" | grep -q 'not found'; then
    printf '%s\n' "$ldd_report" | grep 'not found' >&2
    fail "missing shared library dependency"
fi

janus_ldd=$(in_image 'ldd /opt/janus/bin/janus')
# Data channels (usrsctp) are required by the Nextcloud Talk signaling server.
for lib in libnice libsrtp2 libusrsctp; do
    printf '%s\n' "$janus_ldd" | grep -q "$lib" || fail "janus does not link $lib"
done

# The WebSocket transport and event handler are plugins, so they (not the Janus
# binary) link libwebsockets.
ws_ldd=$(in_image 'ldd /opt/janus/lib/janus/transports/libjanus_websockets.so')
printf '%s\n' "$ws_ldd" | grep -q libwebsockets || fail "the WebSocket transport does not link libwebsockets"

for lib in libavcodec libopus liblua libsofia libwebsockets; do
    if printf '%s\n' "$janus_ldd" | grep -q "$lib"; then
        fail "janus unexpectedly links $lib"
    fi
done
pass "all libraries resolve; janus links libnice/libsrtp2/libusrsctp, the WS transport links libwebsockets"

# --- 3. compiled version -----------------------------------------------------
version_output=$(docker run --rm --entrypoint /opt/janus/bin/janus "$image" --version 2>&1)
printf '%s\n' "$version_output" | grep -qF "$expected_version" || fail "janus --version does not report $expected_version"
pass "janus --version reports $expected_version"

# --- 4. start the container with an HPB override ------------------------------
mkdir -p "$overrides_dir"
docker run --rm --entrypoint cat "$image" /opt/janus/etc/janus/janus.jcfg > "$overrides_dir/janus.jcfg"
sed -i 's/^[[:space:]]*#\?[[:space:]]*log_to_stdout[[:space:]]*=.*/log_to_stdout = true/' "$overrides_dir/janus.jcfg"
chmod 755 "$tmp_dir" "$overrides_dir"
chmod 644 "$overrides_dir/janus.jcfg"

docker run -d --name "$container" \
    --init \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=64m,mode=1777 \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    -e JANUS_TURN_SERVER=127.0.0.1 \
    -e JANUS_TURN_SECRET="$turn_secret" \
    -e JANUS_EVENT_BACKEND=ws://127.0.0.1:9/spreed \
    -e JANUS_WS_IP=127.0.0.1 \
    -e JANUS_WS_ACL=127.0.0.1 \
    -e JANUS_HTTP_IP=127.0.0.1 \
    -e JANUS_HTTP_ACL=127.0.0.1 \
    -v "$overrides_dir:/etc/janus.d:ro" \
    "$image" >/dev/null

info=""
for _ in $(seq 1 30); do
    if info=$(in_container 'curl -fsS http://127.0.0.1:8088/janus/info' 2>/dev/null) && [ -n "$info" ]; then
        break
    fi
    info=""
    sleep 1
done
if [ -z "$info" ]; then
    docker logs "$container" >&2 || true
    fail "janus HTTP API did not answer on 127.0.0.1:8088"
fi
pass "janus answers on the loopback HTTP API"

# --- 5. /janus/info assertions ------------------------------------------------
printf '%s\n' "$info" | python3 -c '
import json, sys

expected = sys.argv[1]
info = json.load(sys.stdin)

if info["version_string"] != expected:
    sys.exit("FAIL: version_string is %r, expected %r" % (info["version_string"], expected))

def names(field):
    return sorted(info[field].keys()) if isinstance(info[field], dict) else sorted(info[field])

if names("plugins") != ["janus.plugin.videoroom"]:
    sys.exit("FAIL: plugins %r" % (names("plugins"),))
if names("transports") != ["janus.transport.http", "janus.transport.websockets"]:
    sys.exit("FAIL: transports %r" % (names("transports"),))
if names("events") != ["janus.eventhandler.wsevh"]:
    sys.exit("FAIL: events %r" % (names("events"),))

deps = info["dependencies"]
if "0.1.24" not in deps.get("libnice", ""):
    sys.exit("FAIL: libnice %r" % (deps.get("libnice"),))
if "2.8.1" not in deps.get("libsrtp", ""):
    sys.exit("FAIL: libsrtp %r" % (deps.get("libsrtp"),))
' "$expected_version" || fail "/janus/info assertions failed"
pass "/janus/info reports $expected_version, VideoRoom, http+ws, wsevh, libnice 0.1.24, libsrtp 2.8.1"

# --- 6. generated configuration and logs --------------------------------------
logs=$(docker logs "$container" 2>&1)
printf '%s\n' "$logs" | grep -q 'janus-entrypoint: applied override janus.jcfg' || fail "override was not applied"
printf '%s\n' "$logs" | grep -q 'janus-entrypoint: events backend' || fail "events backend was not configured"
printf '%s\n' "$logs" | grep -q 'janus-entrypoint: TURN' || fail "TURN was not configured"
if printf '%s\n' "$logs" | grep -qF "$turn_secret"; then
    fail "the TURN secret leaked into the container logs"
fi

cfg=/tmp/janus-config/janus.jcfg
in_container "grep -qx 'broadcast = true' $cfg" || fail "broadcast is not enabled in janus.jcfg"
in_container "grep -qx '	turn_server = \"127.0.0.1\"' $cfg" || fail "turn_server is not 127.0.0.1"
in_container "grep -qx '	turn_port = 3478' $cfg" || fail "turn_port is not 3478"
in_container "grep -qE '^[[:space:]]*turn_user = ' $cfg" || fail "turn_user is missing"
in_container "grep -qE '^[[:space:]]*turn_pwd = ' $cfg" || fail "turn_pwd is missing"
if in_container "grep -qE '^[[:space:]]*rtp_port_range' $cfg"; then
    fail "rtp_port_range was written although JANUS_RTP_PORT_RANGE is unset"
fi
[ "$(in_container "stat -c '%a' $cfg")" = "600" ] || fail "janus.jcfg is not mode 600"

wsevh=/tmp/janus-config/janus.eventhandler.wsevh.jcfg
in_container "grep -qx 'enabled = true' $wsevh" || fail "wsevh is not enabled"
in_container "grep -qx 'backend = \"ws://127.0.0.1:9/spreed\"' $wsevh" || fail "wsevh backend is wrong"
in_container "grep -qx 'subprotocol = \"janus-events\"' $wsevh" || fail "wsevh subprotocol is wrong"
in_container "grep -qx 'events = \"handles,media,webrtc\"' $wsevh" || fail "wsevh events list is wrong"

if in_container "grep -q 'room-1234' /tmp/janus-config/janus.plugin.videoroom.jcfg"; then
    fail "the sample VideoRoom room-1234 is still configured"
fi

http_cfg=/tmp/janus-config/janus.transport.http.jcfg
in_container "grep -qx 'admin_http = false' $http_cfg" || fail "admin_http is enabled"
in_container "grep -qx 'ip = \"127.0.0.1\"' $http_cfg" || fail "http transport is not loopback"
in_container "grep -qx 'acl = \"127.0.0.1\"' $http_cfg" || fail "http transport ACL is not loopback"

ws_cfg=/tmp/janus-config/janus.transport.websockets.jcfg
in_container "grep -qx 'admin_ws = false' $ws_cfg" || fail "admin_ws is enabled"
in_container "grep -qx 'ws_ip = \"127.0.0.1\"' $ws_cfg" || fail "ws transport is not loopback"
in_container "grep -qx 'ws_acl = \"127.0.0.1\"' $ws_cfg" || fail "ws transport ACL is not loopback"

pass "TURN REST block generated in a mode-600 config, no secret in logs, admin APIs disabled, no sample room"

echo "== smoke test passed"
