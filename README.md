# portainer-docker-watchdog

Host-side healthcheck script that leverages Docker Health and Portainer webhooks to keep containers running and healthy.

---

## Overview

`portainer-docker-watchdog` is a bash-based healthcheck script designed to run on the Docker host via cron. It performs a series of escalating checks against a target container, attempting to self-heal via `docker restart` before falling back to a full stack redeployment via a Portainer webhook. Discord notifications are sent at each failure stage with built-in throttling to prevent alert spam.

---

## Features

- **4-stage health checking** — container existence, running state, Docker healthcheck status, and a functional app test
- **Automatic self-healing** — restarts the container on failure
- **Portainer webhook fallback** — triggers a full stack redeployment if `docker restart` fails
- **Discord notifications** — alerts you at each failure stage with per-status hourly throttling
- **Flexible functional test** — configure any `curl`, `dig`, `docker exec`, or other shell command as the app-level health check
- **Automatic log trimming** — keeps the log file capped at 1000 lines (Configurable)

---

## How It Works

Checks are run in order and exit early on failure — each check only runs if the previous one passed.

| Step | Check | Action on Failure |
|------|-------|-------------------|
| 1 | Container exists | Trigger Portainer webhook |
| 2 | Container is running | `docker restart` → fallback to Portainer webhook |
| 3 | Docker healthcheck status | `docker restart` → fallback to Portainer webhook |
| 4 | Functional app test | `docker restart` → fallback to Portainer webhook |

---

## Requirements

- Docker running on the host
- [Portainer](https://www.portainer.io/) with a stack webhook configured for the target container
- A Discord webhook URL for notifications
- `curl` available on the host
- Cron or similar scheduler to run the script on an interval

---

## Configuration

All configuration is at the top of the script:
```bash
# The name of the Docker container to monitor
CONTAINER_NAME="sonarr"

# Command to functionally test the container's application
# Can be any shell command — curl, dig, docker exec, etc.
HC_COMMAND="curl --silent --retry 10 --max-time 10 --retry-delay 10 \
  --retry-max-time 10 --connect-timeout 10 --retry-connrefused \
  http://localhost:8989"

# Portainer stack webhook URL
PORTAINER_WEBHOOK_URL="http://your-portainer-host:9000/api/stacks/webhooks/your-webhook-id"

# Discord webhook URL
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/your-webhook-id"

# How often to re-notify about the same failure status (default: 1 hour)
NOTIFY_INTERVAL=$((60 * 60))
```

---

## HC_COMMAND Examples

The functional test is fully customizable. Some examples:

**Web GUI (curl):**
```bash
HC_COMMAND="curl --silent --retry 3 --max-time 10 --connect-timeout 10 \
  --retry-connrefused http://localhost:8989"
```

**DNS resolution (Pi-hole):**
```bash
HC_COMMAND="docker exec pihole dig +short +time=5 +tries=3 @127.0.0.1 pi.hole"
```

**VPN tunnel endpoint ping (WireGuard):**
```bash
HC_COMMAND='docker exec wireguard-client sh -c '"'"'ping -c 1 \
  $(grep -m1 "Endpoint" /config/wg_confs/wg0.conf \
  | cut -d"=" -f2 | cut -d":" -f1 | tr -d " ")'"'"''
```

---

## Setup

1. Copy the script to your host, e.g. `/root/healthchecks/sonarr-check.sh`
2. Set your configuration values at the top of the script
3. Make it executable:
```bash
   chmod +x /root/healthchecks/sonarr-check.sh
```
4. Add a cron entry to run it on an interval:
```bash
   crontab -e
```
```cron
   * * * * * /root/healthchecks/sonarr-check.sh
```

---

## Log Output

Logs are written to `/root/healthchecks/<container-name>-check.log` and automatically trimmed to the last 100 lines on each run.

Example output:
```
[2026-03-16 15:54:23] INFO: sonarr container is healthy and responding.
[2026-03-16 15:55:31] WARNING: Container 'sonarr' is not running. Restarting...
[2026-03-16 15:55:31] INFO: Sending Discord notification for 'not_running'...
[2026-03-16 15:55:31] INFO: Attempting docker restart for 'sonarr'...
[2026-03-16 15:55:34] INFO: docker restart succeeded for 'sonarr'.
```

---

## Discord Notifications

Notifications are sent for the following events:

| Status Key | Trigger |
|------------|---------|
| `missing_container` | Container does not exist |
| `not_running` | Container is stopped |
| `unhealthy` | Docker healthcheck reports unhealthy |
| `functional_test_failed` | Functional app test failed |
| `*_restart_failed` | `docker restart` failed, webhook triggered |
| `webhook_failed` | Portainer webhook call failed |

Each status key is throttled independently — a `not_running` notification won't suppress an `unhealthy` one.

---

## License

MIT
