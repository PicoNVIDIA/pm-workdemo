# gogcli-skill

NemoClaw skill that gives a sandboxed agent read-only access to Google Workspace (Gmail, Calendar, Drive) via the `gog` CLI.

## How it works

OAuth2 refresh tokens stay on the host inside a lightweight token server (`gog-token-server.py`). The sandbox gets a thin `gog` wrapper that fetches a short-lived access token from the host on each call — the sandbox never sees the refresh token.

```
sandbox (gog wrapper) ──GET /token──> host token server ──OAuth2──> Google APIs
```

## Files

| File | Purpose |
|---|---|
| `bootstrap.sh` | First-time setup: store credentials, run OAuth consent flow, start token server, push gogcli into sandbox, apply network policy |
| `setup.sh` | Re-deploy only: restart token server + re-upload sandbox config (skips OAuth consent) |
| `gog-token-server.py` | Host-side HTTP server — serves `GET /token` (fresh access token) and `GET /health` |
| `policy.yaml` | NemoClaw network policy — restricts sandbox egress to Google APIs (read-only) |
| `SKILL.md` | In-sandbox skill card loaded by the OpenClaw agent |

## Quick start

### 1. First-time setup (bootstrap)

```bash
export GOG_KEYRING_PASSWORD=<choose-a-password>

./gogcli-skill/bootstrap.sh \
  --credentials ~/Downloads/client_secret.json \
  --email you@gmail.com \
  --sandbox email
```

This will open a browser for the OAuth consent flow. After granting access, the token server starts and gogcli is pushed into the sandbox.

### 2. Re-deploy (after a reboot or sandbox reset)

```bash
export GOG_KEYRING_PASSWORD=<same-password>
GOG_KEYRING_PASSWORD=$GOG_KEYRING_PASSWORD ./gogcli-skill/setup.sh email
```

### 3. Verify

```bash
# Check the token server is running
curl -sf http://localhost:9100/health

# Connect to the sandbox and test
openshell sandbox connect email
/sandbox/.config/gogcli/gog gmail list -a you@gmail.com
```

## Network policy

All three Google services are currently **read-only** (GET only). Write methods are commented out in `policy.yaml` and can be re-enabled per service if needed.

| Service | Endpoint | Allowed |
|---|---|---|
| Gmail | `gmail.googleapis.com` | GET |
| Calendar | `calendar.googleapis.com` | GET |
| Drive | `drive.googleapis.com` | GET |
| Drive downloads | `www.googleapis.com` | GET |
| Token server | `<host-ip>:9100` | GET `/token`, GET `/health` |

## Prerequisites

- `gog` binary built from the [gogcli](../../../gogcli) repo (`cd ~/demo/gogcli && make`)
- GCP OAuth client credentials JSON (see below)
- `openshell` and `openclaw` CLIs available on the host
- Python 3 (for the token server)

### Getting the GCP OAuth credentials JSON

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and select (or create) a project.
2. **Enable APIs:** Navigate to **APIs & Services > Library** and enable:
   - Gmail API
   - Google Calendar API
   - Google Drive API
3. **Configure the consent screen:** Go to **APIs & Services > OAuth consent screen**.
   - Choose **External** (or Internal if using Google Workspace).
   - Fill in app name and support email, then save.
   - Under **Scopes**, add the read-only scopes you need (e.g. `gmail.readonly`, `calendar.readonly`, `drive.readonly`).
   - Add your Gmail address as a **Test user**.
4. **Create credentials:** Go to **APIs & Services > Credentials > Create Credentials > OAuth client ID**.
   - Application type: **Desktop app**.
   - Give it a name and click **Create**.
5. **Download the JSON:** Click the download icon next to the new client ID. Save the file (e.g. `~/Downloads/client_secret.json`) — this is the `--credentials` argument for `bootstrap.sh`.

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `GOG_KEYRING_PASSWORD` | Yes | — | Encrypts the local token file |
| `GOG_ACCOUNT` | No | first account in keyring | Gmail address for the token server |
| `GOG_TOKEN_SERVER_PORT` | No | `9100` | Token server port |
