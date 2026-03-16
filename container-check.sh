#!/bin/bash

# Container name
CONTAINER_NAME="<YOUR_CONTAINER_NAME_HERE>"

# Log file
LOG_FILE="/root/healthchecks/$CONTAINER_NAME-check.log"

# Set the Health Check Command to be used to test the WEB GUI hosted by the container or other valid test to test actual functionality
# Radarr example, this is really just any functional test that can be done from the host
# HC_COMMAND="curl --silent --retry 10 --max-time 10 --retry-delay 10 --retry-max-time 10 --connect-timeout 10 --retry-connrefused http://localhost:7878"
HC_COMMAND="<YOUR FUNCTIONAL TEST HERE>

# Portainer stack or containter webhook URL
# Example: https://your-portainer-url/api/webhooks/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
PORTAINER_WEBHOOK_URL="<Container, or Stack URL Here>"

# Discord webhook URL
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/<YOURS/HERE>"

# Status tracking file (when last notification sent per status)
LAST_SENT_FILE="/root/healthchecks/$CONTAINER_NAME.lastsent"

# How often to notify about same status (seconds)
NOTIFY_INTERVAL=$((60 * 60)) # 1 hour

# Helper log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# FUNCTION - Send a Discord notification (only once per hour per STATUS_KEY)
notify_discord() {
    local STATUS_KEY="$1"
    local MESSAGE="$2"

    mkdir -p "$(dirname "$LAST_SENT_FILE")"
    touch "$LAST_SENT_FILE"

    local LAST_SENT=0

    if grep -q "^${STATUS_KEY}:" "$LAST_SENT_FILE"; then
        LAST_SENT=$(grep "^${STATUS_KEY}:" "$LAST_SENT_FILE" | cut -d':' -f2)
    fi

    local NOW=$(date +%s)
    local ELAPSED=$((NOW - LAST_SENT))

    # Guard against clock skew producing a negative elapsed time
    if (( ELAPSED < 0 )); then
        log "WARNING: Negative elapsed time detected for '${STATUS_KEY}' (clock skew?). Resetting and forcing notification."
        ELAPSED=$NOTIFY_INTERVAL
    fi

    if (( ELAPSED >= NOTIFY_INTERVAL )); then
        log "INFO: Sending Discord notification for '${STATUS_KEY}'..."

        curl -s -H "Content-Type: application/json" -X POST -d "{\"content\": \"${MESSAGE}\"}" "$DISCORD_WEBHOOK_URL" >> "$LOG_FILE" 2>&1

        # Update last sent timestamp
        grep -v "^${STATUS_KEY}:" "$LAST_SENT_FILE" > "${LAST_SENT_FILE}.tmp"
        echo "${STATUS_KEY}:${NOW}" >> "${LAST_SENT_FILE}.tmp"
        mv "${LAST_SENT_FILE}.tmp" "$LAST_SENT_FILE"
    else
        log "INFO: Skipping Discord notification for '${STATUS_KEY}' (last sent $((ELAPSED / 60)) minutes ago)"
    fi
}

# FUNCTION - Attempt docker restart, fall back to Portainer webhook on failure
restart_or_redeploy() {
    local REASON="$1"  # e.g. "not_running", "unhealthy", "functional_test_failed"

    log "INFO: Attempting docker restart for '${CONTAINER_NAME}'..."
    docker restart "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        local MSG="ERROR: docker restart failed for '${CONTAINER_NAME}' (reason: ${REASON}). Triggering Portainer webhook to redeploy stack..."
        log "$MSG"
        notify_discord "${REASON}_restart_failed" "$MSG"

        curl -s -X POST "$PORTAINER_WEBHOOK_URL" >> "$LOG_FILE" 2>&1

        if [[ $? -eq 0 ]]; then
            log "INFO: Portainer webhook triggered successfully."
        else
            log "ERROR: Failed to trigger Portainer webhook."
            notify_discord "webhook_failed" "ERROR: Failed to trigger Portainer webhook for '${CONTAINER_NAME}' after restart failure!"
        fi
    else
        log "INFO: docker restart succeeded for '${CONTAINER_NAME}'."
    fi
}

#
##
### Main Checks ###
##
#

# 1. Check if container exists
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    MSG="ERROR: Container '${CONTAINER_NAME}' does not exist! Triggering Portainer webhook to deploy stack..."
    log "$MSG"
    notify_discord "missing_container" "$MSG"

    # Trigger Portainer webhook
    curl -s -X POST "$PORTAINER_WEBHOOK_URL" >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        log "INFO: Webhook triggered successfully."
    else
        log "ERROR: Failed to trigger webhook."
        notify_discord "webhook_failed" "ERROR: Failed to trigger Portainer webhook for $CONTAINER_NAME stack!"
    fi

    exit 1
fi

# 2. Check if container is running
if ! docker inspect -f '{{.State.Running}}' "$CONTAINER_NAME" | grep -q true; then
    MSG="WARNING: Container '${CONTAINER_NAME}' is not running. Restarting..."
    log "$MSG"
    notify_discord "not_running" "$MSG"

    restart_or_redeploy "not_running"
    exit 1
fi

# 3. Check container health (if healthcheck exists)
HEALTH_STATUS=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER_NAME" 2>/dev/null)

if [[ "$HEALTH_STATUS" == "unhealthy" ]]; then
    MSG="WARNING: Container '${CONTAINER_NAME}' is unhealthy. Restarting..."
    log "$MSG"
    notify_discord "unhealthy" "$MSG"

    restart_or_redeploy "unhealthy"
    exit 1
fi

# 4. Functional test to Container APP
if ! eval "$HC_COMMAND"; then
    MSG="WARNING: $CONTAINER_NAME web-gui test failed. Restarting container..."
    log "$MSG"
    notify_discord "functional_test_failed" "$MSG"

    restart_or_redeploy "functional_test_failed"
    exit 1
fi

# All good
log "INFO: $CONTAINER_NAME container is healthy and responding."

# --- Trim log: Keep last 1000 lines only ---

MAX_LINES=1000
TMP_LOG="${LOG_FILE}.tmp"

if [ -s "$LOG_FILE" ]; then
    tail -n "$MAX_LINES" "$LOG_FILE" > "$TMP_LOG" && mv "$TMP_LOG" "$LOG_FILE"
else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: Log file is empty, skipping trim." >> "$LOG_FILE"
fi
