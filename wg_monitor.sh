#!/usr/bin/env bash

set -euo pipefail

exec 200>/var/run/wg_monitor.lock
flock -n 200 || exit 0

# ----------------- Settings -----------------
threshold=300                   # seconds after last handshake to consider disconnected
peers="/etc/wireguard/peers"    # optional peer aliases file
# Optional peers file containing friendly aliases for WG public keys
# - compatible with https://github.com/FlyveHest/wg-friendly-peer-names/
# - format:
# wg_public_key1:Client1
# wg_public_key2:Client2
format="sep"                    # json | sep
sep="|"                         # used only when format=sep

# Log and state files
log_file="/var/log/wg_monitor.log"   # empty = do not log to file
log_journal=true                     # true/false
logger_name=""                       # empty = wg_monitor
log_state=""                         # empty = /var/run/wg_monitor.connected

# ---- JSON keys customization ----
json_ts_script="ts"             # current timestamp key
json_ts_handshake="hs"          # last handshake timestamp key
json_duration="d"               # duration in seconds key
json_iface="i"                  # interface key
json_msg="m"                    # message key
json_peer="p"                   # peer public key key
json_host="h"                   # peer alias key
json_ip="ip"                    # peer IP key

# ---- Message customization ----
msg_connected="CONNECTED"
msg_disconnected="DISCONNECTED"
msg_roamed="ROAMED"

# ---- Log field configuration ----
# Define what fields to log and their order.
# Supported: ts, hs, duration, iface, msg, peer, host, ip
log_fields=(ts hs duration iface msg peer host ip)
# To change order or skip a field, just edit this array
# Example: log_fields=(hs peer ip ts)

# ---------------------------------

declare -A json_field_map=(
    [ts]="$json_ts_script"
    [hs]="$json_ts_handshake"
    [duration]="$json_duration"
    [iface]="$json_iface"
    [msg]="$json_msg"
    [peer]="$json_peer"
    [host]="$json_host"
    [ip]="$json_ip"
)

# --- Logging function ---
log_event() {
    local ts="$1"
    local hs="$2"
    local duration="$3"
    local iface="$4"
    local msg="$5"
    local peer="$6"
    local host="$7"
    local ip="$8"

    declare -A fields
    fields=( ["ts"]="$ts" ["hs"]="$hs" ["duration"]="$duration" ["iface"]="$iface" ["msg"]="$msg" ["peer"]="$peer" ["host"]="$host" ["ip"]="$ip" )

    local line=""

    if [[ "$format" == "json" ]]; then
        line="{"
        local first=1
        for f in "${log_fields[@]}"; do
            [[ $first -eq 0 ]] && line+=","
            val="${fields[$f]:-}"
            val="${val//\\/\\\\}"       # backslash
            val="${val//\"/\\\"}"       # double quote
            val="${val//$'\t'/\\t}"     # tab
            val="${val//$'\n'/\\n}"     # newline
            val="${val//$'\r'/\\r}"     # carriage return
            line+="\"${json_field_map[$f]:-$f}\":\"$val\""
            first=0
        done
        line+="}"
    else
        for f in "${log_fields[@]}"; do
            [[ -n "$line" ]] && line+="$sep"
            val="${fields[$f]:-}"
            val="${val//$sep/}"         # strip separator characters
            line+="$val"
        done
    fi

    if [[ -n "$log_file" ]]; then
        echo "$line" >> "$log_file"
    fi

    if [[ "$log_journal" == "true" ]]; then
        logger -t "$logger_name" -- "$line"
    fi
}


