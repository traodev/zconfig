#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/configs"
JAR_DIR="$ROOT/jars"
LOG_DIR="$ROOT/logs"
STATE_DIR="$LOG_DIR/state"

ENVIRONMENT="${ZCONFIG_ENV:-}"
FORCE_NODE="${ZCONFIG_NODE:-}"
FORCE_ROLE="${ZCONFIG_ROLE:-}"

mkdir -p "$LOG_DIR" "$STATE_DIR"

START_TIME="$(date +%s)"
RUN_ID="$(date '+%Y%m%d-%H%M%S')"

LOG_FILE="$LOG_DIR/zconfig-$RUN_ID.log"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

error() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
    error "$*"
    exit 1
}

section() {
    echo
    echo "============================================================"
    echo " $*"
    echo "============================================================"
    echo
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Missing command: $1"
}

require_file() {
    [ -f "$1" ] || fail "Missing file: $1"
}

json_get() {
    local file="$1"
    local expression="$2"

    python3 - "$file" "$expression" <<'PY'
import json
import sys

file = sys.argv[1]
expression = sys.argv[2]

with open(file, encoding="utf-8") as f:
    data = json.load(f)

value = data

for part in expression.split("."):
    if not part:
        continue

    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None

    if value is None:
        break

if isinstance(value, bool):
    print("true" if value else "false")
elif isinstance(value, (dict, list)):
    print(json.dumps(value, separators=(",", ":")))
elif value is not None:
    print(value)
PY
}

json_array() {
    local file="$1"
    local expression="$2"

    python3 - "$file" "$expression" <<'PY'
import json
import sys

file = sys.argv[1]
expression = sys.argv[2]

with open(file, encoding="utf-8") as f:
    data = json.load(f)

value = data

for part in expression.split("."):
    if not part:
        continue

    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None

if isinstance(value, list):
    for item in value:
        if isinstance(item, str):
            print(item)
        else:
            print(json.dumps(item, separators=(",", ":")))
PY
}

get_hostname() {
    hostnamectl --static 2>/dev/null ||
        hostname -s 2>/dev/null ||
        hostname
}

get_fqdn() {
    hostname -f 2>/dev/null ||
        hostname
}

get_primary_ip() {
    local ip

    ip="$(ip route get 1.1.1.1 2>/dev/null |
        awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i == "src") {
                        print $(i + 1)
                        exit
                    }
                }
            }
        ')"

    if [ -n "$ip" ]; then
        echo "$ip"
        return
    fi

    ip -4 addr show scope global 2>/dev/null |
        awk '/inet / {sub("/.*", "", $2); print $2; exit}'
}

get_all_ips() {
    ip -o -4 addr show scope global 2>/dev/null |
        awk '{split($4,a,"/"); print a[1]}'
}

detect_environment() {
    if [ -n "$ENVIRONMENT" ]; then
        echo "$ENVIRONMENT"
        return
    fi

    if [ -f "$CONFIG_DIR/local.json" ] && [ -f "$CONFIG_DIR/runtime.json" ]; then
        echo "local"
        return
    fi

    fail "Unable to determine environment. Set ZCONFIG_ENV."
}

