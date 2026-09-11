#!/usr/bin/env bash
#
# Install and launch SeriouslySimpleAnalytics.
#
#   ./install.sh                  # set up and start on port 4001
#   ./install.sh --dev            # development mode (code reloading)
#   ./install.sh --no-start       # set up, but do not launch
#   ./install.sh --yes            # never prompt; assume yes
#   ./install.sh --no-geoip       # skip the ~120MB city database
#   PORT=4005 ./install.sh        # somewhere other than 4001
#
# Safe to re-run: every step checks before it acts, and secrets already written
# are reused rather than regenerated.

set -euo pipefail
cd "$(dirname "$0")"

# The box this is built for already runs another Phoenix app, so nothing here
# may assume the usual 4000.
PORT="${PORT:-4001}"
MIX_ENV="${MIX_ENV:-prod}"
ASSUME_YES=0
START=1
WANT_GEOIP=1
ENV_FILE=".env"

while [ $# -gt 0 ]; do
  case "$1" in
    --dev)       MIX_ENV=dev ;;
    --prod)      MIX_ENV=prod ;;
    --yes|-y)    ASSUME_YES=1 ;;
    --no-start)  START=0 ;;
    --no-geoip)  WANT_GEOIP=0 ;;
    --port)      shift; PORT="$1" ;;
    -h|--help)   sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

export MIX_ENV PORT

bold=$(tput bold 2>/dev/null || true); dim=$(tput dim 2>/dev/null || true)
red=$(tput setaf 1 2>/dev/null || true); green=$(tput setaf 2 2>/dev/null || true)
yellow=$(tput setaf 3 2>/dev/null || true); cyan=$(tput setaf 6 2>/dev/null || true)
reset=$(tput sgr0 2>/dev/null || true)

say()  { printf '%s==>%s %s\n' "$cyan$bold" "$reset" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '  %s!%s %s\n' "$yellow" "$reset" "$*"; }
die()  { printf '%serror%s %s\n' "$red$bold" "$reset" "$*" >&2; exit 1; }

# Prompts default to yes, but only when someone is actually there to answer.
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  [ -t 0 ] || return 1
  printf '  %s?%s %s [Y/n] ' "$yellow" "$reset" "$1"
  read -r reply
  case "$reply" in ''|[Yy]*) return 0 ;; *) return 1 ;; esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# -- 1. prerequisites ------------------------------------------------------

say "Checking prerequisites"

if have brew; then
  INSTALLER="brew install"
elif have apt-get; then
  INSTALLER="sudo apt-get install -y"
elif have dnf; then
  INSTALLER="sudo dnf install -y"
else
  INSTALLER=""
fi

# Installing system packages is not something to do behind someone's back, so
# it is always offered rather than assumed.
require() {
  local cmd="$1" package="$2" label="$3"

  if have "$cmd"; then
    ok "$label"
    return 0
  fi

  if [ -z "$INSTALLER" ]; then
    die "$label is not installed, and no supported package manager was found.
      Install it and re-run this script."
  fi

  warn "$label is not installed."
  if confirm "Install it with: $INSTALLER $package ?"; then
    $INSTALLER "$package"
    have "$cmd" || die "$label still is not on PATH after installing."
    ok "$label installed"
  else
    die "$label is required. Install it and re-run this script."
  fi
}

require elixir elixir "Elixir"
require psql postgresql "PostgreSQL client"

mix local.hex --force --if-missing >/dev/null
mix local.rebar --force --if-missing >/dev/null

# -- 2. database server ----------------------------------------------------

say "Checking the database"

if ! pg_isready -q 2>/dev/null; then
  warn "PostgreSQL is not accepting connections."

  if have brew && brew services list 2>/dev/null | grep -q postgres; then
    if confirm "Start it with: brew services start postgresql ?"; then
      brew services start "$(brew services list | awk '/postgres/{print $1; exit}')"
      for _ in $(seq 1 30); do pg_isready -q 2>/dev/null && break; sleep 1; done
    fi
  elif have systemctl; then
    if confirm "Start it with: sudo systemctl start postgresql ?"; then
      sudo systemctl start postgresql
      for _ in $(seq 1 30); do pg_isready -q 2>/dev/null && break; sleep 1; done
    fi
  fi

  pg_isready -q 2>/dev/null || die "PostgreSQL is still not reachable. Start it and re-run."
fi
ok "PostgreSQL is up"

# -- 3. port ---------------------------------------------------------------

# -sTCP:LISTEN matters: plain lsof also matches processes that merely hold an
# open connection to this port, and a passing client would block the install.
if have lsof && lsof -ti tcp:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  holder="$(lsof -ti tcp:"$PORT" -sTCP:LISTEN | head -1)"
  name="$(ps -p "$holder" -o comm= 2>/dev/null || echo unknown)"
  die "Port $PORT is in use by pid $holder ($name).
      Stop it, or choose another:  ./install.sh --port 4005"
