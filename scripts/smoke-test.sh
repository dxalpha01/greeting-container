#!/usr/bin/env bash
# Smoke test for the sample-app container image.
#
# Usage:
#   scripts/smoke-test.sh                                    # build from this repo and test
#   scripts/smoke-test.sh ghcr.io/dxalpha01/sample-app:v1    # test an existing image
#
# Requires: docker, curl.
set -euo pipefail

# Stop Git Bash on Windows rewriting container paths such as /app into Windows paths.
export MSYS_NO_PATHCONV=1

IMAGE="${1:-}"
APP_PORT=9090
GREETING="Smoke test greeting"
CONTAINER="sample-app-smoke-$$"
FAILURES=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

cleanup() {
    if [[ $FAILURES -gt 0 ]] && docker inspect "$CONTAINER" >/dev/null 2>&1; then
        echo "--- container logs ---"
        docker logs "$CONTAINER" 2>&1 | tail -n 30
    fi
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ -z "$IMAGE" ]]; then
    IMAGE="sample-app:smoke"
    echo "Building $IMAGE ..."
    docker build --quiet -t "$IMAGE" "$(dirname "$0")/.." >/dev/null
fi

echo "Testing $IMAGE"

echo "Image configuration"
check "configured to run as UID 10001" \
    test "$(docker image inspect --format '{{.Config.User}}' "$IMAGE")" = "10001:10001"
check "no compilers or debugging tools in the image" \
    docker run --rm "$IMAGE" sh -c '! command -v gcc && ! command -v curl && ! command -v vim'
check "pip is not installed in the runtime image" \
    docker run --rm "$IMAGE" sh -c '! command -v pip && ! python -c "import pip"'
check "application files are not writable by the app user" \
    docker run --rm "$IMAGE" sh -c 'test ! -w /app/app/app.py && test ! -w /app/app'

echo "Runtime (read-only root filesystem, PORT=$APP_PORT)"
docker run -d --name "$CONTAINER" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --health-interval 2s \
    -e PORT="$APP_PORT" \
    -e GREETING="$GREETING" \
    -p "127.0.0.1::$APP_PORT" \
    "$IMAGE" >/dev/null

if ! HOST_ADDR="$(docker port "$CONTAINER" "$APP_PORT/tcp" 2>/dev/null | head -n 1)" || [[ -z "$HOST_ADDR" ]]; then
    fail "container exited during startup"
    exit 1
fi
BASE_URL="http://$HOST_ADDR"

ready=false
for _ in $(seq 1 30); do
    if curl -fsS "$BASE_URL/healthz" >/dev/null 2>&1; then ready=true; break; fi
    sleep 1
done
if [[ "$ready" != true ]]; then
    fail "app did not answer on $BASE_URL/healthz within 30s"
    exit 1
fi

check "GET /healthz returns status ok" \
    sh -c "curl -fsS '$BASE_URL/healthz' | grep -q '\"status\":\"ok\"'"
check "GET / returns the GREETING from the environment" \
    sh -c "curl -fsS '$BASE_URL/' | grep -qF '\"message\":\"$GREETING\"'"
check "GET /info reports PORT=$APP_PORT" \
    sh -c "curl -fsS '$BASE_URL/info' | grep -q '\"port\":$APP_PORT'"
check "process runs as UID 10001" \
    test "$(docker exec "$CONTAINER" id -u)" = "10001"
check "access logs go to stdout" \
    sh -c "docker logs '$CONTAINER' 2>&1 | grep -q 'GET /healthz'"

healthy=false
for _ in $(seq 1 30); do
    if [[ "$(docker inspect --format '{{.State.Health.Status}}' "$CONTAINER")" == healthy ]]; then
        healthy=true
        break
    fi
    sleep 1
done
if [[ "$healthy" == true ]]; then pass "Docker HEALTHCHECK reports healthy"; else fail "Docker HEALTHCHECK reports healthy"; fi

echo "Shutdown"
start=$SECONDS
docker stop --time 10 "$CONTAINER" >/dev/null
elapsed=$((SECONDS - start))
exit_code="$(docker inspect --format '{{.State.ExitCode}}' "$CONTAINER")"
if [[ "$exit_code" == 0 && $elapsed -lt 10 ]]; then
    pass "stops cleanly on SIGTERM (exit 0 in ${elapsed}s)"
else
    fail "stops cleanly on SIGTERM (exit $exit_code in ${elapsed}s)"
fi

echo
if [[ $FAILURES -gt 0 ]]; then
    echo "$FAILURES check(s) failed"
    exit 1
fi
echo "All checks passed"