detect_node() {
    if [ -n "$FORCE_NODE" ]; then
        echo "$FORCE_NODE"
        return
    fi

    local hostname
    local primary_ip

    hostname="$(get_hostname)"
    primary_ip="$(get_primary_ip)"

    log "Hostname detected: $hostname"
    log "Primary IP detected: ${primary_ip:-unknown}"

    if [ -f "$CONFIG_DIR/$ENVIRONMENT.json" ]; then
        local detected

        detected="$(
            python3 \
                "$CONFIG_DIR/$ENVIRONMENT.json" \
                "$hostname" \
                "$primary_ip" <<'PY'
import json
import socket
import sys

file = sys.argv[1]
hostname = sys.argv[2]
primary_ip = sys.argv[3]

with open(file, encoding="utf-8") as f:
    data = json.load(f)

nodes = data.get("nodes", [])

for node in nodes:
    if not isinstance(node, dict):
        continue

    names = [
        node.get("name"),
        node.get("hostname"),
        node.get("host"),
        node.get("id")
    ]

    addresses = [
        node.get("ip"),
        node.get("address"),
        node.get("private_ip"),
        node.get("public_ip")
    ]

    if hostname in names:
        print(node.get("name") or node.get("hostname") or node.get("id"))
        raise SystemExit

    if primary_ip and primary_ip in addresses:
        print(node.get("name") or node.get("hostname") or node.get("id"))
        raise SystemExit

print("")
PY
        )"

        if [ -n "$detected" ]; then
            echo "$detected"
            return
        fi
    fi

    case "$hostname" in
        *master*|*manager*|*controller*)
            echo "$hostname"
            return
            ;;

        *slave*|*worker*|*node*)
            echo "$hostname"
            return
            ;;
    esac

    fail "Unable to automatically determine node. Set ZCONFIG_NODE."
}

detect_role() {
    if [ -n "$FORCE_ROLE" ]; then
        echo "$FORCE_ROLE"
        return
    fi

    local role=""

    if [ -f "$CONFIG_DIR/$ENVIRONMENT.json" ]; then
        role="$(
            python3 \
                "$CONFIG_DIR/$ENVIRONMENT.json" \
                "$NODE_NAME" <<'PY'
import json
import sys

file = sys.argv[1]
node_name = sys.argv[2]

with open(file, encoding="utf-8") as f:
    data = json.load(f)

nodes = data.get("nodes", [])

for node in nodes:
    if not isinstance(node, dict):
        continue

    names = {
        node.get("name"),
        node.get("hostname"),
        node.get("host"),
        node.get("id")
    }

    if node_name in names:
        role = node.get("role") or node.get("type")

        if role:
            print(str(role).lower())
            raise SystemExit
PY
        )"
    fi

    case "$role" in
        master|slave)
            echo "$role"
            return
            ;;
    esac

    case "$NODE_NAME" in
        *master*|*manager*|*controller*)
            echo "master"
            return
            ;;

        *slave*|*worker*)
            echo "slave"
            return
            ;;
    esac

    fail "Unable to determine node role."
}

validate_json_configs() {
    section "CONFIGURATION VALIDATION"

    local file

    for file in \
        "$CONFIG_DIR/global.json" \
        "$CONFIG_DIR/$ENVIRONMENT.json" \
        "$CONFIG_DIR/runtime.json"
    do
        require_file "$file"

        python3 - "$file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    json.load(f)
PY

        log "Validated: $(basename "$file")"
    done

    if [ -f "$CONFIG_DIR/healthchecks.json" ]; then
        python3 - "$CONFIG_DIR/healthchecks.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    json.load(f)
PY

        log "Validated: healthchecks.json"
    fi

    require_file "$CONFIG_DIR/infra.masto"

    log "Validated: infra.masto"
}

check_runtime() {
    section "RUNTIME"

    require_command python3
    require_command java
    require_command docker
    require_command ip
    require_command awk
    require_command sed
    require_command grep

    log "Python: $(python3 --version 2>&1)"
    log "Java: $(java -version 2>&1 | head -n 1)"
    log "Docker: $(docker --version)"

    if ! docker info >/dev/null 2>&1; then
        fail "Docker daemon is unavailable"
    fi

    log "Docker daemon: available"
}

load_runtime() {
    section "RUNTIME CONFIG"

    RUNTIME_ENGINE="$(
        json_get "$CONFIG_DIR/runtime.json" "runtime.engine"
    )"

    [ -n "$RUNTIME_ENGINE" ] || RUNTIME_ENGINE="docker"

    log "Engine: $RUNTIME_ENGINE"

    case "$RUNTIME_ENGINE" in
        docker)
            ;;
        *)
            fail "Unsupported runtime engine: $RUNTIME_ENGINE"
            ;;
    esac
}

