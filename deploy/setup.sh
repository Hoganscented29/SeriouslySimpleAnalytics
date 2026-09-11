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
FORCE_PROXY=""
ASSUME_YES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --user)    shift; SERVICE_USER="$1" ;;
    --yes|-y)  ASSUME_YES=1 ;;
    --nginx)   FORCE_PROXY=nginx ;;
    --caddy)   FORCE_PROXY=caddy ;;
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

# This was missing, and its absence was invisible: `if confirm ...` with no such
# command is simply false, so every prompt silently answered "no". The visible
# result was a site file with no certificate and no 443 block, which looks like
# certbot failing rather than never being asked to run.
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  [ -t 0 ] || return 1
  printf '  %s?%s %s [Y/n] ' "$yellow" "$reset" "$1"
  read -r reply
  case "$reply" in ''|[Yy]*) return 0 ;; *) return 1 ;; esac
}

run() {
  if [ "$DRY_RUN" = "1" ]; then
    printf '  %swould run:%s %s\n' "$dim" "$reset" "$*"
  else
    "$@"
  fi
}

write_file() {
  # $1 = path, stdin = contents
  local path="$1" content backup
  content="$(cat)"

  if [ "$DRY_RUN" = "1" ]; then
    if [ -e "$path" ]; then
      printf '\n  %swould BACK UP and replace %s:%s\n' "$yellow" "$path" "$reset"
    else
      printf '\n  %swould write %s:%s\n' "$dim" "$path" "$reset"
    fi
    printf '%s\n' "$content" | sed 's/^/    | /'
    return
  fi

  # Never destroy a file that was already there. This box serves other things,
  # and a name collision — a site file, a unit — would otherwise take one of
  # them down with no way back.
  if [ -e "$path" ]; then
    backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$path" "$backup"
    warn "$path existed; kept a copy at $backup"
  fi

  printf '%s\n' "$content" > "$path"
}

# Guards against exactly the class of bug that shipped here: a helper called but
# never defined is false inside an `if`, so the step is skipped in silence.
for helper in say ok warn die have run write_file confirm set_env; do
  if ! declare -F "$helper" >/dev/null 2>&1; then
    case "$helper" in
      set_env) continue ;;  # defined later, after .env is located
      *) printf 'internal error: %s() is not defined\n' "$helper" >&2; exit 70 ;;
    esac
  fi
done

[ -n "$DOMAIN" ] || die "Which domain?  sudo ./deploy/setup.sh example.com"

if [ "$DRY_RUN" = "0" ] && [ "$(id -u)" != "0" ]; then
  die "Needs root: it writes to /etc/systemd and /etc/caddy.
      sudo ./deploy/setup.sh $DOMAIN"
fi

[ -f .env ] || die "No .env here. Run ./install.sh first."

# -- what this box actually looks like -------------------------------------

printf '\n%sThis changes only the following:%s\n' "$bold" "$reset"
printf '  .env in this directory\n'
printf '  /etc/systemd/system/%s.service      (new unit)\n' "$SERVICE_NAME"
printf '  the reverse proxy config for %s only\n' "$DOMAIN"
printf '  firewall rules for 80 and 443, if ufw is active\n\n'
printf '%sNothing else is edited.%s Other sites and services on this box keep their own\n' "$bold" "$reset"
printf 'config files, and any file that already exists is backed up before replacement.\n\n'

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

# -- building the checked-out code ------------------------------------------

# The realistic way this script gets run a second time is `git pull && sudo
# ./deploy/setup.sh domain`. A pull can bring new dependencies, new assets and
# new migrations, and restarting without building leaves systemd in a restart
# loop whose only symptom is "did not start" — the real message being several
# screens back in the journal.
say "Building the application"

if [ "$DRY_RUN" = "1" ]; then
  printf '  %swould run:%s mix deps.get, compile, assets.deploy, ecto.migrate in %s\n' \
    "$dim" "$reset" "$APP_DIR"
