#!/usr/bin/env bash
#
# Check that a deployment is actually working — and that nothing else on the
# box stopped working.
#
#   ./deploy/verify.sh seriouslysimpleanalytics.com
#
# Read-only. Changes nothing.

set -uo pipefail

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "usage: ./deploy/verify.sh your-domain.com" >&2; exit 2; }

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true); cyan=$(tput setaf 6 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

PASS=0; FAIL=0; WARN=0
say()  { printf '\n%s==>%s %s\n' "$cyan$bold" "$reset" "$*"; }
pass() { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
fail() { FAIL=$((FAIL+1)); printf '  %s✗%s %s\n' "$red" "$reset" "$*"; }
warn() { WARN=$((WARN+1)); printf '  %s!%s %s\n' "$yellow" "$reset" "$*"; }
note() { printf '    %s%s%s\n' "$dim" "$*" "$reset"; }

BASE="https://${DOMAIN}"

# -- is it us? -------------------------------------------------------------

say "Serving this application"

# The decisive check. A box running several applications behind one proxy will
# happily answer 200 from the wrong one, so identity is tested, not liveness.
first_line="$(curl -sf --max-time 15 "${BASE}/llms.txt" 2>/dev/null | head -1 || true)"
if printf '%s' "$first_line" | grep -q "SeriouslySimpleAnalytics"; then
  pass "${BASE}/llms.txt is this application"
else
  fail "${BASE}/llms.txt is not this application"
  note "got: ${first_line:-<nothing>}"
  note "another nginx server block is matching the domain first"
fi

for path in / /dashboard /demo /wa.js; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${BASE}${path}" 2>/dev/null || echo 000)"
  case "$code" in
    200) pass "${path} -> 200" ;;
    000) fail "${path} -> no response" ;;
    *)   fail "${path} -> ${code}" ;;
  esac
done

# -- TLS -------------------------------------------------------------------

say "TLS"

if curl -sf --max-time 15 -o /dev/null "$BASE/" 2>/dev/null; then
  pass "certificate is valid"
else
  if curl -sfk --max-time 15 -o /dev/null "$BASE/" 2>/dev/null; then
    fail "TLS works only with verification disabled — the certificate is wrong or expired"
  else
    fail "https is not answering at all"
  fi
fi

redirect="$(curl -s -o /dev/null -w '%{redirect_url}' --max-time 15 "http://${DOMAIN}/" 2>/dev/null || true)"
case "$redirect" in
  https://${DOMAIN}/*) pass "http redirects to https on this domain" ;;
  "")                  warn "http did not redirect" ;;
  *)                   fail "http redirects to ${redirect} — wrong host" ;;
esac

# -- the websocket the dashboard depends on --------------------------------

say "LiveView websocket"

# The dashboard renders fine without this and then never updates, which reads as
# a broken application rather than a proxy missing two headers.
ws="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "${BASE}/live/websocket?vsn=2.0.0" 2>/dev/null || echo 000)"

case "$ws" in
  101) pass "websocket upgrades (101) — the dashboard will update live" ;;
  400) warn "websocket returned 400; Phoenix rejected the handshake, but the proxy forwarded it" ;;
  *)   fail "websocket returned ${ws} — the proxy is not forwarding Upgrade headers"
       note "nginx needs proxy_http_version 1.1 and the Upgrade/Connection headers" ;;
esac

# -- the API ---------------------------------------------------------------

say "Ping API"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  "${BASE}/api/ping?uid=verify-probe&event=deploy_check" 2>/dev/null || echo 000)"
[ "$code" = "204" ] && pass "/api/ping -> 204" || fail "/api/ping -> ${code} (expected 204)"

# -- what the integration guide tells people -------------------------------

say "Published URLs"

# PHX_HOST feeds these. Wrong, and every AI tool that reads llms.txt is told to
# send its events somewhere other than here.
bad="$(curl -sf --max-time 15 "${BASE}/llms.txt" 2>/dev/null | grep -cE 'https?://(localhost|example\.com)' || true)"
if [ "${bad:-0}" -eq 0 ]; then
  pass "llms.txt publishes ${DOMAIN}, not localhost"
else
  fail "llms.txt still publishes localhost or example.com in ${bad} place(s)"
  note "set PHX_HOST, PHX_SCHEME and PHX_PORT in .env, then restart the service"
fi

# -- survives a reboot -----------------------------------------------------

if command -v systemctl >/dev/null 2>&1; then
  say "Service"

  if systemctl is-active --quiet seriouslysimpleanalytics 2>/dev/null; then
    pass "service is running"
  else
    fail "service is not running"
  fi

  if systemctl is-enabled --quiet seriouslysimpleanalytics 2>/dev/null; then
    pass "service is enabled — it comes back after a reboot"
  else
    warn "service is not enabled; it will not start after a reboot"
    note "systemctl enable seriouslysimpleanalytics"
  fi
fi

# -- the other sites on this box -------------------------------------------

if [ -d /etc/nginx/sites-enabled ]; then
  say "Other sites on this box"

  others="$(grep -rhoE '^\s*server_name\s+[^;]+;' /etc/nginx/sites-enabled/ 2>/dev/null \
    | sed -E 's/^\s*server_name\s+//; s/;$//' | tr ' ' '\n' \
    | grep -vE "^(_|\\\$|${DOMAIN}|www\.${DOMAIN})$" | grep -E '\.' | sort -u || true)"

  if [ -z "$others" ]; then
    note "no other domains configured"
  else
    while IFS= read -r host; do
      [ -z "$host" ] && continue
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${host}/" 2>/dev/null || echo 000)"
      case "$code" in
        000) warn "${host} -> no response" ;;
        5*)  fail "${host} -> ${code}" ;;
        *)   pass "${host} -> ${code}" ;;
      esac
    done <<< "$others"
  fi
fi

# -- summary ---------------------------------------------------------------

printf '\n'
if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  printf '%sAll %d checks passed.%s\n\n' "$green$bold" "$PASS" "$reset"
elif [ "$FAIL" -eq 0 ]; then
  printf '%s%d passed, %d warning(s).%s\n\n' "$yellow$bold" "$PASS" "$WARN" "$reset"
else
  printf '%s%d passed, %d failed, %d warning(s).%s\n\n' "$red$bold" "$PASS" "$FAIL" "$WARN" "$reset"
  exit 1
fi