write_identity() {
    cat > "$STATE_DIR/node" <<EOF
environment=$ENVIRONMENT
node=$NODE_NAME
role=$NODE_ROLE
hostname=$HOSTNAME_SHORT
fqdn=$HOSTNAME_FQDN
primary_ip=${PRIMARY_IP:-unknown}
run_id=$RUN_ID
timestamp=$(date --iso-8601=seconds)
EOF

    log "Runtime identity written"
}

docker_networks() {
    section "DOCKER NETWORK"

    local network
    network="$(
        json_get "$CONFIG_DIR/runtime.json" "runtime.network.name"
    )"

    [ -n "$network" ] || network="zconfig"

    if docker network inspect "$network" >/dev/null 2>&1; then
        log "Docker network: $network"
    else
        log "Creating Docker network: $network"

        docker network create \
            --driver bridge \
            "$network" >/dev/null
    fi
}

stop_managed_containers() {
    section "STOPPING SERVICES"

    mapfile -t containers < <(
        docker ps \
            --format '{{.Names}}' \
            --filter "label=zconfig.managed=true"
    )

    if [ "${#containers[@]}" -eq 0 ]; then
        log "No managed containers running"
        return
    fi

    for container in "${containers[@]}"; do
        log "Stopping: $container"
        docker stop "$container" >/dev/null
    done
}

start_managed_containers() {
    section "STARTING DOCKER SERVICES"

    mapfile -t containers < <(
        docker ps -a \
            --format '{{.Names}}' \
            --filter "label=zconfig.managed=true"
    )

    if [ "${#containers[@]}" -eq 0 ]; then
        log "No managed Docker containers found"
        return
    fi

    for container in "${containers[@]}"; do
        local labels
        labels="$(docker inspect "$container" 2>/dev/null || true)"

        if ! grep -q "\"zconfig.managed\"" <<< "$labels"; then
            continue
        fi

        log "Starting: $container"
        docker start "$container" >/dev/null
    done
}

