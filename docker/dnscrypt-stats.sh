#!/bin/sh
# Fetch dnscrypt-proxy monitoring metrics and publish them for the stats page.
#
# Why server-side: dnscrypt-proxy's monitoring UI sets NO CORS headers
# (see dnscrypt-proxy/monitoring_ui.go - handlers only set Cache-Control and
# Content-Type), so the browser cannot fetch it cross-origin. It also uses HTTP
# Basic auth, which must not end up in the browser.
#
# So the container polls the endpoint with curl and writes a plain file into the
# directory darkhttpd already serves; the page then reads it same-origin.
# Credentials live only in container env vars, never in the page.
#
# Two files are produced:
#   <OUT>.json  verbatim upstream JSON (never re-encoded -> no escaping bugs)
#   <OUT>.meta  small JSON with fetch status/time, for a staleness banner
#
# On failure the previous .json is deliberately left untouched, so the page can
# keep showing the last known values instead of blanking out.
#
# Env:
#   DNSCRYPT_METRICS_URL  full URL of the JSON endpoint, e.g.
#                         http://192.168.1.35:8080/api/metrics
#                         (empty = feature disabled)
#   DNSCRYPT_USER / DNSCRYPT_PASS  basic auth credentials
#   DNSCRYPT_TIMEOUT      curl timeout seconds (default 10)
#   DNSCRYPT_STATS_FILE   output path (default /usr/share/mosdns-stats/dnscrypt)
# Exit: 0 on success (or nothing to do), 1 on failure.
set -eu

URL="${DNSCRYPT_METRICS_URL:-}"
BASE="${DNSCRYPT_STATS_FILE:-/usr/share/mosdns-stats/dnscrypt}"
TIMEOUT="${DNSCRYPT_TIMEOUT:-10}"
USER="${DNSCRYPT_USER:-}"
PASS="${DNSCRYPT_PASS:-}"

[ -n "$URL" ] || exit 0

mkdir -p "$(dirname "$BASE")"

# Escape a string for embedding in a JSON string literal.
json_str() {
    printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_meta() { # $1=ok(0/1) $2=err
    tmp="${BASE}.meta.tmp.$$"
    printf '{"ok":%s,"ts":%s,"err":"%s"}\n' \
        "$1" "$(date +%s)" "$(json_str "$2")" > "$tmp"
    mv -f "$tmp" "${BASE}.meta"
}

# NOTE: -u keeps any characters in user/pass valid. It must NOT be built into a
# single variable and expanded unquoted: word splitting would break on spaces
# and curl would treat the remainder as extra URLs. Hence the two branches.
# Trade-off: credentials are visible in this process's argv to anything inside
# the container (/proc/*/cmdline); acceptable for a single-purpose container
# that runs no other user workloads.
tmp="${BASE}.json.tmp.$$"
if [ -n "$USER" ]; then
    fetch() { curl -fsS --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" --user "$USER:$PASS" -o "$tmp" "$URL"; }
else
    fetch() { curl -fsS --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" -o "$tmp" "$URL"; }
fi

if fetch; then
    # Sanity check: must be JSON, not an HTML error/login page.
    if head -c 1 "$tmp" | grep -q '{'; then
        mv -f "$tmp" "${BASE}.json"
        write_meta 1 ""
        exit 0
    fi
    rm -f "$tmp"
    write_meta 0 "响应不是 JSON（检查 dnscrypt-proxy 的 monitoring_ui 配置）"
    exit 1
fi
rm -f "$tmp"
write_meta 0 "无法连接 $URL（检查地址、网络与账号密码）"
exit 1
