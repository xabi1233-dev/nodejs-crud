#!/usr/bin/env bash
#
# Keeps a DuckDNS subdomain pointed at this instance's current public IP.
#
# Runs from cron every 5 minutes (see /etc/cron.d/duckdns). Only contacts
# DuckDNS when the IP has actually changed, or once every 12 hours to keep the
# record alive — DuckDNS expires domains after ~30 days without an update.
#
# Credentials are NOT in this file. Create /etc/duckdns.conf on the server:
#
#   DUCKDNS_DOMAIN=yoursubdomain     # just the label, no .duckdns.org
#   DUCKDNS_TOKEN=your-token-uuid
#
#   sudo chmod 600 /etc/duckdns.conf
#   sudo chown root:root /etc/duckdns.conf

set -uo pipefail

CONFIG=/etc/duckdns.conf
STATE_DIR=/var/lib/duckdns
STATE_FILE="$STATE_DIR/last_ip"
LOG=/var/log/duckdns.log
FORCE_AFTER_SECONDS=$((12 * 3600))

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

if [[ ! -r $CONFIG ]]; then
  log "ERROR: $CONFIG missing or unreadable"
  exit 1
fi

# shellcheck source=/dev/null
source "$CONFIG"

if [[ -z ${DUCKDNS_DOMAIN:-} || -z ${DUCKDNS_TOKEN:-} ]]; then
  log "ERROR: DUCKDNS_DOMAIN or DUCKDNS_TOKEN not set in $CONFIG"
  exit 1
fi

mkdir -p "$STATE_DIR"

# --- Find our current public IP -------------------------------------------
# EC2's instance metadata service is authoritative and never rate-limits.
# IMDSv2 requires a session token first; fall back to an external service if
# metadata is unreachable (e.g. IMDS disabled).

get_public_ip() {
  local token ip
  token="$(curl -fsS -m 3 -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)"

  if [[ -n $token ]]; then
    ip="$(curl -fsS -m 3 -H "X-aws-ec2-metadata-token: $token" \
      "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null)"
    [[ -n $ip ]] && { echo "$ip"; return 0; }
  fi

  # Fallback: ask an external service what it sees.
  ip="$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null)"
  [[ -n $ip ]] && { echo "$ip"; return 0; }

  return 1
}

CURRENT_IP="$(get_public_ip)"

if [[ -z ${CURRENT_IP:-} ]]; then
  log "ERROR: could not determine public IP (no metadata, no external service)"
  exit 1
fi

# Sanity check the shape before sending it anywhere.
if [[ ! $CURRENT_IP =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
  log "ERROR: '$CURRENT_IP' is not a valid IPv4 address"
  exit 1
fi

# --- Decide whether an update is needed ------------------------------------

LAST_IP=""
[[ -f $STATE_FILE ]] && LAST_IP="$(cat "$STATE_FILE" 2>/dev/null)"

NEEDS_UPDATE=false
REASON=""

if [[ $CURRENT_IP != "$LAST_IP" ]]; then
  NEEDS_UPDATE=true
  REASON="IP changed: ${LAST_IP:-none} -> $CURRENT_IP"
elif [[ -f $STATE_FILE ]]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$STATE_FILE") ))
  if (( AGE > FORCE_AFTER_SECONDS )); then
    NEEDS_UPDATE=true
    REASON="keepalive refresh (last update ${AGE}s ago)"
  fi
fi

if [[ $NEEDS_UPDATE == false ]]; then
  # Silent on the happy path — this runs 288 times a day.
  exit 0
fi

# --- Update DuckDNS ---------------------------------------------------------

RESPONSE="$(curl -fsS -m 10 \
  "https://www.duckdns.org/update?domains=${DUCKDNS_DOMAIN}&token=${DUCKDNS_TOKEN}&ip=${CURRENT_IP}" \
  2>/dev/null)"

if [[ $RESPONSE == "OK" ]]; then
  echo "$CURRENT_IP" > "$STATE_FILE"
  log "OK  $REASON"
  exit 0
fi

# DuckDNS answers "KO" for a bad token or unknown domain, and nothing at all
# if the request never landed.
log "FAILED ($REASON) - DuckDNS replied: '${RESPONSE:-<no response>}'"
exit 1
