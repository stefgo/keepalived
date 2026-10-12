# keepalived

keepalived as a Docker container, restricted to VRRP. One or more VRRP
instances, optional check scripts (`vrrp_script`) and notify scripts for
state changes are configured through environment variables. The image is based on Alpine; keepalived is started
with `--vrrp`, so the LVS/IPVS checker subsystem does not run.

## Requirements

- Linux host with Docker and the Compose plugin
- The container runs with `network_mode: host`, because the VRRP
  advertisements and the virtual IP addresses belong to the host interfaces.
- The container is granted the `NET_ADMIN`, `NET_BROADCAST` and `NET_RAW`
  capabilities.
- If a firewall is active on the host, VRRP (IP protocol 112) must be allowed
  between the peers; in multicast mode to `224.0.0.18`.

## Configuration

```sh
cp .env.example .env
```

`compose.yaml` passes the whole `.env` file to the container, so further
instances and scripts only need to be added there.

### Global

| Variable | Default | Meaning |
|---|---|---|
| `KEEPALIVED_ROUTER_ID` | hostname | `router_id` in `global_defs` |
| `KEEPALIVED_SCRIPT_USER` | `root` | User that runs the check and notify scripts |
| `TZ` | UTC | Time zone of the container |

### VRRP instances

Instances are numbered consecutively starting at 1 (`VRRP_1_*`, `VRRP_2_*`,
...). Every `VRRP_<n>_<KEY>` except `NAME` falls back to `VRRP_<KEY>`, which
therefore acts as the default for all instances.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `VRRP_<n>_INTERFACE` | yes | – | Interface the instance runs on, e.g. `eth0` |
| `VRRP_<n>_VIRTUAL_ROUTER_ID` | yes | – | 1–255, identical on all hosts of the virtual router, unique per interface |
| `VRRP_<n>_VIRTUAL_IPS` | yes | – | Comma-separated; an entry may carry keepalived options, e.g. `192.168.1.100/24 dev eth0 label eth0:vip` |
| `VRRP_<n>_NAME` | no | `VI_<n>` | Name of the instance |
| `VRRP_<n>_STATE` | no | `BACKUP` | Initial state, `MASTER` or `BACKUP` |
| `VRRP_<n>_PRIORITY` | no | `100` | 1–254; the highest priority becomes master |
| `VRRP_<n>_ADVERT_INT` | no | `1` | Advertisement interval in seconds |
| `VRRP_<n>_NOPREEMPT` | no | `false` | Do not take the address back from a lower-priority master; requires `STATE=BACKUP` |
| `VRRP_<n>_AUTH_PASS` | no | – | Enables `auth_type PASS`; at most 8 characters, identical on all hosts |
| `VRRP_<n>_UNICAST_SRC_IP` | no | – | Source address for unicast advertisements |
| `VRRP_<n>_UNICAST_PEERS` | no | – | Peer addresses (space- or comma-separated); switches the instance from multicast to unicast |
| `VRRP_<n>_TRACK_INTERFACES` | no | – | Interfaces (space- or comma-separated) whose failure puts the instance into FAULT state |
| `VRRP_<n>_TRACK_SCRIPTS` | no | – | Names of check scripts (space- or comma-separated) |
| `VRRP_<n>_NOTIFY` | no | – | Command called on every state change, see [Notify scripts](#notify-scripts) |
| `VRRP_<n>_NOTIFY_MASTER` | no | – | Command called when entering MASTER state |
| `VRRP_<n>_NOTIFY_BACKUP` | no | – | Command called when entering BACKUP state |
| `VRRP_<n>_NOTIFY_FAULT` | no | – | Command called when entering FAULT state |
| `VRRP_<n>_NOTIFY_STOP` | no | – | Command called when keepalived stops |

### Check scripts

Scripts are numbered consecutively starting at 1 (`VRRP_SCRIPT_1_*`, ...) and
are assigned to an instance by name through `VRRP_<n>_TRACK_SCRIPTS`.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `VRRP_SCRIPT_<n>_SCRIPT` | yes | – | Command with absolute path, or path to a script file; must not contain double quotes |
| `VRRP_SCRIPT_<n>_NAME` | no | `chk_<n>` | Name of the script |
| `VRRP_SCRIPT_<n>_INTERVAL` | no | `2` | Seconds between two runs |
| `VRRP_SCRIPT_<n>_TIMEOUT` | no | – | Seconds after which a run counts as failed |
| `VRRP_SCRIPT_<n>_FALL` | no | – | Consecutive failures before the script counts as failed |
| `VRRP_SCRIPT_<n>_RISE` | no | – | Consecutive successes before the script counts as ok again |
| `VRRP_SCRIPT_<n>_WEIGHT` | no | – | -253–253; changes the priority instead of entering FAULT state |
| `VRRP_SCRIPT_<n>_USER` | no | – | User for this script, overrides `KEEPALIVED_SCRIPT_USER` |
| `VRRP_SCRIPT_<n>_INIT_FAIL` | no | `false` | Assume the script has failed until its first successful run |

Without `WEIGHT`, a failed script puts the instance into FAULT state and the
address moves to the peer. With a negative `WEIGHT`, the priority is reduced
by that value while the script fails; the difference must be large enough to
drop below the priority of the peer.

Notes:

- The script runs inside the container. Because of `network_mode: host` it
  can reach services of the host over the network (e.g.
  `/usr/bin/nc -z -w 1 127.0.0.1 53`), but it does not see the processes of
  the host. Checks such as `pidof` additionally need `pid: host` in
  `compose.yaml`.
- The image contains only the BusyBox tools (`nc`, `wget`, `ping`, ...).
- Script files are mounted to `/etc/keepalived/scripts` (see the commented
  volume in `compose.yaml`). `enable_script_security` is set: the file and
  its directories must be owned by root and must not be writable by anyone
  else, otherwise keepalived disables the script.

### Notify scripts

keepalived calls the notify commands of an instance when its state changes.
`VRRP_<n>_NOTIFY` is called on every change, and keepalived appends four
arguments to the command:

| Argument | Value |
|---|---|
| `$1` | `INSTANCE` |
| `$2` | Name of the instance, e.g. `VI_1` |
| `$3` | New state: `MASTER`, `BACKUP`, `FAULT` or `STOP` |
| `$4` | Current priority |

`VRRP_<n>_NOTIFY_MASTER`, `_BACKUP`, `_FAULT` and `_STOP` are called without
arguments, only for their own state. Like all instance variables they fall
back to `VRRP_NOTIFY*`, so one script can serve all instances.

The image contains `/usr/local/bin/notify-log.sh`, which writes every change
to the container log and can serve as a template:

```sh
VRRP_NOTIFY=/usr/local/bin/notify-log.sh
```

```
notify: INSTANCE VI_LAN changed to MASTER (priority 150)
```

Notes:

- The commands run asynchronously. keepalived neither waits for them nor
  evaluates their exit code, so they cannot prevent a state change, and the
  order of two quickly succeeding calls is not guaranteed.
- The notes on check scripts apply as well: the command runs inside the
  container, must not contain double quotes, and a script file must be owned
  by root and not be writable by anyone else.

### Example: two hosts, one virtual address

Host A:

```sh
VRRP_1_INTERFACE=eth0
VRRP_1_VIRTUAL_ROUTER_ID=51
VRRP_1_VIRTUAL_IPS=192.168.1.100/24
VRRP_1_AUTH_PASS=changeme
VRRP_1_STATE=MASTER
VRRP_1_PRIORITY=150
```

Host B: identical, but

```sh
VRRP_1_STATE=BACKUP
VRRP_1_PRIORITY=100
```

### Own configuration file

If a file is mounted at `/etc/keepalived/keepalived.conf`, it is used
unchanged and all `VRRP_*` variables are ignored. keepalived is still started
with `--vrrp`.

## Operation

```sh
docker compose up -d
docker compose logs -f
```

Before the start, the entrypoint validates the variables and runs
`keepalived --config-test`; on an error the container exits with a message.

Show the effective configuration (password masked) without starting
keepalived:

```sh
docker compose run --rm keepalived config
```

Additional arguments are passed on to keepalived, e.g.
`command: ["--log-detail"]` in `compose.yaml`.

The health check reports healthy while the keepalived parent process and its
VRRP child are running. It does not say whether the host is currently master.
