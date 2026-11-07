#!/usr/bin/env bash
# Exercise an isolated CrowdSec v1.7.8 LAPI. This does not start Docker and
# does not read or change the project stack.
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Usage: %s /path/to/extracted/crowdsec-v1.7.8\n' "$0" >&2
    exit 2
fi

RELEASE=$1
CROWDSEC="${RELEASE}/cmd/crowdsec/crowdsec"
CSCLI="${RELEASE}/cmd/crowdsec-cli/cscli"
[[ -x "${CROWDSEC}" && -x "${CSCLI}" ]] || {
    printf 'CrowdSec binaries were not found in %s\n' "${RELEASE}" >&2
    exit 2
}
version="$("${CROWDSEC}" -version | awk 'NR==1 { print $2 }')"
[[ "${version}" == v1.7.8-* ]] || {
    printf 'Refusing to test %s; expected the v1.7.8 release binary\n' "${version}" >&2
    exit 2
}

BASE="$(mktemp -d /tmp/crowdsec-lapi-proof.XXXXXX)"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
mkdir -p "${BASE}/etc/hub" "${BASE}/data" "${BASE}/log" "${BASE}/plugins" "${BASE}/notifications"
cp "${RELEASE}/config/profiles.yaml" "${BASE}/etc/profiles.yaml"
printf '%s\n' 'simulation: false' > "${BASE}/etc/simulation.yaml"
printf '%s\n' 'share_manual_decisions: false' > "${BASE}/etc/console.yaml"
printf '%s\n' "url: http://127.0.0.1:${PORT}" > "${BASE}/etc/local_api_credentials.yaml"
: > "${BASE}/etc/online_api_credentials.yaml"
printf '%s\n' '{}' > "${BASE}/etc/hub/.index.json"
printf '%s\n' 'source: file' 'filenames:' "  - ${BASE}/empty.log" 'labels:' '  type: syslog' > "${BASE}/etc/acquis.yaml"
: > "${BASE}/empty.log"
cat > "${BASE}/etc/config.yaml" <<EOF
common:
  daemonize: false
  log_media: file
  log_level: info
  log_dir: ${BASE}/log
  log_max_size: 20
  compress_logs: false
  log_max_files: 2
config_paths:
  config_dir: ${BASE}/etc
  data_dir: ${BASE}/data
  simulation_path: ${BASE}/etc/simulation.yaml
  hub_dir: ${BASE}/etc/hub
  index_path: ${BASE}/etc/hub/.index.json
  notification_dir: ${BASE}/etc/notifications
  plugin_dir: ${BASE}/plugins
crowdsec_service:
  acquisition_path: ${BASE}/etc/acquis.yaml
  parser_routines: 1
db_config:
  log_level: info
  type: sqlite
  db_path: ${BASE}/data/crowdsec.db
  flush:
    max_items: 5000
    max_age: 7d
api:
  client:
    insecure_skip_verify: false
    credentials_path: ${BASE}/etc/local_api_credentials.yaml
  server:
    log_level: info
    listen_uri: 127.0.0.1:${PORT}
    profiles_path: ${BASE}/etc/profiles.yaml
    console_path: ${BASE}/etc/console.yaml
    online_client:
      credentials_path: ${BASE}/etc/online_api_credentials.yaml
    trusted_ips:
      - 127.0.0.1
      - 127.0.0.2
prometheus:
  enabled: false
EOF

pid=""
cleanup() {
    if [[ -n "${pid}" ]]; then
        kill "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null || true
    fi
    rm -rf "${BASE}"
}
trap cleanup EXIT

"${CROWDSEC}" -c "${BASE}/etc/config.yaml" -no-cs -no-capi > "${BASE}/stdout.log" 2>&1 &
pid=$!
ready=0
for _ in $(seq 1 50); do
    if ! kill -0 "${pid}" 2>/dev/null; then
        break
    fi
    if "${CSCLI}" -c "${BASE}/etc/config.yaml" bouncers list -o raw >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 0.1
done
if [[ "${ready}" -ne 1 ]]; then
    printf 'Isolated CrowdSec LAPI did not become ready\n' >&2
    cat "${BASE}/stdout.log" >&2 || true
    exit 1
fi

export CSCLI_BIN="${CSCLI}"
export CS_CONFIG="${BASE}/etc/config.yaml"
export CS_PORT="${PORT}"
export CS_VERSION="${version}"
python3 - <<'PY'
import json
import os
import socket
import subprocess
import sys

cscli = [os.environ["CSCLI_BIN"], "-c", os.environ["CS_CONFIG"]]
port = int(os.environ["CS_PORT"])
valid = "LAPIPROOFKEY0123456789abcd"
invalid = "LAPIPROOFBADKEY0123456789"
original_ip = "127.0.0.1"
other_ip = "127.0.0.2"

