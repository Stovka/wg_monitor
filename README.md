# WireGuard Peer Monitor (wg_monitor.sh)
A shell script that logs peer connections and disconnections to a WireGuard server. It parses `wg show all dump` (last handshake) to determine who connected/disconnected to Wireguard server.


## Features
- **Logs new connection**
- **Logs disconnections**
- **Logs roaming** - Client changing public IP
- **Customizable logging**
  - You can change format of logs (json, separator based)
  - You can change what should be logged and order

## Installation
```bash
# Clone this repo
git clone https://github.com/Stovka/wg_monitor.git
cd wg_monitor

# Put the script where ever you like
cp wg_monitor.sh /usr/local/bin/wg_monitor.sh

# Make the script executable
sudo chmod 700 /usr/local/bin/wg_monitor.sh

# (Optional) Create peers file with friendly names
nano /etc/wireguard/peers
# cat /etc/wireguard/peers
# LuQ3 ... 0yWc=:Client1
# P3Q7 ... RuH4=:Client2
```

## Running the script
- Script evaluates the WG clients every time you run it
- It leverages the `wg` command which usually requires root permissions thats why it also needs root and why we set `sudo chmod 700` earlier
- you can test it by running it directly
  - By default it logs to `/var/log/wg_monitor.log`
  - You can change where and how it should log
```bash
wg_monitor.sh
```
- To monitor WG clients continuously you need to run it periodically
- For that you can use whatever scheduling mechanism you prefer.
- For example you can create CRON job
```bash
sudo crontab -e
# Append:
# Run /usr/local/bin/wg_monitor.sh every minute with flock (prevent race condition)
* * * * * /usr/bin/flock -n /tmp/monitor_wg.lockfile /usr/local/bin/wg_monitor.sh
# Run /usr/local/bin/wg_monitor.sh every minute
# * * * * * /usr/local/bin/wg_monitor.sh
```
- Or you can create service
```bash
nano /etc/systemd/system/wg_monitor.service
# Append:
[Unit]
Description=WireGuard Peer Monitor
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wg_monitor.sh
Restart=always
RestartSec=60

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload
sudo systemctl enable wg_monitor.service
sudo systemctl start wg_monitor.service
sudo systemctl status wg_monitor.service
```

## Configuration
- `threshold=300` - Seconds after last handshake to consider a peer disconnected
- `peers="/etc/wireguard/peers"` 
  - Path to peers file containing wg_public_key:friendly_name
  - Compatible with `wgg` https://github.com/FlyveHest/wg-friendly-peer-names/
- `format="json"` - Whether it should log in json or values with separator
- `sep="|"` - Custom separator (Only used when combined with `format="sep"`)
- `log_path="/var/log/wg_monitor.log"` - Path to log file
- `log_state="/var/run/wg_monitor.connected"` - Path to file where current connections are tracked (from previous run)
- `json_*` - Custom keys for json format
- `msg_*` - Custom messages for connection, ...
- `log_fields=(ts hs iface msg peer host ip)` - Fields that should be logged and their order

## Example of logs
- Default sep format:
```
2026-03-10T12:00:01Z|2026-03-10T11:35:00Z|wg0|CONNECTED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.1.1
2026-03-10T12:06:01Z|2026-03-10T12:05:13Z|wg0|ROAMED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.1.1->85.193.2.2
2026-03-10T12:10:01Z|2026-03-10T12:09:23Z|wg0|DISCONNECTED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.2.2
```
- Default json format:
```
{"ts":"2026-03-10T12:00:01Z","hs":"2026-03-10T11:35:00Z","i":"wg0","m":"CONNECTED","p":"LuQ3bL0T0xxxxxxxO0yWc=","h":"Mobil","ip":"85.193.1.1"}
{"ts":"2026-03-10T12:06:01Z","hs":"2026-03-10T12:05:13Z","i":"wg0","m":"ROAMED","p":"LuQ3bL0T0xxxxxxxO0yWc=","h":"Mobil","ip":"85.193.1.1->85.193.2.2"}
{"ts":"2026-03-10T12:10:01Z","hs":"2026-03-10T12:09:23Z","i":"wg0","m":"DISCONNECTED","p":"LuQ3bL0T0xxxxxxxO0yWc=","h":"Mobil","ip":"85.193.2.2"}
```