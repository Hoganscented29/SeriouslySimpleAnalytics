#!/usr/bin/env bash
#
# Put a running install behind a domain, with TLS, and keep it running.
#
#   sudo ./deploy/setup.sh seriouslysimpleanalytics.com
#   sudo ./deploy/setup.sh example.com --dry-run    # show what it would do
#
# Assumes ./install.sh has already produced a working install on port 4001.
# This is the part that install.sh deliberately does not do: it changes things
# outside the project directory.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_DIR="$(pwd)"
SERVICE_NAME="seriouslysimpleanalytics"
DOMAIN=""
DRY_RUN=0
SERVICE_USER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --user)    shift; SERVICE_USER="$1" ;;
    -h|--help) sed -n '3,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    *)         DOMAIN="$1" ;;
  esac
  shift
done

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true); cyan=$(tput setaf 6 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

say()  { printf '%s==>%s %s\n' "$cyan$bold" "$reset" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$*"; }
die()  { printf '%serror%s %s\n' "$red$bold" "$reset" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s\n' "$dim" "$reset" "$*"
  else
    "$@"
  fi
}

write_file() {
  # $1 = path, stdin = contents
  local path="$1" content
  content="$(cat)"

  if [ "$DRY_RUN" = "1" ]; then
    printf '\n  %swould write %s:%s\n' "$dim" "$path" "$reset"
    printf '%s\n' "$content" | sed 's/^/    | /'
  else
    printf '%s\n' "$content" > "$path"
  fi
}

[ -n "$DOMAIN" ] || die "Which domain?  sudo ./deploy/setup.sh example.com"

if [ "$DRY_RUN" = "0" ] && [ "$(id -u)" != "0" ]; then
  die "Needs root: it writes to /etc/systemd and /etc/caddy.
      sudo ./deploy/setup.sh $DOMAIN"
fi

[ -f .env ] || die "No .env here. Run ./install.sh first."

# -- what this box actually looks like -------------------------------------

say "Inspecting this machine"

MIX_PATH="$(command -v mix || true)"
[ -n "$MIX_PATH" ] || die "mix is not on PATH. Install Elixir, or pass its full path."
ok "mix at $MIX_PATH"

# systemd runs with a minimal PATH and no shell profile, so a version-manager
# shim that works in your terminal will not work here.
case "$MIX_PATH" in
  *"/.asdf/"*|*"/.mise/"*|*"/.rbenv/"*)
    warn "$MIX_PATH is a version-manager shim; systemd may not resolve its runtime."
    warn "If the service fails to start, point ExecStart at the real binary."
    ;;
esac

# Default to whoever owns the checkout. Running as a different user needs that
# user to have its own hex and rebar archives and write access to _build, which
# a plain `User=` line does not arrange.
if [ -z "$SERVICE_USER" ]; then
  SERVICE_USER="$(stat -c '%U' "$APP_DIR" 2>/dev/null || stat -f '%Su' "$APP_DIR")"
fi
id "$SERVICE_USER" >/dev/null 2>&1 || die "No such user: $SERVICE_USER"

if [ "$SERVICE_USER" = "root" ]; then
  warn "Service will run as root, matching how the install was done."
  warn "To use a dedicated account later: create it, chown -R this directory,"
  warn "re-run ./install.sh as that user, then re-run this with --user NAME."
fi
ok "Service user: $SERVICE_USER"

APP_PORT="$(grep -E '^(export )?PORT=' .env | tail -1 | cut -d= -f2- || true)"
APP_PORT="${APP_PORT:-4001}"
ok "Application port: $APP_PORT"

# -- tell the application its public address -------------------------------

say "Preparing .env"

# Earlier versions of install.sh wrote `export KEY=value`. A shell sources that
# happily, so nothing complained — but systemd's EnvironmentFile= does not
# understand the keyword and would hand the service a variable literally named
# "export PHX_HOST". The service would start with none of its configuration and
# fail on the first thing it needed.
if grep -qE '^[[:space:]]*export ' .env; then
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould strip%s `export ` prefixes so systemd can read .env\n' "$dim" "$reset"
  else
    tmp="$(mktemp)"
    sed -E 's/^[[:space:]]*export //' .env > "$tmp"
    mv "$tmp" .env
    chmod 600 .env
    ok "Removed 'export ' prefixes (systemd cannot parse them)"
  fi
else
  ok ".env is already in KEY=value form"
fi

set_env() {
  local key="$1" value="$2"
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould set%s %s=%s\n' "$dim" "$reset" "$key" "$value"
    return
  fi
  # Matches an `export ` prefix too, in case normalisation was skipped.
  if grep -qE "^(export )?${key}=" .env; then
    tmp="$(mktemp)"
    sed -E "s|^(export )?${key}=.*|${key}=${value}|" .env > "$tmp"
    mv "$tmp" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
  chmod 600 .env
}

# force_ssl redirects to the *configured* host, and /llms.txt publishes absolute
# URLs built from these. Left at localhost, visitors are sent to
# https://localhost/ and integrators are told to ping their own machine.
set_env PHX_HOST "$DOMAIN"
set_env PHX_SCHEME https
set_env PHX_PORT 443
ok "PHX_HOST=$DOMAIN, https, 443"

# -- keep it running -------------------------------------------------------

say "Installing the systemd service"

write_file "/etc/systemd/system/${SERVICE_NAME}.service" <<UNIT
# Generated by deploy/setup.sh. Re-running regenerates it.
[Unit]
Description=SeriouslySimpleAnalytics
Documentation=https://github.com/lbesecker195/SeriouslySimpleAnalytics
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=exec
User=${SERVICE_USER}
WorkingDirectory=${APP_DIR}

# Plain KEY=value; systemd cannot parse a leading \`export\`, which is why
# install.sh writes the file without one.
EnvironmentFile=${APP_DIR}/.env

ExecStart=${MIX_PATH} phx.server

Restart=always
RestartSec=5

# Migrations and the ~120MB GeoIP load need room before systemd calls it a
# failed start.
TimeoutStartSec=120

# The BEAM handles SIGTERM itself and drains connections; let it.
KillSignal=SIGTERM
TimeoutStopSec=30

StandardOutput=journal
StandardError=journal
SyslogIdentifier=ssa

[Install]
WantedBy=multi-user.target
UNIT

run systemctl daemon-reload
run systemctl enable "$SERVICE_NAME"
ok "Service installed"

# -- TLS and the public ports ----------------------------------------------

say "Setting up Caddy"

if ! have caddy; then
  warn "Caddy is not installed."
  if [ "$DRY_RUN" = "0" ] && have apt-get; then
    printf '  Install it now? [Y/n] '
    read -r reply
    case "$reply" in
      ''|[Yy]*)
        run apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
        run sh -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg'
        run sh -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list'
        run apt-get update
        run apt-get install -y caddy
        ;;
      *) die "Caddy is needed for TLS. Install it and re-run." ;;
    esac
  else
    warn "Install Caddy, then re-run: apt-get install caddy"
  fi