stop_java_services() {
    section "JAVA SERVICES"

    shopt -s nullglob

    for pid_file in "$LOG_DIR"/*.pid; do
        [ -f "$pid_file" ] || continue

        local pid
        local name

        pid="$(cat "$pid_file" 2>/dev/null || true)"
        name="$(basename "$pid_file" .pid)"

        if [ -z "$pid" ]; then
            rm -f "$pid_file"
            continue
        fi

        if kill -0 "$pid" 2>/dev/null; then
            log "Stopping Java service: $name ($pid)"

            kill "$pid" 2>/dev/null || true

            for _ in {1..20}; do
                if ! kill -0 "$pid" 2>/dev/null; then
                    break
                fi

                sleep 0.25
            done

            if kill -0 "$pid" 2>/dev/null; then
                warn "$name did not stop cleanly"
                kill -9 "$pid" 2>/dev/null || true
            fi
        fi

        rm -f "$pid_file"
    done
}

start_java_services() {
    section "STARTING JAVA SERVICES"

    [ -d "$JAR_DIR" ] || {
        warn "JAR directory does not exist: $JAR_DIR"
        return
    }

    shopt -s nullglob

    local jars=("$JAR_DIR"/*.jar)

    if [ "${#jars[@]}" -eq 0 ]; then
        log "No JAR services found"
        return
    fi

    for jar in "${jars[@]}"; do
        local name
        local logfile
        local pidfile

        name="$(basename "$jar" .jar)"
        logfile="$LOG_DIR/$name.log"
        pidfile="$LOG_DIR/$name.pid"

        log "Starting JAR: $name"

        nohup java \
            -jar "$jar" \
            >> "$logfile" 2>&1 &

        echo "$!" > "$pidfile"

        log "$name started with PID $!"
    done
}

check_docker_services() {
    section "DOCKER HEALTH"

    mapfile -t containers < <(
        docker ps -a \
            --format '{{.Names}}' \
            --filter "label=zconfig.managed=true"
    )

    for container in "${containers[@]}"; do
        state="$(
            docker inspect \
                -f '{{.State.Running}}' \
                "$container" 2>/dev/null ||
                echo "false"
        )"

        if [ "$state" = "true" ]; then
            log "$container: RUNNING"
        else
            warn "$container: STOPPED"
        fi
    done
}

check_java_services() {
    section "JAVA HEALTH"

    shopt -s nullglob

    for pid_file in "$LOG_DIR"/*.pid; do
        local pid
        local name

        pid="$(cat "$pid_file" 2>/dev/null || true)"
        name="$(basename "$pid_file" .pid)"

        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            log "$name: RUNNING ($pid)"
        else
            warn "$name: NOT RUNNING"
        fi
    done
}

run_healthchecks() {
    section "HEALTHCHECKS"

    [ -f "$CONFIG_DIR/healthchecks.json" ] || {
        log "No healthchecks configured"
        return
    }

    python3 "$CONFIG_DIR/../scripts/healthcheck.py" \
        2>/dev/null || {

        python3 - "$CONFIG_DIR/healthchecks.json" <<'PY'
import json
import sys
import urllib.request

with open(sys.argv[1], encoding="utf-8") as f:
    data = json.load(f)

checks = data.get("healthchecks", [])

for check in checks:
    name = check.get("name", "unknown")
    url = check.get("url")

    if not url:
        print(f"[zconfig] {name}: INVALID")
        continue

    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            print(f"[zconfig] {name}: OK ({response.status})")
    except Exception as exc:
        print(f"[zconfig] {name}: FAILED ({exc})")
PY
    }
}

write_state() {
    section "STATE"

    local end_time
    local duration

    end_time="$(date +%s)"
    duration=$((end_time - START_TIME))

    cat > "$STATE_DIR/runtime" <<EOF
run_id=$RUN_ID
environment=$ENVIRONMENT
node=$NODE_NAME
role=$NODE_ROLE
started_at=$START_TIME
completed_at=$end_time
duration=${duration}s
status=running
EOF

    log "Runtime state synchronized"
}

main() {
    section "ZCONFIG INFRASTRUCTURE"

    HOSTNAME_SHORT="$(get_hostname)"
    HOSTNAME_FQDN="$(get_fqdn)"
    PRIMARY_IP="$(get_primary_ip)"

    log "Hostname: $HOSTNAME_SHORT"
    log "FQDN: $HOSTNAME_FQDN"
    log "Primary IP: ${PRIMARY_IP:-unknown}"

    ENVIRONMENT="$(detect_environment)"

    log "Environment: $ENVIRONMENT"

    NODE_NAME="$(detect_node)"
    log "Node: $NODE_NAME"

    NODE_ROLE="$(detect_role)"

    case "$NODE_ROLE" in
        master|slave)
            ;;
        *)
            fail "Invalid node role: $NODE_ROLE"
            ;;
    esac

    log "Role: $NODE_ROLE"

    validate_json_configs
    check_runtime
    load_runtime
    write_identity

    docker_networks

    stop_java_services
    stop_managed_containers

    start_managed_containers

    if [ "$NODE_ROLE" = "master" ]; then
        section "MASTER SERVICES"
        log "Master node detected"
        log "Enabling infrastructure control services"
        start_java_services
    else
        section "SLAVE SERVICES"
        log "Slave node detected"
        log "Starting workload services"
        start_java_services
    fi

    sleep 3

    check_docker_services
    check_java_services
    run_healthchecks
    write_state

    section "COMPLETED"

    log "Environment : $ENVIRONMENT"
    log "Node        : $NODE_NAME"
    log "Role        : $NODE_ROLE"
    log "Status      : READY"
    log "Run ID      : $RUN_ID"
}

main "$@"
