# WireGuard Peer Monitor (wg_monitor.sh)
A shell script that logs peer connections and disconnections to a WireGuard server. It parses `wg show all dump` (last handshake) to determine who connected/disconnected to Wireguard server. It also works for WireGuard clients - tracking outgoing connections per WG interface.


## Features
- **Logs new connection**
- **Logs disconnections**
- **Logs roaming** - Client changing public IP
- **Customizable logging**
  - You can change format of logs (json, separator based)
  - You can change what should be logged and order
  - You can change where it should log (file, journal)

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
# Compatible with wgg.sh script: https://github.com/FlyveHest/wg-friendly-peer-names/
nano /etc/wireguard/peers
# cat /etc/wireguard/peers
# LuQ3 ... 0yWc=:Client1
# P3Q7 ... RuH4=:Client2
```

## Running the script
- It leverages the `wg` command which usually requires root permissions thats why it also needs root and why we set `sudo chmod 700` earlier
- Script evaluates the `wg show all dump` every time you run it and compares it to previous run
- You can test it by running it directly (`./wg_monitor.sh`)
  - By default it logs to `/var/log/wg_monitor.log` current connections are tracked in `/var/run/wg_monitor.connected`
  - You can change where and how it should log
- To monitor WG clients continuously you need to run it periodically
- For that you can use whatever scheduling mechanism you prefer.
- For example you can create CRON job
```bash
sudo crontab -e

# Run /usr/local/bin/wg_monitor.sh every minute
* * * * * /usr/local/bin/wg_monitor.sh
```
- Or you can create service
```bash
# /etc/systemd/system/wg_monitor.timer
[Unit]
Description=WireGuard peer monitor

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5

[Install]
WantedBy=timers.target
```

```bash
# /etc/systemd/system/wg_monitor.service
[Unit]
Description=WireGuard peer monitor

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg_monitor.sh
```

```bash
sudo systemctl daemon-reload

systemctl enable wg_monitor.timer
systemctl start wg_monitor.timer
# systemctl disable wg_monitor.timer
# systemctl stop wg_monitor.timer

systemctl status wg_monitor.timer
systemctl status wg_monitor.service
journalctl -u wg_monitor.service
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
- `log_journal=true` - Whether to log into journal
- `logger_name="wg_monitor"` - Name of the logger in journal (Only used when combined with `log_journal=true`)
- `json_*` - Custom keys for json format
- `msg_*` - Custom messages for connection, ...
- `log_fields=(ts hs iface msg peer host ip)` - Fields that should be logged and their order

## Example of logs
- Default sep format:
```
2026-03-10T12:00:01Z|2026-03-10T11:35:00Z|1|wg0|CONNECTED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.1.1
2026-03-10T12:06:01Z|2026-03-10T12:05:13Z|1813|wg0|ROAMED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.1.1->85.193.2.2
2026-03-10T12:10:01Z|2026-03-10T12:09:23Z|2063|wg0|DISCONNECTED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.2.2
```
- Default json format:
```
{"ts":"2026-03-10T12:00:01Z","hs":"2026-03-10T11:35:00Z","d":"1","i":"wg0","m":"CONNECTED","p":"LuQ3bL0T0xxxxxxxO0yWc=","h":"Phone","ip":"85.193.1.1"}
{"ts":"2026-03-10T12:06:01Z","hs":"2026-03-10T12:05:13Z","d":"1813","i":"wg0","m":"ROAMED","p":"LuQ3bL0T0xxxxxxxO0yWc=","h":"Phone","ip":"85.193.1.1->85.193.2.2"}
{"ts":"2026-03-10T12:10:01Z","hs":"2026-03-10T12:09:23Z","d":"2063","i":"wg0","m":"DISCONNECTED","p":"LuQ3bL0T0xxxxxxxO0yWc=","h":"Phone","ip":"85.193.2.2"}
```
- Default sep format in journal
```
mar 03 12:00:01 user wg_monitor[488199]: 2026-03-10T12:00:01Z|2026-03-10T11:35:00Z|1|wg0|CONNECTED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.1.1
mar 03 12:06:01 user wg_monitor[488200]: 2026-03-10T12:06:01Z|2026-03-10T12:05:13Z|1813|wg0|ROAMED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.1.1->85.193.2.2
mar 03 12:10:01 user wg_monitor[488201]: 2026-03-10T12:10:01Z|2026-03-10T12:09:23Z|2063|wg0|DISCONNECTED|LuQ3bL0T0xxxxxxxO0yWc=|Client1|85.193.2.2
```
