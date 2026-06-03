#!/usr/bin/env bash

set -euo pipefail

# ----------------- Settings -----------------
threshold=300                   # seconds after last handshake to consider disconnected
interval=60                     # Interval between checks (only used with --watch option)
peers="/etc/wireguard/peers"    # optional peer aliases file
# Optional peers file containing friendly aliases for WG public keys
# - compatible with https://github.com/FlyveHest/wg-friendly-peer-names/
# - format:
# wg_public_key1:Client1
# wg_public_key2:Client2
format="sep"                       # json | sep
sep="|"                            # used only when format=sep
datetime_format="local_datetime"   # local_datetime/offset_datetime/gmt/unix_timestamp
# local_datetime  = YYYY-MM-DDThh:mm:ss
# offset_datetime = YYYY-MM-DDThh:mm:ss+01:00
# gmt             = YYYY-MM-DDThh:mm:ssZ
# unix_timestamp  = 1767225600

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


usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --watch                Run in continuous mode
  --interval <seconds>   Interval between WG checks
  -h, --help             Show this help
EOF
}


# --- Arguments parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)
            continuous=true
            shift
            ;;
        --interval)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --interval requires a value" >&2
                usage
                exit 1
            fi
            interval="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done


continuous=${continuous:-false}
running=true

shutdown() {
    running=false
}

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
        # JSON
        line="{"
        local first=1
        for f in "${log_fields[@]}"; do
            [[ $first -eq 0 ]] && line+=","
            val="${fields[$f]:-}"
            val="${val//\\/\\\\}"       # backslash
            val="${val//\"/\\\"}"       # double quote
            val="${val//$'\n'/\\n}"     # newline
            val="${val//$'\r'/\\r}"     # carriage return
            val="${val//$'\t'/\\t}"     # tab
            line+="\"${json_field_map[$f]:-$f}\":\"$val\""
            first=0
        done
        line+="}"
    else
        # Separator
        for f in "${log_fields[@]}"; do
            [[ -n "$line" ]] && line+="$sep"
            val="${fields[$f]:-}"
            # sep format value sanitization
            val="${val//$sep/}"
            val="${val//$'\n'/}"
            val="${val//$'\r'/}"
            val="${val//$'\t'/}"
            line+="$val"
        done
    fi

    if [[ -n "$log_file" ]]; then
        echo "$line" >> "$log_file" || true
    fi

    if [[ "$log_journal" == "true" ]]; then
        logger -t "$logger_name" -- "$line" || true
    fi
}

# --- Validation config function ---
validate_config() {

    # Detect full path to wg command
    WGCOMMAND=$(command -v wg) || {
        echo "ERROR: wg command not found"
        exit 1
    }

    # Check if flock exists
    command -v flock >/dev/null || {
        echo "ERROR: flock not found"
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

    # validate sep is not a base64 character or white space (would break log)
    if [[ "$format" == "sep" ]]; then
        if [[ "$sep" =~ [A-Za-z0-9+/=] ]]; then
            echo "ERROR: sep cannot be a base64 character (A-Z, a-z, 0-9, +, /, =)"
            exit 1
        fi
        if [[ "$sep" =~ [[:space:]] ]]; then
            echo "ERROR: sep cannot be a whitespace character"
            exit 1
        fi
    fi

    # validate datetime_format
    case "$datetime_format" in
        local_datetime|offset_datetime|gmt|unix_timestamp)
            ;;
        *)
            echo "ERROR: datetime_format must be one of: local_datetime, offset_datetime, gmt, unix_timestamp"
            exit 1
            ;;
    esac

    # Validate log_fields not empty
    if [[ ${#log_fields[@]} -eq 0 ]]; then
        echo "ERROR: log_fields must contain at least one field"
        exit 1
    fi

    # Validate log_fields duplicates
    declare -A _seen_fields
    for field in "${log_fields[@]}"; do
        if [[ -n "${_seen_fields[$field]:-}" ]]; then
            echo "ERROR: Duplicate field in log_fields: $field"
            exit 1
        fi
        _seen_fields[$field]=1
    done

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

    # validate interval
    if ! [[ "$interval" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: interval must be a positive integer greater than 0"
        exit 1
    fi
}

# --- Datetime formatter ---
date_cmd_supports_r=false
if date -r 0 >/dev/null 2>&1; then
    date_cmd_supports_r=true
fi

format_datetime() {
    local epoch="$1"

    case "$datetime_format" in
        gmt)
            if [[ "$date_cmd_supports_r" == "true" ]]; then
                date -u -r "$epoch" +%FT%TZ
            else
                date -u -d "@$epoch" +%FT%TZ
            fi
            ;;
        local_datetime)
            if [[ "$date_cmd_supports_r" == "true" ]]; then
                date -r "$epoch" +%FT%T
            else
                date -d "@$epoch" +%FT%T
            fi
            ;;
        offset_datetime)
            if [[ "$date_cmd_supports_r" == "true" ]]; then
                date -r "$epoch" +%FT%T%:z
            else
                date -d "@$epoch" +%FT%T%:z
            fi
            ;;
        unix_timestamp)
            echo "$epoch"
            ;;
    esac
}

