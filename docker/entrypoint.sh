#!/bin/sh
# Generates /run/keepalived.conf from VRRP_* environment variables and starts
# keepalived with the VRRP subsystem only. A keepalived.conf mounted at
# /etc/keepalived/keepalived.conf takes precedence over the generated one.
set -euf

CUSTOM_CONF=/etc/keepalived/keepalived.conf
GENERATED_CONF=/run/keepalived.conf

log() { echo "entrypoint: $*"; }
die() { echo "entrypoint: ERROR: $*" >&2; exit 1; }

# var NAME -> value of the environment variable NAME (empty if unset)
var() { eval "printf '%s' \"\${$1:-}\""; }

# inst N KEY [DEFAULT] -> VRRP_<N>_<KEY>, else VRRP_<KEY>, else DEFAULT
inst() {
  _v=$(var "VRRP_${1}_${2}")
  [ -n "$_v" ] || _v=$(var "VRRP_${2}")
  printf '%s' "${_v:-${3:-}}"
}

# script N KEY [DEFAULT] -> VRRP_SCRIPT_<N>_<KEY>, else DEFAULT
script() {
  _v=$(var "VRRP_SCRIPT_${1}_${2}")
  printf '%s' "${_v:-${3:-}}"
}

is_int() {
  case "${1#-}" in
    '' | *[!0-9]*) return 1 ;;
  esac
}

# check_int LABEL VALUE MIN MAX
check_int() {
  is_int "$2" && [ "$2" -ge "$3" ] && [ "$2" -le "$4" ] \
    || die "$1 must be an integer between $3 and $4 (got '$2')"
}

check_name() {
  case "$2" in
    '' | *[!A-Za-z0-9_.-]*) die "$1 may only contain A-Z a-z 0-9 _ . - (got '$2')" ;;
  esac
}

is_true() {
  case "$1" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
  esac
  return 1
}

# words "a, b c" -> a b c
words() { printf '%s' "$1" | tr ',' ' '; }

# in_list ITEM LIST...
in_list() {
  _item=$1
  shift
  for _i in "$@"; do
    [ "$_i" = "$_item" ] && return 0
  done
  return 1
}

# count_blocks PREFIX -> number of consecutively numbered blocks PREFIX<n>_*
count_blocks() {
  _n=0
  while env | grep -q "^${1}$((_n + 1))_"; do
    _n=$((_n + 1))
  done
  # A gap in the numbering would silently drop every block behind it
  for _found in $(env | sed -n "s/^${1}\([0-9][0-9]*\)_.*/\1/p" | sort -un); do
    [ "$_found" -le "$_n" ] && [ "$_found" -ge 1 ] \
      || die "${1}${_found}_* is set, but ${1}$((_n + 1))_* is missing; number the blocks consecutively starting at 1"
  done
  echo "$_n"
}

# emit_block KEYWORD "a b c" -> KEYWORD { a b c }, one entry per line
emit_block() {
  echo "    $1 {"
  for _e in $2; do
    echo "        $_e"
  done
  echo "    }"
}

generate_global() {
  echo "global_defs {"
  echo "    router_id ${KEEPALIVED_ROUTER_ID:-$(hostname)}"
  echo "    script_user ${KEEPALIVED_SCRIPT_USER:-root}"
  echo "    enable_script_security"
  echo "}"
}