fi
ok "Port $PORT is free"

# -- 4. secrets ------------------------------------------------------------

say "Preparing configuration"

DB_USER="${PGUSER:-${USER}}"
DB_HOST="${PGHOST:-localhost}"
DB_NAME="seriously_simple_analytics_${MIX_ENV}"

if [ -f "$ENV_FILE" ]; then
  ok "Reusing $ENV_FILE"
else
  # Generated once and kept. Regenerating SECRET_KEY_BASE would invalidate every
  # signed session, and regenerating IP_SALT would orphan every stored IP hash.
  secret="$(mix phx.gen.secret 2>/dev/null | tail -1)"
  salt="$(mix phx.gen.secret 2>/dev/null | tail -1)"

  auth="$DB_USER"
  [ -n "${PGPASSWORD:-}" ] && auth="$DB_USER:$PGPASSWORD"

  cat > "$ENV_FILE" <<ENV
# Written by install.sh. Secrets — never commit this file.
export MIX_ENV=$MIX_ENV
export PORT=$PORT
export SECRET_KEY_BASE=$secret
export IP_SALT=$salt
export DATABASE_URL=ecto://$auth@$DB_HOST/$DB_NAME
export PHX_HOST=localhost
# How this box is reached from outside. /llms.txt publishes absolute URLs built
# from these, so set them to the public address before pointing anyone at it.
export PHX_SCHEME=http
export PHX_PORT=$PORT
ENV
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE (secrets generated, mode 600)"
fi

# shellcheck source=/dev/null
. "./$ENV_FILE"
export MIX_ENV PORT

# -- 5. dependencies and database -----------------------------------------

say "Installing dependencies"
mix deps.get >/dev/null
ok "Dependencies installed"

say "Setting up the database"
mix ecto.create --quiet
mix ecto.migrate
ok "Database ready"

# -- 6. geolocation --------------------------------------------------------

if [ "$WANT_GEOIP" = "1" ] && [ -z "$(ls priv/geoip/*.mmdb 2>/dev/null)" ]; then
  say "Geolocation"
  warn "City-level location needs a GeoIP database (~120MB, free, no account)."
  if confirm "Download it now?"; then
    mix geoip.download || warn "Download failed; location will fall back to time zone."
  else
    warn "Skipped. Web visitors fall back to CDN headers, then a country guess."
    warn "The ping API is unaffected: callers send their own location."
  fi
fi

# -- 7. assets -------------------------------------------------------------

if [ "$MIX_ENV" = "prod" ]; then
  say "Building assets"
  mix assets.deploy >/dev/null
  ok "Assets built"
fi

# -- 8. an account to use --------------------------------------------------

say "Account"

# Filtered to the account-id charset rather than taken as the last line: any
# stray log output would otherwise be captured and pasted into the snippets
# printed below as though it were the ID.
account_id() { grep -E '^[A-Za-z0-9_-]+$' | tail -1; }

ACCOUNT="$(mix ssa.account --quiet 2>/dev/null | account_id || true)"
if [ -z "$ACCOUNT" ]; then
  ACCOUNT="$(mix ssa.account "My Site" --quiet 2>/dev/null | account_id)"
  ok "Created account $ACCOUNT"
else
  ok "Using existing account $ACCOUNT"
fi

# -- 9. go -----------------------------------------------------------------

BASE="http://localhost:$PORT"

printf '\n%sReady.%s  %s(%s)%s\n\n' "$green$bold" "$reset" "$dim" "MIX_ENV=$MIX_ENV" "$reset"
printf '  Landing    %s/\n' "$BASE"
printf '  Dashboard  %s/dashboard\n' "$BASE"
printf '  llms.txt   %s/llms.txt\n' "$BASE"
printf '  Demo site  %s/demo\n\n' "$BASE"
printf '  %sAccount ID%s  %s\n\n' "$bold" "$reset" "$ACCOUNT"
printf '  %sLog an event from anything:%s\n' "$bold" "$reset"
printf '    curl "%s/api/ping?uid=%s&type=ai&project=my-agent&event=page_view&c=Austin&cc=Travis&s_p=Texas&n=US"\n\n' "$BASE" "$ACCOUNT"
printf '  %sTrack a website:%s\n' "$bold" "$reset"
printf '    <script src="%s/wa.js" data-site="%s" defer></script>\n\n' "$BASE" "$ACCOUNT"

if [ "$START" = "0" ]; then
  printf '  Start it with:  %s. ./%s && mix phx.server%s\n\n' "$dim" "$ENV_FILE" "$reset"
  exit 0
fi

say "Starting on port $PORT — Ctrl-C twice to stop"
exec mix phx.server