def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)

def bouncers():
    raw = subprocess.check_output(cscli + ["bouncers", "list", "-o", "json"], text=True)
    data = json.loads(raw or "[]")
    return data

def add_bouncer():
    subprocess.run(
        cscli + ["bouncers", "add", "lu-traefik", "--key", valid],
        check=True,
        stdout=subprocess.DEVNULL,
    )

def delete_original():
    subprocess.run(
        cscli + ["bouncers", "delete", "lu-traefik"],
        check=True,
        stdout=subprocess.DEVNULL,
    )

def request(method, source, key):
    sock = socket.create_connection(("127.0.0.1", port), timeout=5, source_address=(source, 0))
    try:
        payload = (
            f"{method} /v1/decisions HTTP/1.0\r\n"
            f"Host: 127.0.0.1:{port}\r\n"
            "X-Api-Key: " + key + "\r\n"
            "Connection: close\r\n\r\n"
        )
        sock.sendall(payload.encode())
        data = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            data += chunk
    finally:
        sock.close()
    line = data.split(b"\r\n", 1)[0].decode()
    parts = line.split()
    if len(parts) < 2 or not parts[1].isdigit():
        fail(f"{method} from {source} returned {line!r}")
    return int(parts[1])

def named(rows, name):
    found = [row for row in rows if row["name"] == name]
    if len(found) != 1:
        fail(f"expected one {name}, got {json.dumps(rows, sort_keys=True)}")
    return found[0]

def show(label, row):
    kept = {
        "name": row["name"],
        "ip_address": row["ip_address"],
        "auto_created": row["auto_created"],
        "last_pull": row["last_pull"],
        "type": row["type"],
        "version": row["version"],
        "auth_type": row["auth_type"],
        "revoked": row["revoked"],
    }
    print(f"{label}: {json.dumps(kept, sort_keys=True)}")

add_bouncer()
code = request("GET", original_ip, valid)
if code != 200:
    fail(f"GET from {original_ip} with the valid key returned {code}")
established = named(bouncers(), "lu-traefik")
if established["auto_created"] or established["ip_address"] != original_ip or not established["last_pull"]:
    fail(f"initial GET did not bind lu-traefik to {original_ip}: {established}")
before_get = json.dumps(established, sort_keys=True)

code = request("GET", other_ip, valid)
if code != 200:
    fail(f"GET from {other_ip} with the valid key returned {code}")
rows = bouncers()
if len(rows) != 2:
    fail(f"GET from {other_ip} produced {len(rows)} bouncers: {rows}")
original = named(rows, "lu-traefik")
auto = named(rows, f"lu-traefik@{other_ip}")
if json.dumps(original, sort_keys=True) != before_get:
    fail("GET from the second IP changed the original lu-traefik row")
if not auto["auto_created"] or auto["ip_address"] != other_ip:
    fail(f"automatic bouncer was not recorded for {other_ip}: {auto}")
show("after GET from second IP", original)
show("automatic bouncer", auto)

delete_original()
if bouncers():
    fail("deleting lu-traefik left another registration behind")

add_bouncer()
code = request("GET", original_ip, valid)
if code != 200:
    fail(f"second establishing GET returned {code}")
before_head = named(bouncers(), "lu-traefik")
before_head_json = json.dumps(before_head, sort_keys=True)

code = request("HEAD", other_ip, valid)
if code != 200:
    fail(f"HEAD from {other_ip} with the valid key returned {code}")
rows = bouncers()
if len(rows) != 1:
    fail(f"HEAD from {other_ip} produced {len(rows)} bouncers: {rows}")
after_head = named(rows, "lu-traefik")
if json.dumps(after_head, sort_keys=True) != before_head_json:
    fail("HEAD changed the original lu-traefik row, including last_pull or IP")
if after_head["last_pull"] != before_head["last_pull"]:
    fail("HEAD updated last_pull")

code = request("HEAD", other_ip, invalid)
if code != 403:
    fail(f"HEAD with an unknown key returned {code}")
code = request("GET", other_ip, invalid)
if code != 403:
    fail(f"GET with an unknown key returned {code}")
rows = bouncers()
if len(rows) != 1 or json.dumps(named(rows, "lu-traefik"), sort_keys=True) != before_head_json:
    fail("an unknown key changed or added a bouncer")

show("after HEAD from second IP", after_head)
print(f"CrowdSec {os.environ.get('CS_VERSION', 'v1.7.8')} accepted the valid key with 200 and rejected the unknown key with 403")
print("HEAD from 127.0.0.2 did not create lu-traefik@127.0.0.2 and did not change lu-traefik")
PY