generate_script() {
  n=$1
  name=$(script "$n" NAME "chk_$n")
  check_name "VRRP_SCRIPT_${n}_NAME" "$name"
  # shellcheck disable=SC2086
  in_list "$name" $SCRIPT_NAMES && die "vrrp_script name '$name' is used more than once"
  SCRIPT_NAMES="$SCRIPT_NAMES $name"

  cmd=$(script "$n" SCRIPT)
  [ -n "$cmd" ] || die "VRRP_SCRIPT_${n}_SCRIPT is required"
  case "$cmd" in
    *\"*) die "VRRP_SCRIPT_${n}_SCRIPT must not contain double quotes; use single quotes or a script file" ;;
  esac

  interval=$(script "$n" INTERVAL 2)
  check_int "VRRP_SCRIPT_${n}_INTERVAL" "$interval" 1 3600

  echo
  echo "vrrp_script $name {"
  echo "    script \"$cmd\""
  echo "    interval $interval"

  timeout=$(script "$n" TIMEOUT)
  if [ -n "$timeout" ]; then
    check_int "VRRP_SCRIPT_${n}_TIMEOUT" "$timeout" 1 3600
    echo "    timeout $timeout"
  fi
  weight=$(script "$n" WEIGHT)
  if [ -n "$weight" ]; then
    check_int "VRRP_SCRIPT_${n}_WEIGHT" "$weight" -253 253
    echo "    weight $weight"
  fi
  fall=$(script "$n" FALL)
  if [ -n "$fall" ]; then
    check_int "VRRP_SCRIPT_${n}_FALL" "$fall" 1 1000
    echo "    fall $fall"
  fi
  rise=$(script "$n" RISE)
  if [ -n "$rise" ]; then
    check_int "VRRP_SCRIPT_${n}_RISE" "$rise" 1 1000
    echo "    rise $rise"
  fi
  user=$(script "$n" USER)
  if [ -n "$user" ]; then
    echo "    user $user"
  fi
  if is_true "$(script "$n" INIT_FAIL)"; then
    echo "    init_fail"
  fi
  echo "}"
}

generate_instance() {
  n=$1
  name=$(var "VRRP_${n}_NAME")
  name=${name:-VI_$n}
  check_name "VRRP_${n}_NAME" "$name"
  # shellcheck disable=SC2086
  in_list "$name" $INSTANCE_NAMES && die "vrrp_instance name '$name' is used more than once"
  INSTANCE_NAMES="$INSTANCE_NAMES $name"

  interface=$(inst "$n" INTERFACE)
  [ -n "$interface" ] || die "VRRP_${n}_INTERFACE (or VRRP_INTERFACE) is required"
  check_name "VRRP_${n}_INTERFACE" "$interface"

  vrid=$(inst "$n" VIRTUAL_ROUTER_ID)
  [ -n "$vrid" ] || die "VRRP_${n}_VIRTUAL_ROUTER_ID is required"
  check_int "VRRP_${n}_VIRTUAL_ROUTER_ID" "$vrid" 1 255
  # shellcheck disable=SC2086
  in_list "$interface/$vrid" $INSTANCE_VRIDS \
    && die "virtual router id $vrid is used more than once on interface $interface"
  INSTANCE_VRIDS="$INSTANCE_VRIDS $interface/$vrid"

  state=$(inst "$n" STATE BACKUP)
  case "$state" in
    MASTER | BACKUP) ;;
    *) die "VRRP_${n}_STATE must be MASTER or BACKUP (got '$state')" ;;
  esac

  priority=$(inst "$n" PRIORITY 100)
  check_int "VRRP_${n}_PRIORITY" "$priority" 1 254

  advert_int=$(inst "$n" ADVERT_INT 1)
  check_int "VRRP_${n}_ADVERT_INT" "$advert_int" 1 255

  vips=$(inst "$n" VIRTUAL_IPS)
  [ -n "$(printf '%s' "$vips" | tr -d ', ')" ] || die "VRRP_${n}_VIRTUAL_IPS is required"

  nopreempt=$(inst "$n" NOPREEMPT)
  if is_true "$nopreempt" && [ "$state" = MASTER ]; then
    die "VRRP_${n}_NOPREEMPT requires VRRP_${n}_STATE=BACKUP"
  fi

  auth_pass=$(inst "$n" AUTH_PASS)
  [ "${#auth_pass}" -le 8 ] || die "VRRP_${n}_AUTH_PASS must not be longer than 8 characters"
  case "$auth_pass" in
    *[[:space:]\"#!]*) die "VRRP_${n}_AUTH_PASS must not contain whitespace, quotes, # or !" ;;
  esac

  track_scripts=$(words "$(inst "$n" TRACK_SCRIPTS)")
  for s in $track_scripts; do
    # shellcheck disable=SC2086
    in_list "$s" $SCRIPT_NAMES \
      || die "VRRP_${n}_TRACK_SCRIPTS references unknown vrrp_script '$s' (defined:${SCRIPT_NAMES:- none})"
  done

  # notify is called on every state change, the others only on their own
  for key in NOTIFY NOTIFY_MASTER NOTIFY_BACKUP NOTIFY_FAULT NOTIFY_STOP; do
    cmd=$(inst "$n" "$key")
    case "$cmd" in
      *\"*) die "VRRP_${n}_${key} must not contain double quotes; use single quotes or a script file" ;;
    esac
    # keepalived only warns about a missing notify script and then skips it
    if [ -n "$cmd" ] && [ ! -x "${cmd%% *}" ]; then
      die "VRRP_${n}_${key}: '${cmd%% *}' does not exist or is not executable"
    fi
  done

  echo
  echo "vrrp_instance $name {"
  echo "    state $state"
  echo "    interface $interface"
  echo "    virtual_router_id $vrid"
  echo "    priority $priority"
  echo "    advert_int $advert_int"
  if is_true "$nopreempt"; then
    echo "    nopreempt"
  fi
  if [ -n "$auth_pass" ]; then
    echo "    authentication {"
    echo "        auth_type PASS"
    echo "        auth_pass $auth_pass"
    echo "    }"
  fi

  unicast_src_ip=$(inst "$n" UNICAST_SRC_IP)
  unicast_peers=$(words "$(inst "$n" UNICAST_PEERS)")
  if [ -n "$unicast_src_ip" ]; then
    echo "    unicast_src_ip $unicast_src_ip"
  fi
  if [ -n "$unicast_peers" ]; then
    emit_block unicast_peer "$unicast_peers"
  fi

  # Entries are comma-separated because one entry may contain spaces
  # (e.g. "192.168.1.100/24 dev eth0 label eth0:vip")
  echo "    virtual_ipaddress {"
  printf '%s\n' "$vips" | tr ',' '\n' | while read -r vip; do
    if [ -n "$vip" ]; then
      echo "        $vip"
    fi
  done
  echo "    }"

  track_interfaces=$(words "$(inst "$n" TRACK_INTERFACES)")
  if [ -n "$track_interfaces" ]; then
    emit_block track_interface "$track_interfaces"
  fi
  if [ -n "$track_scripts" ]; then
    emit_block track_script "$track_scripts"
  fi
  for key in NOTIFY NOTIFY_MASTER NOTIFY_BACKUP NOTIFY_FAULT NOTIFY_STOP; do
    cmd=$(inst "$n" "$key")
    if [ -n "$cmd" ]; then
      echo "    $(printf '%s' "$key" | tr 'A-Z' 'a-z') \"$cmd\""
    fi
  done
  echo "}"
}