fi

write_file /etc/caddy/Caddyfile <<CADDY
# Generated by deploy/setup.sh.
#
# Caddy obtains and renews the certificate itself. It does that by answering a
# challenge on port 80, so ${DOMAIN} must already resolve to this machine —
# a certificate cannot be issued before DNS points here.

${DOMAIN} {
	encode zstd gzip

	reverse_proxy 127.0.0.1:${APP_PORT} {
		# The application has force_ssl with rewrite_on: [:x_forwarded_proto].
		# Without this header it cannot tell that the request already arrived
		# over TLS, and redirects it to https forever.
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-For {remote_host}
	}
}
CADDY

run systemctl enable caddy
ok "Caddy configured for $DOMAIN"

# -- firewall ---------------------------------------------------------------

if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
  say "Opening the web ports"
  run ufw allow 80/tcp
  run ufw allow 443/tcp
  # 4001 stays closed: Caddy reaches it over loopback, and exposing it would
  # serve the site over plain HTTP, bypassing TLS entirely.
  ok "80 and 443 open; $APP_PORT left closed"
fi

# -- go ---------------------------------------------------------------------

say "Starting"
run systemctl restart "$SERVICE_NAME"
run systemctl reload caddy || run systemctl restart caddy

if [ "$DRY_RUN" = "1" ]; then
  printf '\n%sDry run complete.%s Nothing was changed.\n\n' "$yellow$bold" "$reset"
  exit 0
fi

sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "$SERVICE_NAME is running"
else
  die "$SERVICE_NAME did not start. See why with:
      journalctl -u $SERVICE_NAME -n 50 --no-pager"
fi

printf '\n%sDone.%s\n\n' "$green$bold" "$reset"
printf '  https://%s/\n' "$DOMAIN"
printf '  https://%s/dashboard\n' "$DOMAIN"
printf '  https://%s/llms.txt\n\n' "$DOMAIN"
printf '  %sLogs:%s     journalctl -u %s -f\n' "$bold" "$reset" "$SERVICE_NAME"
printf '  %sRestart:%s  systemctl restart %s\n\n' "$bold" "$reset" "$SERVICE_NAME"
printf '  If the certificate has not appeared yet, DNS may still be propagating.\n'
printf '  Watch it with:  journalctl -u caddy -f\n\n'