# --- Validation config function ---
validate_config() {

    # Detect full path to wg command
    WGCOMMAND=$(command -v wg) || {
        echo "ERROR: wg command not found"
        exit 1
    }

    # Default logger name
    if [[ -z "$logger_name" ]]; then
        logger_name="wg_monitor"
    fi

    # Validate log_journal boolean
    if [[ "$log_journal" != "true" && "$log_journal" != "false" ]]; then
        echo "ERROR: log_journal must be true or false"
        exit 1
    fi

    # Validate logging destination
    if [[ -z "$log_file" && "$log_journal" == "false" ]]; then
        echo "ERROR: No logging destination defined (log_file empty AND log_journal=false)"
        exit 1
    fi

    # validate log format
    if [[ "$format" != "json" && "$format" != "sep" ]]; then
        echo "ERROR: format must be 'json' or 'sep'"
        exit 1
    fi

    # validate sep
    if [[ "$format" == "sep" && -z "$sep" ]]; then
        echo "ERROR: sep cannot be empty when format=sep"
        exit 1
    fi

    # validate sep is not a base64 character (would break log)
    if [[ "$format" == "sep" ]]; then
        if [[ "$sep" =~ [A-Za-z0-9+/=] ]]; then
            echo "ERROR: sep cannot be a base64 character (A-Z, a-z, 0-9, +, /, =)"
            exit 1
        fi
    fi

    # Validate log_fields not empty
    if [[ ${#log_fields[@]} -eq 0 ]]; then
        echo "ERROR: log_fields must contain at least one field"
        exit 1
    fi

    # Validate log_fields content
    allowed_fields=(ts hs duration iface msg peer host ip)
    for field in "${log_fields[@]}"; do
        valid=false
        for allowed in "${allowed_fields[@]}"; do
            if [[ "$field" == "$allowed" ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" == "false" ]]; then
            echo "ERROR: Invalid field in log_fields: $field"
            echo "Allowed fields: ${allowed_fields[*]}"
            exit 1
        fi
    done

    # log_state is defined
    if [[ -z "$log_state" ]]; then
        log_state="/var/run/wg_monitor.connected"
    fi

    # log_state is writable
    touch "$log_state" 2>/dev/null || {
    echo "ERROR: Cannot write to log_state: $log_state"
        exit 1
    }

    # Create log_file only if defined
    if [[ -n "$log_file" ]]; then
        touch "$log_file" || {
            echo "ERROR: Cannot write to log_file: $log_file"
            exit 1
        }
    fi

    # logger exists
    if [[ "$log_journal" == "true" ]]; then
        command -v logger >/dev/null || {
            echo "ERROR: logger command not found"
            exit 1
        }
    fi
}
# --- Run validation ---
validate_config

# --- Define date_from_epoch
if date -r 0 >/dev/null 2>&1; then
  date_from_epoch() { date -u -r "$1" +%FT%TZ; }
else
  date_from_epoch() { date -u -d "@$1" +%FT%TZ; }
fi

# --- Load peer aliases (optional) ---
declare -A peer_aliases
if [[ -f "$peers" ]]; then
    while IFS= read -r line; do
        # Ignore empty lines, comments, lines without :
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        [[ "$line" != *:* ]] && continue
        key="${line%%:*}"
        name_rest="${line#*:}"
        peer_aliases[$key]="$name_rest"
    done < "$peers"
fi

# --- Load current state ---
declare -A state
declare -A seen
while IFS='|' read -r iface key name ip connected_since; do
    id="$iface|$key"
    state["$id"]="$name|$ip|$connected_since"
done < "$log_state" || true

now=$(date +%s)
printf -v cur_ts '%(%Y-%m-%dT%H:%M:%SZ)T' -1


# --- Iterate over WireGuard peers ---
wg_dump=$("$WGCOMMAND" show all dump) || {
    echo "ERROR: wg show all dump failed" >&2
    exit 1
}
while IFS=$'\t' read -r iface key psk endpoint allowed latest rx tx keepalive extra; do
    # Skip interface header lines (fewer fields, latest will be empty)
    [[ -z "$latest" ]] && continue
    # Skip peers that have never connected
    [[ "$latest" == "0" && "$endpoint" == "(none)" ]] && continue

    # Extract IP from endpoint (handles both IPv4 host:port and [IPv6]:port)
    ip=${endpoint%:*}; ip=${ip#[}; ip=${ip%]}

    age=$((now - latest))
    id="$iface|$key"
    seen["$id"]=1

    # Resolve alias and sanitize user-controlled fields before any use
    name="${peer_aliases[$key]:-}"
    name="${name//|/}"
    ip="${ip//|/}"

    if [[ "$latest" != "0" ]]; then
        hs=$(date_from_epoch "$latest")
    else
        hs="$cur_ts"
    fi

    if (( age < threshold )); then
        if [[ -z "${state[$id]:-}" ]]; then
            # New connection: peer not in state, now within threshold
            # duration = now - last handshake
            connected_since="$latest"
            duration=$(( now - latest ))
            log_event "$cur_ts" "$hs" "$duration" "$iface" "$msg_connected" "$key" "$name" "$ip"
        else
            # Already connected: check for roam (IP change)
            # extract original connected_since, preserve it on roam
            connected_since="${state[$id]##*|}"
            oldip="${state[$id]#*|}"
            oldip="${oldip%|*}"
            if [[ "$oldip" != "$ip" ]]; then
                duration=$(( now - connected_since ))
                log_event "$cur_ts" "$hs" "$duration" "$iface" "$msg_roamed" "$key" "$name" "${oldip}->${ip}"
            fi
        fi
        # Update state preserving original connected_since
        state["$id"]="$name|$ip|$connected_since"
    else
        # Disconnect: log disconnect if it was previously connected
        if [[ -n "${state[$id]:-}" ]]; then
            oldname="${state[$id]%%|*}"
            rest="${state[$id]#*|}"
            oldip="${rest%|*}"
            # duration = now - connected_since
            connected_since="${rest##*|}"
            duration=$(( now - connected_since ))
            log_event "$cur_ts" "$hs" "$duration" "$iface" "$msg_disconnected" "$key" "$oldname" "$oldip"
            unset 'state[$id]'
        fi
    fi
done <<< "$wg_dump"

# --- Handle peers removed entirely ---
for id in "${!state[@]}"; do
    if [[ -z "${seen[$id]:-}" ]]; then
        iface="${id%%|*}"
        key="${id#*|}"
        oldname="${state[$id]%%|*}"
        rest="${state[$id]#*|}"
        oldip="${rest%|*}"
        connected_since="${rest##*|}"
        duration=$(( now - connected_since ))
        hs="$cur_ts"  # Set hs to cur_ts because hs is unknown
        log_event "$cur_ts" "$hs" "$duration" "$iface" "$msg_disconnected" "$key" "$oldname" "$oldip"
        unset 'state[$id]'
    fi
done

# --- Write back the updated state ---
tmp_state=$(mktemp "${log_state}.XXXXXX")
trap 'rm -f "$tmp_state"' EXIT
for id in "${!state[@]}"; do
    iface="${id%%|*}"; key="${id#*|}"
    rest="${state[$id]#*|}"
    name="${state[$id]%%|*}"
    ip="${rest%|*}"
    connected_since="${rest##*|}"
    name="${name//|/}"
    ip="${ip//|/}"
    printf '%s\n' "$iface|$key|$name|$ip|$connected_since"
done > "$tmp_state"
mv -f "$tmp_state" "$log_state"