generate() {
  echo "# Generated by entrypoint.sh from VRRP_* environment variables"
  generate_global
  i=1
  while [ "$i" -le "$SCRIPT_COUNT" ]; do
    generate_script "$i"
    i=$((i + 1))
  done
  i=1
  while [ "$i" -le "$INSTANCE_COUNT" ]; do
    generate_instance "$i"
    i=$((i + 1))
  done
}

if [ -f "$CUSTOM_CONF" ]; then
  log "using mounted $CUSTOM_CONF, VRRP_* variables are ignored"
  CONF=$CUSTOM_CONF
else
  INSTANCE_COUNT=$(count_blocks VRRP_)
  SCRIPT_COUNT=$(count_blocks VRRP_SCRIPT_)
  [ "$INSTANCE_COUNT" -ge 1 ] \
    || die "no VRRP instance configured; set VRRP_1_* or mount $CUSTOM_CONF"

  SCRIPT_NAMES=""
  INSTANCE_NAMES=""
  INSTANCE_VRIDS=""
  CONF=$GENERATED_CONF
  generate > "$CONF"
  chmod 600 "$CONF"
  log "generated $CONF with $INSTANCE_COUNT VRRP instance(s) and $SCRIPT_COUNT vrrp_script(s)"
fi

keepalived --config-test --use-file "$CONF" \
  || die "keepalived rejected $CONF"

if [ "${1:-}" = "config" ]; then
  # Print the effective configuration without the password and exit
  sed 's/\(auth_pass\) .*/\1 ********/' "$CONF"
  exit 0
fi

# PID files survive a container restart and would block the start
rm -f /run/keepalived.pid /run/vrrp.pid /run/keepalived/keepalived.pid /run/keepalived/vrrp.pid

exec keepalived --dont-fork --log-console --vrrp --use-file "$CONF" "$@"