# --- Load peer aliases (optional) ---
declare -A peer_aliases
load_aliases() {
    peer_aliases=()
    if [[ -f "$peers" ]]; then
        while IFS= read -r line || [[ -n "${line:-}" ]]; do
            # Ignore empty lines, comments, lines without :
            [[ -z "$line" ]] && continue
            [[ "$line" == \#* ]] && continue
            [[ "$line" != *:* ]] && continue
            key="${line%%:*}"
            name_rest="${line#*:}"
            peer_aliases[$key]="$name_rest"
        done < "$peers"
    fi
}

# --- Single run ---
run_once() {
    now=$(date +%s)
    cur_ts=$(format_datetime "$now")

    # Load previous state
    declare -A state
    declare -A seen
    while IFS='|' read -r iface key name ip connected_since extra || [[ -n "${iface:-}" ]]; do
        # skip malformed
        [[ -n "$extra" ]] && continue 
        [[ -z "$iface" || -z "$key" ]] && continue
        [[ "$connected_since" =~ ^[0-9]+$ ]] || continue
        id="$iface|$key"
        state["$id"]="$name|$ip|$connected_since"
    done < "$log_state" || true

    # Iterate over current WireGuard peers
    if ! wg_dump=$("$WGCOMMAND" show all dump); then
        echo "ERROR: wg show all dump failed" >&2
        return 1
    fi
    while IFS=$'\t' read -r iface key psk endpoint allowed latest rx tx keepalive extra; do
        # Skip interface header lines (fewer fields, latest will be empty)
        [[ -z "$latest" ]] && continue
        # Skip peers that have never connected
        [[ "$latest" == "0" && "$endpoint" == "(none)" ]] && continue
        # Skip if latest is not a number
        if ! [[ "$latest" =~ ^[0-9]+$ ]]; then
            continue
        fi

        # Extract IP from endpoint (handles IPv4 host:port, [IPv6]:port, hostname)
        case "$endpoint" in
            \[*\]:*) ip="${endpoint#\[}"; ip="${ip%%\]:*}" ;;
            *:*)     ip="${endpoint%:*}" ;;
            *)        ip="$endpoint" ;;
        esac


        if (( latest > now )); then
            latest="$now"  # Overwrite latest to now if latest is greater 
        fi
        age=$((now - latest))
        id="$iface|$key"
        seen["$id"]=1

        # Resolve alias and sanitize user-controlled fields
        name="${peer_aliases[$key]:-}"
        name="${name//|/}"
        ip="${ip//|/}"

        if [[ "$latest" != "0" ]]; then
            hs=$(format_datetime "$latest")
        else
            hs="$cur_ts"
        fi

        if (( age < threshold )); then
            if [[ -z "${state[$id]:-}" ]]; then
                # New connection: peer not in previous state
                connected_since="$latest"
                # duration = now - last handshake
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
                connected_since="${rest##*|}"
                duration=$(( now - connected_since - threshold ))  # Subtract threshold to get more accurate reading
                (( duration < 0 )) && duration=0
                log_event "$cur_ts" "$hs" "$duration" "$iface" "$msg_disconnected" "$key" "$oldname" "$oldip"
                unset 'state[$id]'
            fi
        fi
    done <<< "$wg_dump"

    # Handle removed peers (peer disappeared from wg output entirely)
    # This happens on client when WG is shutdown. On server only when its restarted and client was removed or WG shutdown 
    for id in "${!state[@]}"; do
        if [[ -z "${seen[$id]:-}" ]]; then
            iface="${id%%|*}"
            key="${id#*|}"
            oldname="${state[$id]%%|*}"
            rest="${state[$id]#*|}"
            oldip="${rest%|*}"
            connected_since="${rest##*|}"
            # There is no threshold subtraction because this is being run every time not only when age < threshold
            # Duration will be skewed randomly on average interval / 2 in continuous mode
            duration=$(( now - connected_since ))
            hs="$cur_ts"  # Set hs to cur_ts because hs is unknown
            log_event "$cur_ts" "$hs" "$duration" "$iface" "$msg_disconnected" "$key" "$oldname" "$oldip"
            unset 'state[$id]'
        fi
    done

    # Update state file
    if ! tmp_state=$(mktemp "${log_state}.XXXXXX"); then
        echo "ERROR: mktemp failed" >&2
        return 1
    fi
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
    if ! mv -f "$tmp_state" "$log_state"; then
        rm -f "$tmp_state"
        echo "ERROR: failed to update state file" >&2
        return 1
    fi
}


validate_config
load_aliases
lock_file="${log_state}.lock"
exec 200>"$lock_file"
if ! flock -n 200; then
    printf "ERROR: Already running."
    exec 200>&-
    if command -v fuser >/dev/null; then
        printf " Lock held by PID(s): "
        fuser "$lock_file" 2>/dev/null
    fi
    echo
    exit 1
fi

sleep_pid=0
trap 'running=false; [[ $sleep_pid -ne 0 ]] && kill "$sleep_pid" 2>/dev/null || true' TERM INT HUP
trap 'exec 200>&-' EXIT

if [[ "$continuous" == "true" ]]; then
    while $running; do
        run_once || echo "WARNING: run_once failed, retrying in ${interval}s" >&2
        ( exec 200>&-; sleep "$interval" ) &  # Release fd in child
        sleep_pid=$!
        wait $sleep_pid || true
        sleep_pid=0  # Prevent trap killing reused PID when interrupted in run_once
    done
else
    run_once
fi
