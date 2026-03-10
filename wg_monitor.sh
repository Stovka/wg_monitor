#!/usr/bin/env bash

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
log_path="/var/log/wg_monitor.log"
log_state="/var/run/wg_monitor.connected"

# ---- JSON keys customization ----
json_ts_script="ts"             # current timestamp key
json_ts_handshake="hs"          # last handshake timestamp key
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
# Supported: ts, hs, iface, msg, peer, host, ip
# Example: only log hs and peer first, ts last
log_fields=(ts hs iface msg peer host ip)
# To change order or skip a field, just edit this array
# Example: log_fields=(hs peer ip ts)

# ---------------------------------

# Ensure files exist
touch "$log_state" "$log_path"

# Detect full path to wg command
WGCOMMAND=$(which wg)

# --- Logging function ---
log_event() {
    local ts="$1"
    local hs="$2"
    local iface="$3"
    local msg="$4"
    local peer="$5"
    local host="$6"
    local ip="$7"

    # Build associative array for fields
    declare -A fields
    fields=( ["ts"]="$ts" ["hs"]="$hs" ["iface"]="$iface" ["msg"]="$msg" ["peer"]="$peer" ["host"]="$host" ["ip"]="$ip" )

    if [[ "$format" == "json" ]]; then
        line="{"
        first=1
        for f in "${log_fields[@]}"; do
            [[ -z "${fields[$f]}" ]] && continue
            [[ $first -eq 0 ]] && line+=","
            line+="\"${!f}\":\"${fields[$f]}\""
            first=0
        done
        line+="}"
        echo "$line" >> "$log_path"
    else
        # separator format
        line=""
        for f in "${log_fields[@]}"; do
            [[ -z "${fields[$f]}" ]] && continue
            [[ -n "$line" ]] && line+="$sep"
            line+="${fields[$f]}"
        done
        echo "$line" >> "$log_path"
    fi
}

# --- Load peer aliases (optional) ---
declare -A alias
if [[ -f "$peers" ]]; then
    while IFS=: read -r key name; do
        alias[$key]=$name
    done < "$peers"
fi

now=$(date +%s)

# --- Iterate over WireGuard peers ---
while read iface key psk endpoint allowed latest rx tx keepalive; do

    [[ "$endpoint" == "(none)" ]] && continue
    [[ "$latest" == "0" ]] && continue

    ip=${endpoint%%:*}
    age=$((now-latest))

    name=${alias[$key]}
    [[ -z "$name" ]] && name=""

    id="$iface $key"
    cur_ts=$(date -u +%FT%TZ)

    if (( age < threshold )); then
        # New connection
        if ! grep -q "^$id " "$log_state"; then
            hs=$(date -u -d @"$latest" +%FT%TZ)
            log_event "$cur_ts" "$hs" "$iface" "$msg_connected" "$key" "$name" "$ip"
            echo "$iface $key $name $ip" >> "$log_state"

        # Check for roaming
        else
            read _ _ oldname oldip <<< "$(grep "^$id " "$log_state")"
            if [[ "$oldip" != "$ip" ]]; then
                hs=$(date -u -d @"$latest" +%FT%TZ)
                log_event "$cur_ts" "$hs" "$iface" "$msg_roamed" "$key" "$name" "$oldip->$ip"

                grep -v "^$id " "$log_state" > "$log_state.tmp"
                echo "$iface $key $name $ip" >> "$log_state.tmp"
                mv "$log_state.tmp" "$log_state"
            fi
        fi

    else
        # Peer disconnected
        if grep -q "^$id " "$log_state"; then
            read _ _ oldname oldip <<< "$(grep "^$id " "$log_state")"
            hs=$(date -u -d @"$latest" +%FT%TZ)
            log_event "$cur_ts" "$hs" "$iface" "$msg_disconnected" "$key" "$oldname" "$oldip"

            grep -v "^$id " "$log_state" > "$log_state.tmp" && mv "$log_state.tmp" "$log_state"
        fi
    fi

done < <($WGCOMMAND show all dump)