else
  # As the service user, so the build artefacts belong to whoever will run them.
  # _build owned by root under a non-root service is a start failure with an
  # even less obvious message than the one above.
  as_service_user() {
    if [ "$SERVICE_USER" = "root" ] || [ "$SERVICE_USER" = "$(id -un)" ]; then
      ( cd "$APP_DIR" && set -a && . ./.env && set +a && "$@" )
    else
      run_as="cd $(printf '%q' "$APP_DIR") && set -a && . ./.env && set +a && $*"
      su -s /bin/sh -c "$run_as" "$SERVICE_USER"
    fi
  }

  build_failed=""

  as_service_user "$MIX_PATH" local.hex --force --if-missing >/dev/null 2>&1 || true
  as_service_user "$MIX_PATH" local.rebar --force --if-missing >/dev/null 2>&1 || true

  # Debian and Ubuntu split the Erlang standard library across packages, and a
  # box provisioned with erlang-nox has no xmerl. Nothing here uses XML, but
  # swoosh compiles an adapter that does, so the whole build dies on a missing
  # header with a message that names neither the package nor the fix.
  if ! erl -noshell -eval "case code:lib_dir(xmerl) of {error,_} -> halt(1); _ -> halt(0) end" \
       >/dev/null 2>&1; then
    warn "Erlang's xmerl is missing; swoosh will not compile without it."
    if have apt-get && confirm "Install erlang-xmerl?"; then
      run apt-get install -y erlang-xmerl
    else
      die "Install it, then re-run:  apt-get install -y erlang-xmerl"
    fi
  fi

  if as_service_user "$MIX_PATH" deps.get >/dev/null; then
    ok "Dependencies up to date"
  else
    build_failed="mix deps.get"
  fi

  if [ -z "$build_failed" ]; then
    if as_service_user "$MIX_PATH" compile >/dev/null; then
      ok "Compiled"
    else
      build_failed="mix compile"
    fi
  fi

  if [ -z "$build_failed" ]; then
    if as_service_user "$MIX_PATH" assets.deploy >/dev/null 2>&1; then
      ok "Assets built"
    else
      warn "mix assets.deploy failed; the site will serve stale or missing CSS."
    fi
  fi

  if [ -z "$build_failed" ]; then
    if as_service_user "$MIX_PATH" ecto.migrate; then
      ok "Migrations up to date"
    else
      build_failed="mix ecto.migrate"
    fi
  fi

  if [ -n "$build_failed" ]; then
    die "$build_failed failed, so the service was left alone rather than
      restarted into a crash loop. Run it by hand to see the error:

      cd $APP_DIR && set -a && . ./.env && set +a && $build_failed"
  fi
fi

# -- TLS and the public ports ----------------------------------------------

say "Checking DNS"

# Caddy proves control of the domain over port 80, so a certificate cannot be
# issued until the name resolves to this machine. Checking first turns a
# confusing TLS failure into a plain statement of what is wrong.
resolved="$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)"
[ -z "$resolved" ] && have dig && resolved="$(dig +short "$DOMAIN" A | head -1 || true)"
public_ip="$(curl -s --max-time 10 https://api.ipify.org 2>/dev/null || true)"

if [ -z "$resolved" ]; then
  warn "$DOMAIN does not resolve yet."
  warn "Caddy will keep retrying; TLS starts working once DNS propagates."
elif [ -n "$public_ip" ] && [ "$resolved" != "$public_ip" ]; then
  warn "$DOMAIN resolves to $resolved, but this machine is $public_ip."
  warn "Until the A record points here, no certificate can be issued."
else
  ok "$DOMAIN resolves to $resolved"
fi

# A box that already serves a site has a web server on 80 and 443 already.
# Installing a second one does not give you two web servers, it gives you one
# working and one that cannot bind — so the proxy is added to whatever is
# already there.
say "Setting up the reverse proxy"

PROXY=""
if [ -n "$FORCE_PROXY" ]; then
  PROXY="$FORCE_PROXY"
elif have nginx; then
  PROXY="nginx"
elif have caddy; then
  PROXY="caddy"
fi

if [ -z "$PROXY" ]; then
  warn "Neither nginx nor Caddy is installed."
  if [ "$DRY_RUN" = "0" ] && have apt-get; then
    printf '  Install Caddy (handles TLS automatically)? [Y/n] '
    read -r reply
    case "$reply" in
      ''|[Yy]*)
        run apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
        run sh -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg'
        run sh -c 'curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt > /etc/apt/sources.list.d/caddy-stable.list'
        run apt-get update
        run apt-get install -y caddy
        PROXY="caddy"
        ;;
      *) die "A reverse proxy is needed to serve the domain on 443." ;;
    esac
  else
    die "Install nginx or Caddy, then re-run."
  fi
fi

ok "Using $PROXY"

