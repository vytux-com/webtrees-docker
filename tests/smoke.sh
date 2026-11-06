#!/usr/bin/env bash
# Smoke tests for the image. Requires docker (with compose) and curl.
#   IMAGE=webtrees-nginx:test tests/smoke.sh
# The image is expected to have been built with
#   --build-arg WEBTREES_MODULES=magicsunday/webtrees-pedigree-chart
set -euo pipefail

IMAGE="${IMAGE:-webtrees-nginx:test}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
PROJECT="wtsmoke"
fails=0
# webtrees treats curl's default user agent as a robot.
UA="Mozilla/5.0 (X11; Linux x86_64) webtrees-smoke-test"

compose=(docker compose -p "$PROJECT" --env-file "$WORK/.env" -f "$ROOT/docker-compose.yml")

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fails=$((fails + 1)); }

cleanup() {
    status=$?
    if [ "$fails" -gt 0 ] || [ "$status" -ne 0 ]; then
        echo "--- logs ---"
        "${compose[@]}" logs --no-color webtrees 2>&1 || true
        docker logs wtsmoke-sqlite 2>&1 || true
    fi
    "${compose[@]}" down -v >/dev/null 2>&1 || true
    docker rm -f wtsmoke-sqlite >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

wait_healthy() {
    local container="$1"
    for _ in $(seq 1 90); do
        [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ] || return 1
        [ "$(docker inspect -f '{{.State.Health.Status}}' "$container")" = "healthy" ] && return 0
        sleep 2
    done
    return 1
}

expect_status() {
    local expected="$1" url="$2" actual
    actual="$(curl -A "$UA" -s -o /dev/null -w '%{http_code}' "$url")"
    if [ "$actual" = "$expected" ]; then pass "$url -> $actual"; else fail "$url -> $actual (expected $expected)"; fi
}

expect_body() {
    local needle="$1" url="$2"
    local body
    body="$(curl -A "$UA" -fsSL "$url" || true)"
    if grep -q "$needle" <<<"$body"; then pass "$url contains '$needle'"; else fail "$url missing '$needle'"; fi
}

###############################################################################
echo "== MariaDB + build-time and runtime modules + pretty URLs (compose) =="
grep -Ev '^(WEBTREES_PORT|BASE_URL|WEBTREES_MODULES)=' "$ROOT/.env.example" > "$WORK/.env"
cat >> "$WORK/.env" <<EOF
WEBTREES_ENV_FILE=$WORK/.env
WEBTREES_IMAGE=$IMAGE
WEBTREES_PORT=18080
BASE_URL=http://localhost:18080
WEBTREES_MODULES=magicsunday/webtrees-fan-chart
WT_SITE_TIMEZONE=Europe/London
EOF

"${compose[@]}" up -d --no-build
cid="$("${compose[@]}" ps -q webtrees)"
if wait_healthy "$cid"; then pass "container healthy"; else fail "container not healthy"; exit 1; fi

B=http://localhost:18080
expect_body  'webtrees' "$B/"
expect_status 200 "$B/login"
expect_status 308 "$B/index.php?route=%2Flogin"
expect_status 200 "$B/public/css/webtrees.min.css"
expect_status 404 "$B/data/config.ini.php"
expect_status 404 "$B/data/"
expect_status 404 "$B/vendor/autoload.php"
expect_status 404 "$B/app/Webtrees.php"
expect_status 404 "$B/composer.json"
expect_status 404 "$B/README.md"
expect_status 404 "$B/modules_v4/webtrees-fan-chart/module.php"
expect_status 404 "$B/.docker-modules"
expect_status 403 "$B/healthz"

headers="$(curl -A "$UA" -sS -D - -o /dev/null "$B/login" | tr -d '\r')"
if grep -qix 'server: nginx' <<<"$headers"; then pass "server version hidden"; else fail "server header: $(grep -i '^server' <<<"$headers")"; fi
if grep -qi '^x-powered-by' <<<"$headers"; then fail "X-Powered-By exposed"; else pass "no X-Powered-By"; fi

for module in webtrees-pedigree-chart webtrees-fan-chart; do
    if "${compose[@]}" exec -T webtrees test -f "modules_v4/$module/module.php"; then pass "module $module installed"; else fail "module $module missing"; fi
done

out="$("${compose[@]}" exec -T webtrees webtrees-cli user-list)"
if grep -q admin <<<"$out"; then pass "admin user created"; else fail "admin user missing"; fi
out="$("${compose[@]}" exec -T webtrees webtrees-cli site-setting --list TIMEZONE)"
if grep -q 'Europe/London' <<<"$out"; then pass "WT_SITE_* applied"; else fail "WT_SITE_TIMEZONE not applied"; fi
if "${compose[@]}" exec -T webtrees grep -q 'rewrite_urls="1"' data/config.ini.php; then pass "PRETTY_URLS written"; else fail "PRETTY_URLS not written"; fi

procs="$("${compose[@]}" exec -T webtrees ps -o user,args | grep -E 'nginx|php-fpm' | grep -v grep)"
if grep -vq '^www-data' <<<"$procs"; then fail "processes not running as www-data: $procs"; else pass "nginx/php-fpm run as www-data"; fi

"${compose[@]}" restart webtrees >/dev/null
if wait_healthy "$cid"; then pass "healthy after restart"; else fail "unhealthy after restart"; fi
out="$("${compose[@]}" logs webtrees)"
if grep -q 'modules already installed' <<<"$out"; then pass "modules not reinstalled on restart"; else fail "modules reinstalled on restart"; fi

###############################################################################
echo "== SQLite, read-only root FS, non-root user, all capabilities dropped =="
docker run -d --name wtsmoke-sqlite -p 18081:8080 \
    --read-only --tmpfs /tmp --tmpfs /run/webtrees:uid=82,gid=82 \
    --user 82:82 --cap-drop ALL --security-opt no-new-privileges:true \
    -e DB_TYPE=sqlite -e BASE_URL=http://localhost:18081 \
    -e WT_USER=admin -e WT_EMAIL=admin@example.com -e WT_PASS=sqlite-secret \
    "$IMAGE" >/dev/null
if wait_healthy wtsmoke-sqlite; then pass "container healthy"; else fail "container not healthy"; exit 1; fi
expect_body 'webtrees' http://localhost:18081/
expect_status 200 'http://localhost:18081/index.php?route=%2Flogin'

###############################################################################
if [ "$fails" -gt 0 ]; then
    echo "$fails check(s) failed"
    exit 1
fi
echo "All checks passed"
