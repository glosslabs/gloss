#!/usr/bin/env bash
# Load-test gloss, mist and Cowboy with oha (https://github.com/hatoo/oha).
#
#   ./run.sh                 # every server, every scenario
#   ./run.sh gloss           # one server
#   DURATION=5s CONNECTIONS=50 SCHEDULERS=8 ./run.sh
#
# The server gets 4 schedulers by default, so it rather than oha (running
# on the same machine) is what saturates.
# Each server is started fresh; each scenario runs after a short warm-up.
# Prints requests per second and p50/p99 latency.
set -euo pipefail
cd "$(dirname "$0")"

servers=("${@:-gloss mist cowboy}")
read -r -a servers <<<"${servers[*]}"
duration=${DURATION:-10s}
connections=${CONNECTIONS:-100}
schedulers=${SCHEDULERS:-4}
port=4100

gleam build >/dev/null
if curl -s -o /dev/null "http://127.0.0.1:$port/"; then
  echo "port $port is already in use" >&2
  exit 1
fi

# Run oha with the given options against a path, after a warm-up.
scenario() {
  local name=$1 path=$2; shift 2
  oha --no-tui -z 2s -c "$connections" "http://127.0.0.1:$port$path" >/dev/null
  oha --no-tui -c "$connections" --output-format json "$@" \
    "http://127.0.0.1:$port$path" |
    python3 -c '
import json, sys
name = sys.argv[1]
r = json.load(sys.stdin)
rps = r["summary"]["requestsPerSec"]
p = r["latencyPercentiles"]
codes = dict(r.get("statusCodeDistribution", {}), **r.get("errorDistribution", {}))
ms = lambda q: "%6.2f ms" % (p[q] * 1000) if p[q] is not None else "     -   "
print("  %-13s %9.0f req/s   p50 %s   p99 %s   %s" % (name, rps, ms("p50"), ms("p99"), codes))
' "$name"
}

# Wait until few sockets are in TIME_WAIT, so new connections get ports.
cool_down() {
  until [ "$(netstat -an | grep -c TIME_WAIT)" -lt 1000 ]; do sleep 1; done
}

for server in "${servers[@]}"; do
  cool_down
  echo "$server"
  erl +S "$schedulers" -noshell -pa build/dev/erlang/*/ebin \
    -eval "bench:main()" -extra "$server" "$port" >/dev/null &
  pid=$!
  until curl -s -o /dev/null "http://127.0.0.1:$port/"; do sleep 0.1; done
  scenario hello / -z "$duration"
  scenario json /json -z "$duration"
  scenario params /users/7/posts/42 -z "$duration"
  # A new connection per request leaves each client port in TIME_WAIT for
  # 2 x MSL (30s on macOS), so this runs a fixed count that fits the
  # ephemeral range, and waits for the ports to free up first.
  cool_down
  scenario no-keepalive / -n 10000 --disable-keepalive
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  sleep 1
done