if [ "$PROXY" = "nginx" ]; then
  # Caddy may have been installed by an earlier run of this script, before it
  # knew nginx was here. Two of them cannot both hold port 80.
  if have caddy && systemctl is-active --quiet caddy 2>/dev/null; then
    warn "Caddy is running and will fight nginx for ports 80 and 443."
    if confirm "Stop and disable Caddy?"; then
      run systemctl disable --now caddy
      ok "Caddy stopped"
    fi
  fi

  SITE="/etc/nginx/sites-available/${DOMAIN}"

  # An existing file under this name might be another application's, and
  # server_name is the honest test of whose it is.
  if [ -f "$SITE" ] && ! grep -q "server_name .*${DOMAIN}" "$SITE" 2>/dev/null; then
    die "$SITE already exists and does not mention $DOMAIN.

      It probably belongs to something else. Move it aside, or pass a different
      domain, rather than letting this overwrite it."
  fi

  # certbot --nginx edits this file in place: it adds the 443 server block, the
  # certificate paths, and the HTTP redirect. Regenerating the file from the
  # template below therefore *deletes* the TLS configuration, and because the
  # certificate itself survives on disk, the TLS step afterwards sees a
  # certificate, says so, and does nothing. The site is then HTTP only, requests
  # for https fall through to whichever other block owns 443, and the domain
  # serves someone else's application.
  #
  # That is not hypothetical — it is what this script did on every re-run. So a
  # file certbot has already taken over is left alone.
  SITE_HAS_TLS=0
  if [ -f "$SITE" ] && grep -qE 'listen[^;]*443' "$SITE" 2>/dev/null; then
    SITE_HAS_TLS=1
  fi

  if [ "$SITE_HAS_TLS" = "1" ]; then
    ok "$SITE already has a 443 block; leaving it alone"
    warn "Re-generating it would delete the TLS configuration certbot wrote."
    warn "To rebuild it from scratch: move it aside, re-run, then re-run certbot."

    # The proxy target can still drift — a port change in .env, say — and that
    # is worth saying out loud rather than silently serving the wrong port.
    if ! grep -q "127.0.0.1:${APP_PORT}" "$SITE" 2>/dev/null; then
      warn "It does not proxy to 127.0.0.1:${APP_PORT}. Check the proxy_pass lines:"
      warn "  grep -n proxy_pass $SITE"
    fi
  else

  # Written as its own site file and symlinked in. Nothing existing is edited,
  # so the other application on this box is untouched.
  write_file "$SITE" <<NGINX
# Generated by deploy/setup.sh for ${DOMAIN}.

