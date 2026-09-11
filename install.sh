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

random_secret() {
  if have openssl; then
    openssl rand -base64 48 | tr -d '\n'
  elif [ -r /dev/urandom ]; then
    head -c 48 /dev/urandom | base64 | tr -d '\n'
  else
    die "No source of randomness available (needs openssl or /dev/urandom)."
  fi
}

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

# -- 4. deployment key -----------------------------------------------------

# Checked here rather than left to fail at boot, so nobody sits through a
# database setup and a 120MB download to be told at the end that they cannot
# run it.
if [ "$MIX_ENV" = "prod" ]; then
  say "Deployment key"

  KEY="${SSA_LICENSE_KEY:-}"
  [ -z "$KEY" ] && [ -f "$ENV_FILE" ] && KEY="$(set -a; . "./$ENV_FILE" >/dev/null 2>&1; set +a; printf '%s' "${SSA_LICENSE_KEY:-}")"

  if [ -z "$KEY" ]; then
    printf '\n%serror%s A deployment key is required to run in production.\n\n' "$red$bold" "$reset" >&2
    cat >&2 <<'KEYHELP'
  Set it before running this script:

      SSA_LICENSE_KEY="SSA1.…" ./install.sh

  ...or put it in .env and re-run.

  No key? Contact me@LoganBesecker.com.

  Evaluating, or working on the code? Development mode needs no key and binds
  to localhost only:

      ./install.sh --dev

  The licence terms are in LICENSE.md.
KEYHELP
    exit 1
  fi
  ok "Key present"
fi

# -- 5. dependencies -------------------------------------------------------

say "Installing dependencies"
mix local.hex --force --if-missing >/dev/null
mix local.rebar --force --if-missing >/dev/null
mix deps.get >/dev/null
ok "Dependencies installed"

# -- 6. secrets ------------------------------------------------------------

say "Preparing configuration"

DB_HOST="${PGHOST:-localhost}"
DB_NAME="seriously_simple_analytics_${MIX_ENV}"

# `$USER` is not always set, and where it is, it is not always a Postgres role:
# installing as root on a stock Ubuntu box gives a `root` login and a `postgres`
# superuser, which are not the same thing. So candidates are tried against the
# server rather than assumed, and the failure names what to do about it.
db_can_connect() {
  PGPASSWORD="${PGPASSWORD:-}" psql -h "$DB_HOST" -U "$1" -d postgres -tAc 'select 1' >/dev/null 2>&1
}

DB_USER=""
for candidate in "${PGUSER:-}" "${USER:-}" postgres; do
  [ -z "$candidate" ] && continue
  if db_can_connect "$candidate"; then DB_USER="$candidate"; break; fi
done

if [ -z "$DB_USER" ]; then
  die "Cannot connect to PostgreSQL on $DB_HOST as ${PGUSER:-}, ${USER:-} or postgres.

      Create a role this install can use, then tell the script about it:

          sudo -u postgres createuser --createdb --pwprompt ssa
          PGUSER=ssa PGPASSWORD=secret ./install.sh"
fi
ok "PostgreSQL role: $DB_USER"

if [ -f "$ENV_FILE" ]; then
  ok "Reusing $ENV_FILE"
else
  # Generated once and kept. Regenerating SECRET_KEY_BASE would invalidate every
  # signed session, and regenerating IP_SALT would orphan every stored IP hash.
  # Deliberately not `mix phx.gen.secret`: on a fresh clone the dependencies are
  # not fetched yet, so that task fails — and this step runs before them.
  # 48 random bytes is 64 base64 characters, the length Phoenix requires of
  # SECRET_KEY_BASE.
  secret="$(random_secret)"
  salt="$(random_secret)"

  auth="$DB_USER"
  [ -n "${PGPASSWORD:-}" ] && auth="$DB_USER:$PGPASSWORD"

  # No `export` prefixes: systemd's EnvironmentFile= cannot parse them, and
  # sourcing under `set -a` exports everything anyway. One file, both uses.
  cat > "$ENV_FILE" <<ENV
# Written by install.sh. Secrets — never commit this file.
MIX_ENV=$MIX_ENV
PORT=$PORT
SECRET_KEY_BASE=$secret
IP_SALT=$salt
DATABASE_URL=ecto://$auth@$DB_HOST/$DB_NAME
SSA_LICENSE_KEY=${SSA_LICENSE_KEY:-}

# How this box is reached from outside.
#
# Two things depend on these and break quietly if they are wrong: /llms.txt
# publishes absolute URLs built from them, and force_ssl redirects visitors to
# this host — so left at localhost, every visitor on your real domain is sent to
# https://localhost/ and lands nowhere.
PHX_HOST=localhost
PHX_SCHEME=http
PHX_PORT=$PORT
ENV
  chmod 600 "$ENV_FILE"
  ok "Wrote $ENV_FILE (secrets generated, mode 600)"
fi

set -a
# shellcheck source=/dev/null
. "./$ENV_FILE"
set +a
export MIX_ENV PORT

# -- 7. database -----------------------------------------------------------

say "Setting up the database"
mix ecto.create --quiet
mix ecto.migrate
ok "Database ready"

# -- 8. geolocation --------------------------------------------------------

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

# -- 9. assets -------------------------------------------------------------

if [ "$MIX_ENV" = "prod" ]; then
  say "Building assets"
  mix assets.deploy >/dev/null
  ok "Assets built"
fi

# -- 10. an account to use --------------------------------------------------

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

# -- 11. go -----------------------------------------------------------------

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
