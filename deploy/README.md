# Putting it on the internet

`./install.sh` gets the application running on port 4001. It does not make a
domain resolve to it. These are the three pieces in between.

## 1. DNS

Point an `A` record (and `AAAA` if the box has IPv6) at the server's public
address. Do this first: Caddy obtains its certificate by answering a challenge
on port 80, so it cannot get one before the name resolves here.

## 2. Tell the app its own address

`deploy/setup.sh` below does this for you. By hand, edit `.env` on the server:

```
PHX_HOST=seriouslysimpleanalytics.com
PHX_SCHEME=https
PHX_PORT=443
```

**This is the step that is easy to skip and fails quietly.** Two things depend
on it:

- `force_ssl` redirects visitors to the *configured* host. Left at `localhost`,
  everyone arriving on your real domain is redirected to `https://localhost/`
  and lands nowhere. The site will look broken in a way that logs nothing
  interesting.
- `/llms.txt` publishes absolute URLs built from these values, so every AI tool
  that reads your integration contract would be told to POST its events to its
  own machine.

`PORT` stays 4001 — that is the port the app listens on locally, behind the
proxy. `PHX_PORT` is the port the *public* reaches, which is 443.

## 2 and 3, in one command

```bash
sudo ./deploy/setup.sh your-domain.com
```

It reads the machine rather than assuming it: the real path to `mix`, the user
that owns the checkout, the port from `.env`. It writes the systemd unit and the
Caddyfile, opens 80 and 443 if `ufw` is running, and starts everything.

`--dry-run` prints what it would write and changes nothing. Worth doing first.

It also strips any `export ` prefixes from `.env`. Earlier versions of
install.sh wrote them, a shell sources them happily, and systemd's
`EnvironmentFile=` does not understand them — a service reading that file would
have started with none of its configuration.

`deploy/Caddyfile` and `deploy/seriouslysimpleanalytics.service` are reference
copies of what it generates. Do not install them as-is: `User=` and `ExecStart=`
have no correct general value, and the ones that were there originally were
wrong on the first server they met.

## Checking it worked

```bash
curl -I https://seriouslysimpleanalytics.com/
curl -s https://seriouslysimpleanalytics.com/llms.txt | head -20
```

The second one is the real test. If the URLs inside it say `localhost`, step 2
did not take effect — restart the service after editing `.env`, since it is read
at boot.

Then open `/dashboard` and confirm the numbers update without a refresh. The
dashboard is a LiveView, so it needs a websocket, and a websocket that cannot
connect is the symptom of a proxy that is not forwarding upgrade headers. Caddy
does this by default; nginx needs `proxy_set_header Upgrade` and `Connection`
explicitly.