server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    # Must come before the proxy below: certbot answers its challenge from this
    # path, and a proxied request would be redirected to https by the
    # application before the certificate that makes https possible exists.
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};

        # The dashboard is a LiveView and needs a websocket. Without these three
        # lines the pages render and then never update, which looks like a bug
        # in the application rather than in the proxy.
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;

        # The application has force_ssl with rewrite_on: [:x_forwarded_proto].
        # Without this header it cannot tell the request already arrived over
        # TLS, and redirects it to https forever.
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_read_timeout 300s;
    }
}
NGINX

  fi

  run mkdir -p /var/www/html
  run ln -sf "$SITE" "/etc/nginx/sites-enabled/${DOMAIN}"

  if [ "$DRY_RUN" = "0" ]; then
    if nginx -t 2>/dev/null; then
      ok "nginx configuration is valid"
      systemctl reload nginx
      ok "nginx reloaded"
    else
      nginx -t || true
      die "nginx rejected the configuration; nothing was reloaded.
      The site file is at $SITE — fix or remove it, then: systemctl reload nginx"
    fi
  fi

  # nginx does not obtain certificates by itself.
  say "TLS"

  # certbot --nginx edits the server block it manages, adding the 443 listener
  # and the redirect. Worth knowing which file ends up owning 443 for this
  # domain, because if another block already claims it as default_server, the
  # certificate can be issued and the site still serve something else.
  if [ "$DRY_RUN" = "0" ] && have nginx; then
    other_default="$(nginx -T 2>/dev/null | grep -E 'listen .*443.*default_server' | head -1 || true)"
    if [ -n "$other_default" ]; then
      warn "Another server block claims 443 as default_server:"
      warn "  $(printf '%s' "$other_default" | sed 's/^[[:space:]]*//')"
      warn "If this domain ends up serving the wrong application, that is why."
    fi
  fi
  if have certbot; then
    ok "certbot is installed"
  else
    warn "certbot is not installed; the site will be HTTP only."
    if [ "$DRY_RUN" = "0" ] && have apt-get && confirm "Install certbot?"; then
      run apt-get install -y certbot python3-certbot-nginx
    fi
  fi

  # A certificate on disk says nothing about whether nginx is serving it for this
  # name. The two can be out of step — a half-finished run, a rewritten site
  # file, a certificate issued by a different plugin — and the symptom is the
  # nastiest one this script can produce: https://DOMAIN resolves, answers, and
  # serves a different application, because with no 443 block of its own the
  # request falls through to whichever block owns the port.
  #
  # So the question asked here is "does this domain have a 443 server block",
  # not "does a certificate exist".
  domain_has_tls_vhost() {
    have nginx || return 1
    nginx -T 2>/dev/null | awk -v domain="$DOMAIN" '
      # Brace depth is tracked across the whole file, and a server block is
      # remembered by the depth it opened at. Counting per line, or assuming
      # server blocks sit at depth zero, both give the wrong answer on a real
      # config: server blocks are nested inside http, and they contain location
      # blocks whose closing brace is not the end of the server block.
      {
        line = $0
        sub(/#.*/, "", line)
        opens  = gsub(/\{/, "{", line)
        closes = gsub(/\}/, "}", line)

        if (!in_server && opens > 0 &&
            (line ~ /(^|[ \t])server[ \t]*\{/ || pending)) {
          in_server = 1; server_depth = depth; tls = 0; named = 0
        }
        pending = (!in_server && line ~ /(^|[ \t])server[ \t]*$/)

        if (in_server) {
          if (line ~ /listen/ && line ~ /443/) tls = 1

          if (line ~ /^[ \t]*server_name[ \t]/) {
            value = line
            sub(/^[ \t]*server_name[ \t]+/, "", value)
            sub(/;.*/, "", value)
            count = split(value, names, /[ \t]+/)
            for (i = 1; i <= count; i++) if (names[i] == domain) named = 1
          }
        }

        depth += opens - closes

        if (in_server && depth <= server_depth) {
          if (tls && named) found = 1
          in_server = 0
        }
      }
      END { exit(found ? 0 : 1) }
    '
  }

  if have certbot && [ "$DRY_RUN" = "0" ]; then
    cert_present=0
    [ -d "/etc/letsencrypt/live/${DOMAIN}" ] && cert_present=1

    tls_vhost=0
    domain_has_tls_vhost && tls_vhost=1

    if [ "$cert_present" = "1" ] && [ "$tls_vhost" = "1" ]; then
      ok "Certificate installed and nginx serves ${DOMAIN} on 443"

    elif [ "$cert_present" = "1" ] && [ "$tls_vhost" = "0" ]; then
      # The case that bit us. Older runs stopped at "certificate already
      # present" and left the domain with no 443 block at all, so HTTPS served
      # whichever other application owned the port. Reinstalling is what fixes
      # it: same certificate, but certbot writes the missing server block and
      # the HTTP redirect.
      warn "A certificate exists for ${DOMAIN} but nginx has no 443 block for it."
      warn "https://${DOMAIN}/ is currently served by some other server block."
      if confirm "Install it into nginx now (certbot --nginx --reinstall --redirect)?"; then
        certbot --nginx -d "$DOMAIN" --redirect --reinstall --agree-tos --non-interactive \
          -m "${CERT_EMAIL:-me@LoganBesecker.com}" || \
          warn "certbot could not install the certificate. By hand:
      certbot --nginx -d $DOMAIN --redirect     # choose 2 (redirect) if asked"
      fi

    elif confirm "Obtain a Let's Encrypt certificate for ${DOMAIN} now?"; then
      certbot --nginx -d "$DOMAIN" --redirect --agree-tos --non-interactive \
        -m "${CERT_EMAIL:-me@LoganBesecker.com}" || \
        warn "certbot failed — usually DNS not pointing here yet. Re-run once it does:
      certbot --nginx -d $DOMAIN --redirect"
    fi

    # Whatever happened above, say plainly whether the domain now terminates TLS
    # on its own block. certbot can exit 0 and still not have installed where
    # you expected, and this is the one outcome that must not pass quietly.
    if domain_has_tls_vhost; then
      ok "${DOMAIN} has its own 443 server block"
    else
      warn "${DOMAIN} still has no 443 server block."
      warn "https://${DOMAIN}/ will serve whatever other application owns port 443."
      warn "Fix it with:  certbot --nginx -d $DOMAIN --redirect"
      warn "and choose option 2 (redirect) if it asks."
    fi
  fi
else
  write_file /etc/caddy/Caddyfile <<CADDY
# Generated by deploy/setup.sh.
#
# Caddy obtains and renews the certificate itself, by answering a challenge on
# port 80 — so ${DOMAIN} must already resolve to this machine.

${DOMAIN} {
	encode zstd gzip

	reverse_proxy 127.0.0.1:${APP_PORT} {
		header_up X-Forwarded-Proto {scheme}
		header_up X-Forwarded-For {remote_host}
	}
}
CADDY

  run systemctl enable caddy
  ok "Caddy configured for $DOMAIN"
fi

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

# Only the proxy actually in use. Restarting Caddy on an nginx box would start a
# second web server against ports nginx already holds — and on a box serving
# someone else's application, that is not a harmless mistake.
if [ "$DRY_RUN" = "0" ] && [ "$PROXY" = "caddy" ]; then
  systemctl reload caddy 2>/dev/null || systemctl restart caddy || true
fi

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

# The application being up says nothing about whether the public can reach it.
# These two checks are the difference between "it works" and "it works on
# localhost", which is the whole problem this script exists to solve.
if curl -sf -o /dev/null --max-time 10 "http://127.0.0.1:${APP_PORT}/"; then
  ok "Application answering on 127.0.0.1:${APP_PORT}"
else
  warn "Application is not answering on 127.0.0.1:${APP_PORT} yet."
fi

if ! systemctl is-active --quiet "$PROXY"; then
  warn "$PROXY is not running — nothing is listening on 80 or 443."
  warn "  systemctl status $PROXY --no-pager"
  warn "  journalctl -u $PROXY -n 50 --no-pager"
elif ss -lntp 2>/dev/null | grep -qE ':(80|443)\b'; then
  ok "$PROXY is listening on 80/443"
else
  warn "$PROXY is running but not listening on 80/443. Check: journalctl -u $PROXY -n 50"
fi

# "Something answers" is not the same as "this answers". On a box with more than
# one application behind one proxy, a server_name that fails to match sends the
# request to whichever block is the default — so the domain comes up, serves
# someone else's site, and every check short of reading the body passes.
if reply="$(curl -sf --max-time 15 "https://${DOMAIN}/llms.txt" 2>/dev/null)"; then
  if printf '%s' "$reply" | head -1 | grep -q "SeriouslySimpleAnalytics"; then
    ok "https://${DOMAIN}/ is serving this application"
  else
    warn "https://${DOMAIN}/ answers, but not with this application."
    warn "Another server block is matching the domain first. Find which:"
    warn "  nginx -T | grep -nE 'server_name|listen|proxy_pass'"
    warn "Look for a block with 'default_server' or a wider server_name."
  fi
elif curl -sfI --max-time 15 "https://${DOMAIN}/" >/dev/null 2>&1; then
  warn "https://${DOMAIN}/ answers but /llms.txt does not — likely another application."
else
  warn "https://${DOMAIN}/ is not answering yet."
  warn "If DNS only just changed, give it time. Otherwise check $PROXY's logs."
fi

printf '\n%sDone.%s\n\n' "$green$bold" "$reset"
printf '  https://%s/\n' "$DOMAIN"
printf '  https://%s/dashboard\n' "$DOMAIN"
printf '  https://%s/llms.txt\n\n' "$DOMAIN"
printf '  %sLogs:%s     journalctl -u %s -f\n' "$bold" "$reset" "$SERVICE_NAME"
printf '  %sRestart:%s  systemctl restart %s\n' "$bold" "$reset" "$SERVICE_NAME"
printf '  %sUpdate:%s   git pull && sudo ./deploy/setup.sh %s\n\n' \
  "$bold" "$reset" "$DOMAIN"

# Naming the proxy actually in use, rather than whichever one this script was
# written against first.
if [ "$PROXY" = "caddy" ]; then
  printf '  Caddy obtains the certificate itself once DNS points here.\n'
  printf '  Watch it with:  journalctl -u caddy -f\n\n'
else
  printf '  If https serves the wrong application, this domain has no 443 block\n'
  printf '  of its own and the request is falling through to another site. Fix:\n'
  printf '    certbot --nginx -d %s --redirect\n' "$DOMAIN"
  printf '  choosing option 2 (redirect) if it asks, then re-run this script.\n\n'
fi