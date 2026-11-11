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
# webtrees treats cookie-less clients with few headers as robots.
UA="webtrees-smoke-test"

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
    docker volume rm wtsmoke-sqlite-data >/dev/null 2>&1 || true
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
    actual="$(curl -A "$UA" -b x=y -s -o /dev/null -w '%{http_code}' "$url")"
    if [ "$actual" = "$expected" ]; then pass "$url -> $actual"; else fail "$url -> $actual (expected $expected)"; fi
}

expect_body() {
    local needle="$1" url="$2"
    local body
    body="$(curl -A "$UA" -b x=y -fsSL "$url" || true)"
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
PUID=1000
PGID=1000
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

headers="$(curl -A "$UA" -b x=y -sS -D - -o /dev/null "$B/login" | tr -d '\r')"
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

# shellcheck disable=SC2016 # expanded inside the container
procs="$("${compose[@]}" exec -T webtrees sh -c 'for p in $(pgrep -f "^(nginx|php-fpm)"); do awk "/^(Uid|Gid):/{print \$2}" /proc/$p/status; done' | sort -u | tr '\n' ' ')"
if [ "$procs" = "1000 " ]; then pass "nginx/php-fpm run as PUID/PGID 1000"; else fail "nginx/php-fpm uids/gids: $procs"; fi
out="$("${compose[@]}" exec -T webtrees stat -c %u:%g data)"
if [ "$out" = "1000:1000" ]; then pass "data owned by PUID:PGID"; else fail "data owned by $out"; fi
if "${compose[@]}" exec -T --user 1000:1000 webtrees sh -c 'test ! -w composer.json && test ! -w modules_v4 && test ! -w index.php'; then pass "code not writable by runtime user"; else fail "code writable by runtime user"; fi

"${compose[@]}" restart webtrees >/dev/null
if wait_healthy "$cid"; then pass "healthy after restart"; else fail "unhealthy after restart"; fi
out="$("${compose[@]}" logs webtrees)"
if grep -q 'modules already installed' <<<"$out"; then pass "modules not reinstalled on restart"; else fail "modules reinstalled on restart"; fi

###############################################################################
echo "== Unsafe PUID values are rejected =="
for bad in 0 10001 abc; do
    if timeout 60 docker run --rm -e PUID="$bad" "$IMAGE" >/dev/null 2>&1; then fail "PUID=$bad accepted"; else pass "PUID=$bad rejected"; fi
done

###############################################################################
echo "== SQLite, read-only root FS, arbitrary non-root user, all capabilities dropped =="
docker run --rm --user 0 --entrypoint chown -v wtsmoke-sqlite-data:/var/www/webtrees/data \
    "$IMAGE" -R 1234:1234 /var/www/webtrees/data
docker run -d --name wtsmoke-sqlite -p 18081:8080 \
    --read-only --tmpfs /tmp --tmpfs /run/webtrees \
    --user 1234:1234 --cap-drop ALL --security-opt no-new-privileges:true \
    -v wtsmoke-sqlite-data:/var/www/webtrees/data \
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
