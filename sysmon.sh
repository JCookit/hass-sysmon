#!/bin/sh
# sysmon.sh v0.33

# Home Assistant configuration defaults (can be overwritten in .config file)
HASS_TOKEN=""
HASS_SERVER="homeassistant.local"
HASS_PORT="8123"
HASS_MQTT_PREFIX="homeassistant"

# MQTT path to publish states
MQTT_PUB_PATH="/home/servers"
MQTT_PUBLISH_PERIOD=20

# name of network interface (e.g. eth0) otherwise first active one will be used
NETWORK_IFACE=""

# debug levels: 0 = DEBUG, 1 = INFO, 2 = WARN, 3 = ERROR
DEBUG_LEVEL=1

# how long to wait for the Home Assistant server to respond (or to sleep if wait not supported)
TIMEOUT_SERVER=1

# sensor config
ENABLE_DISK=1
ENABLE_LOAD=1
ENABLE_MEMORY=1
ENABLE_SWAP=1
ENABLE_DISK=1
ENABLE_WIFI=1
ENABLE_UPTIME=1
ENABLE_TEMPERATURE=1
ENABLE_PING=1
ENABLE_NETWORK=1
ENABLE_TOP_CPU=0
ENABLE_DOCKER_HEALTH=1
ENABLE_PI_HEALTH=0
ENABLE_MIRROR_HEALTH=0
ENABLE_NETWORK_PROBES=0
ENABLE_REBOOT_DIAGNOSTICS=0

METRIC_TIMEOUT_FAST=1
METRIC_TIMEOUT_NORMAL=2
METRIC_TIMEOUT_PROBE=6
SLOW_METRIC_PERIOD=300
SYSMON_PRINT_ONLY=0

CONFIG_PING_HOST="192.168.1.1"
CONFIG_DNS_HOSTS="weather.visualcrossing.com github.com outlook.live.com"
CONFIG_HTTPS_URLS="https://weather.visualcrossing.com/ https://github.com/"
CONFIG_TCP_TARGETS="1.1.1.1:443 8.8.8.8:443 140.82.114.3:443"
CONFIG_GATEWAY_HOST=""
CONFIG_MAGICMIRROR_PM2_NAME="MagicMirror"
CONFIG_MAGICMIRROR_ELECTRON_PATTERN="/home/cookits/MagicMirror/node_modules/electron/dist/electron js/electron.js"
CONFIG_VISION_WORKER_PATTERN="vision-worker.js"
CONFIG_RESIZE_WORKER_PATTERN="resize-worker.js"

CONFIG_TOP_CPU_IGNORE_COMMAND="top"
CONFIG_TOP_CPU_MAX=3

##### Logging functions #####

COLOR_RESET="\033[0m"
COLOR_RED="\033[31;1m"
COLOR_GREEN="\033[32;1m"
COLOR_BLUE="\033[33;1m"
COLOR_GRAY="\033[37;1m"

DOCKER_CONTAINERS="qbittorrentgluetun gluetun sonarr radarr bazarr prowlarr plex overseerr unpackerr flaresolverr watchtower"


docker_health() {
    first=1
    for container in $DOCKER_CONTAINERS; do
        status=$(docker inspect --format '{{.State.Health.Status}}' "$container" 2>/dev/null)
        value="off"
        [ "$status" = "healthy" ] && value="on"

        if [ "$first" -eq 0 ]; then
            echo -n ","
        fi
        print_key_vals "${container}_health" "\"$value\""
        first=0
    done
}

error() {
    if [ $DEBUG_LEVEL -le 3 ]; then
        printf '%b' "${COLOR_RED}ERROR:${COLOR_RESET} $@\n"
    fi
}

warning() {
    if [ $DEBUG_LEVEL -le 2 ]; then
        printf '%b' "${COLOR_BLUE}WARNING:${COLOR_RESET} $@\n"
    fi
}

info() {
    if [ $DEBUG_LEVEL -le 1 ]; then
        printf '%b' "${COLOR_GREEN}INFO:${COLOR_RESET} $@\n"
    fi
}

debug() {
    if [ $DEBUG_LEVEL -le 0 ]; then
        printf '%b' "${COLOR_GRAY}DEBUG:${COLOR_RESET} $@\n"
    fi
}

##### Helper functions #####

cmd_exists() {
  command -v "$1" 2>&1 >/dev/null
}

run_timeout() {
    timeout --kill-after=1 "$@"
}

json_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g; s/\r/ /g; s/\n/ /g'
}

bool_on_off() {
    if [ "$1" = "1" ] || [ "$1" = "true" ] || [ "$1" = "active" ] || [ "$1" = "online" ]; then
        printf "on"
    else
        printf "off"
    fi
}

append_metric() {
    metric_value="$1"

    if [ -z "$metric_value" ]; then
        return
    fi

    if [ -z "$data" ]; then
        data="$metric_value"
    else
        data="${data},$metric_value"
    fi
}

should_run_slow_metrics() {
    if [ "$SLOW_METRIC_PERIOD" -le 0 ]; then
        return 0
    fi

    time_now=$(date +"%s")
    if [ "$time_now" -ge "$time_slow_next" ]; then
        time_slow_next=$(( time_now + SLOW_METRIC_PERIOD ))
        return 0
    fi

    return 1
}

beginswith() {
    case "$2" in "$1"*) true;; *) false;; esac;
}

print_key_vals() {
    echo -n "\"$1\":$2"
    shift 2

    while [ $# -ge 2 ]; do
        echo -n ",\"$1\":$2"
        shift 2
    done
}

print_json() {
    echo -n "{$(print_key_vals "$@")}"
}

deref_path_symlink() {
    echo $(cd "$*" && pwd -P)
}

macid() {
    nic_name=$1

    cat /sys/class/net/$nic_name/address | head -n 1 | sed 's/://g'
}

active_nic() {
    for nic_path in /sys/class/net/*; do
        nic_name=$(basename "$nic_path")
        is_virtual=$(deref_path_symlink "$nic_path" | grep virtual)

        # skip possibly virtual or inactive devices 
        if [ -z "$is_virtual" ] && [ "$(cat $nic_path/operstate)" = "up" ]; then 
            echo "$nic_name"
            return 0
        fi
    done

    return 1
}

temperature_sensor_names() {
    if ! ls /sys/class/thermal/thermal_zone* > /dev/null 2>&1; then
        return
    fi

    for tz in /sys/class/thermal/thermal_zone*; do
        cat "$tz"/type | sed 's/-/_/'
    done
}

##### Sensor functions #####

CPU_COUNT=$(grep -c ^processor /proc/cpuinfo)

avg_load() {
    loadavg=$(cat /proc/loadavg)

    avg_load_1min_pc=$(echo $loadavg | awk '{printf 100 * $1 / '$CPU_COUNT'}')
    avg_load_5min_pc=$(echo $loadavg | awk '{printf 100 * $2 / '$CPU_COUNT'}')
    avg_load_10min_pc=$(echo $loadavg | awk '{printf 100 * $3 / '$CPU_COUNT'}')

    print_key_vals \
        avg_load_1min_pc $avg_load_1min_pc \
        avg_load_5min_pc $avg_load_5min_pc \
        avg_load_10min_pc $avg_load_10min_pc
}

network_rate() {
  now_sec=$(date +"%s")
  RX2=$(awk "/$NETWORK_IFACE:/"'{print $2}' /proc/net/dev)
  TX2=$(awk "/$NETWORK_IFACE:/"'{print $10}' /proc/net/dev)

  if [ -z "$NETWORK_RX_LAST" ] || [ -z "$NETWORK_TX_LAST" ] || [ -z "$NETWORK_TIME_LAST" ]; then
      NETWORK_RX_LAST="$RX2"
      NETWORK_TX_LAST="$TX2"
      NETWORK_TIME_LAST="$now_sec"
      print_key_vals \
          network_up 0 \
          network_down 0
      return
  fi

  elapsed=$(( now_sec - NETWORK_TIME_LAST ))
  [ "$elapsed" -le 0 ] && elapsed=1

  RX_RATE=$(awk "BEGIN {printf \"%.4f\", ($RX2 - $NETWORK_RX_LAST) / $elapsed / 1048576}")
  TX_RATE=$(awk "BEGIN {printf \"%.4f\", ($TX2 - $NETWORK_TX_LAST) / $elapsed / 1048576}")

  NETWORK_RX_LAST="$RX2"
  NETWORK_TX_LAST="$TX2"
  NETWORK_TIME_LAST="$now_sec"

  print_key_vals \
	network_up $TX_RATE \
        network_down $RX_RATE
}

top_cpu() {
    field_ind_to_name="$(top -bn1 | grep -E  '^ +PID' | sed 's/\s\s*/\n/g' |tail -n +2| grep -nx ".*")"

    cpu_ind=$(echo "$field_ind_to_name" | grep "%CPU" | cut -d: -f1)
    command_ind=$(echo "$field_ind_to_name" | grep "COMMAND" | cut -d: -f1)

    # below assumes COMMAND is last column and PID is first
    top_commands=$(top -bn1 | sed -n '/\s*PID.*$/,$p' | tail -n +2 | sed 's/\s\s*/ /g' | sed 's/^\s*//g' | cut -d' ' -f"${cpu_ind},${command_ind}-")

    i=1
    did_print=0

    echo "$top_commands" | while read line; do
        cpu_pc=$(echo $line | cut -d' ' -f1 | awk '{printf $1 / '$CPU_COUNT'}')
        command_name=$(echo $line | cut -d' ' -f2-)

        # ignore given command 
        if [ ! -z "$CONFIG_TOP_CPU_IGNORE_COMMAND" ] && (beginswith "$command_name" "$CONFIG_TOP_CPU_IGNORE_COMMAND"); then
            continue
        fi

        if [ $did_print -eq 1 ]; then
            echo -n ","
        fi
        did_print=1

        print_key_vals \
            "top_${i}_command_name"   "\"$command_name\"" \
            "top_${i}_command_cpu_pc" "$cpu_pc"

        if [ $i -ge $CONFIG_TOP_CPU_MAX ]; then
            return
        fi

        i=$((i+1))
    done
}

uptime_duration() {
    uptime_sec=$(awk '{print $1}' /proc/uptime)

    print_key_vals uptime_sec $uptime_sec
}

disk_usage() {
    root_usage=$(df | grep " /$")

    disk_free_Mb=$(echo $root_usage | awk '{print $4 / 1000}')
    disk_used_pc=$(echo $root_usage | awk '{print 100 * $3 / $2}')

    print_key_vals \
        disk_free_Mb $disk_free_Mb \
        disk_used_pc $disk_used_pc
}

disk_usage_usb() {
    root_usage=$(df | grep " /mnt/usb1$")
    [ -z "$root_usage" ] && return 1

    disk_usb_free_Mb=$(echo $root_usage | awk '{print $4 / 1000}')
    disk_usb_used_pc=$(echo $root_usage | awk '{print 100 * $3 / $2}')

    print_key_vals \
        disk_usb_free_Mb $disk_usb_free_Mb \
        disk_usb_used_pc $disk_usb_used_pc
}

wifi_signal() {
    signal=$(awk '/wlp/ || /wlan0/ { print $0; exit}' /proc/net/wireless)

    wifi_link_pc=$(echo $signal | awk '{printf "%d", $3}')
    wifi_level_dbm=$(echo $signal | awk '{printf "%d", $4}')

    print_key_vals \
        wifi_link_pc $wifi_link_pc \
        wifi_level_dbm $wifi_level_dbm
}

temperature() {
    if ! ls /sys/class/thermal/thermal_zone* > /dev/null 2>&1; then
        return 1
    fi

    sep=""
    for tz in /sys/class/thermal/thermal_zone*; do
        sensor_name="temperature_$(cat $tz/type | sed 's/-/_/')_C"
        temp=$(awk '{printf $1 / 1000}' $tz/temp)

        echo -n "$sep"
        sep=","
        print_key_vals $sensor_name $temp
    done
}

memory_usage() {
    mem=$(cat /proc/meminfo)

    mem_free_kB=$(echo "$mem" | grep MemAvailable | awk '{printf $2}')
    mem_used_pc=$(echo "$mem" | grep MemTotal | awk '{printf 100 * ($2 - '$mem_free_kB') / $2}')

    print_key_vals \
        mem_free_kB $mem_free_kB \
        mem_used_pc $mem_used_pc
}

swap_usage() {
    mem=$(cat /proc/meminfo)

    swap_total_kB=$(echo "$mem" | grep SwapTotal | awk '{printf $2}')

    # check if no swap
    if [ $swap_total_kB -eq 0 ]; then
        return 1
    fi

    swap_free_kB=$(echo "$mem" | grep SwapFree | awk '{printf $2}')
    swap_used_pc=$(echo | awk '{printf 100 * ('$swap_total_kB' - '$swap_free_kB') / '$swap_total_kB'}') 

    print_key_vals \
        swap_free_kB $swap_free_kB \
        swap_used_pc $swap_used_pc
}

host_name() {
    print_key_vals host_name \"$(cat /proc/sys/kernel/hostname)\"
}

ping_host() {
    result="$(ping $CONFIG_PING_HOST -q -c 1 -W 1)"
    retval=$?

    if ! [ $retval -eq 0 ]; then
        info ping $CONFIG_PING_HOST failed: $(echo "$result" | tail -n 1)
        return 1
    fi

    rtt=$(echo $result | tail -n 1 | cut -d= -f2 | cut -d\/ -f 1 | tr -d ' ')
    print_key_vals ping_rtt_ms $rtt
}

pi_health() {
    throttled_raw="unknown"
    throttled_num=0
    if cmd_exists vcgencmd; then
        throttled_raw=$(run_timeout "$METRIC_TIMEOUT_FAST" vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
        [ -z "$throttled_raw" ] && throttled_raw="unknown"
    fi

    case "$throttled_raw" in
        0x*) throttled_num=$((throttled_raw)) ;;
        *) throttled_num=0 ;;
    esac

    watchdog_state="unknown"
    if cmd_exists systemctl; then
        watchdog_state=$(run_timeout "$METRIC_TIMEOUT_FAST" systemctl is-active watchdog 2>/dev/null || true)
        [ -z "$watchdog_state" ] && watchdog_state="unknown"
    fi

    watchdog_bootstatus=""
    [ -r /sys/class/watchdog/watchdog0/bootstatus ] && watchdog_bootstatus=$(cat /sys/class/watchdog/watchdog0/bootstatus 2>/dev/null)
    [ -z "$watchdog_bootstatus" ] && watchdog_bootstatus="-1"

    print_key_vals \
        pi_throttled_raw "\"$(json_string "$throttled_raw")\"" \
        pi_under_voltage_now "\"$(bool_on_off $(( (throttled_num & 1) != 0 )) )\"" \
        pi_freq_capped_now "\"$(bool_on_off $(( (throttled_num & 2) != 0 )) )\"" \
        pi_throttled_now "\"$(bool_on_off $(( (throttled_num & 4) != 0 )) )\"" \
        pi_soft_temp_limit_now "\"$(bool_on_off $(( (throttled_num & 8) != 0 )) )\"" \
        pi_under_voltage_seen "\"$(bool_on_off $(( (throttled_num & 65536) != 0 )) )\"" \
        pi_throttled_seen "\"$(bool_on_off $(( (throttled_num & 262144) != 0 )) )\"" \
        watchdog_active "\"$(bool_on_off "$watchdog_state")\"" \
        watchdog_bootstatus "$watchdog_bootstatus"
}

electron_memory() {
    pid=$(pgrep -f "$CONFIG_MAGICMIRROR_ELECTRON_PATTERN" | head -n 1)
    if [ -z "$pid" ] || [ ! -r "/proc/$pid/status" ]; then
        print_key_vals \
            electron_present "\"off\"" \
            electron_rss_mb 0 \
            electron_anon_mb 0
        return
    fi

    rss_kb=$(awk '/^VmRSS:/ {print $2}' "/proc/$pid/status")
    anon_kb=$(awk '/^RssAnon:/ {print $2}' "/proc/$pid/status")
    rss_mb=$(( (rss_kb + 1023) / 1024 ))
    anon_mb=$(( (anon_kb + 1023) / 1024 ))

    print_key_vals \
        electron_present "\"on\"" \
        electron_pid "$pid" \
        electron_rss_mb "$rss_mb" \
        electron_anon_mb "$anon_mb"
}

mirror_health() {
    pm2_status="unknown"
    pm2_restarts=0
    pm2_memory_mb=0

    if cmd_exists pm2 && cmd_exists node; then
        pm2_json=$(run_timeout "$METRIC_TIMEOUT_NORMAL" pm2 jlist 2>/dev/null || true)
        if [ -n "$pm2_json" ]; then
            pm2_line=$(printf '%s' "$pm2_json" | SYSMON_PM2_NAME="$CONFIG_MAGICMIRROR_PM2_NAME" node -e '
let s = "";
process.stdin.on("data", d => s += d).on("end", () => {
  try {
    const name = process.env.SYSMON_PM2_NAME;
    const p = JSON.parse(s).find(x => x && x.name === name);
    if (!p) return;
    const env = p.pm2_env || {};
    const monit = p.monit || {};
    console.log([
      env.status || "unknown",
      env.restart_time || 0,
      Math.round((monit.memory || 0) / 1048576)
    ].join(" "));
  } catch {}
});' 2>/dev/null)
            if [ -n "$pm2_line" ]; then
                pm2_status=$(echo "$pm2_line" | awk '{print $1}')
                pm2_restarts=$(echo "$pm2_line" | awk '{print $2}')
                pm2_memory_mb=$(echo "$pm2_line" | awk '{print $3}')
            fi
        fi
    fi

    vision_present="off"
    resize_present="off"
    pgrep -f "$CONFIG_VISION_WORKER_PATTERN" >/dev/null 2>&1 && vision_present="on"
    pgrep -f "$CONFIG_RESIZE_WORKER_PATTERN" >/dev/null 2>&1 && resize_present="on"

    mirror_data=$(print_key_vals \
        magicmirror_online "\"$(bool_on_off "$pm2_status")\"" \
        magicmirror_pm2_status "\"$(json_string "$pm2_status")\"" \
        magicmirror_pm2_restarts "$pm2_restarts" \
        magicmirror_pm2_memory_mb "$pm2_memory_mb" \
        vision_worker_present "\"$vision_present\"" \
        resize_worker_present "\"$resize_present\"")
    electron_data=$(electron_memory)
    printf "%s,%s" "$mirror_data" "$electron_data"
}

default_gateway() {
    if [ -n "$CONFIG_GATEWAY_HOST" ]; then
        printf "%s" "$CONFIG_GATEWAY_HOST"
        return
    fi

    ip route 2>/dev/null | awk '/^default / {print $3; exit}'
}

tcp_probe_summary() {
    tmpdir=$(mktemp -d 2>/dev/null) || return 1

    for target in $CONFIG_TCP_TARGETS; do
        host=${target%:*}
        port=${target#*:}
        (
            run_timeout 2 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1
            printf "%s:%s " "$target" "$?"
        ) >"$tmpdir/$host-$port" &
    done

    wait

    for target in $CONFIG_TCP_TARGETS; do
        host=${target%:*}
        port=${target#*:}
        cat "$tmpdir/$host-$port" 2>/dev/null
    done

    rm -rf "$tmpdir"
}

network_probes() {
    gateway=$(default_gateway)
    gateway_rc=1
    dns_rc=1
    https_rc=1
    dns_good=""
    https_good=""

    if [ -n "$gateway" ]; then
        run_timeout 2 ping -c 1 -W 1 "$gateway" >/dev/null 2>&1
        gateway_rc=$?
    fi

    for host in $CONFIG_DNS_HOSTS; do
        run_timeout 2 getent hosts "$host" >/dev/null 2>&1
        dns_rc=$?
        if [ "$dns_rc" -eq 0 ]; then
            dns_good="$host"
            break
        fi
    done

    for url in $CONFIG_HTTPS_URLS; do
        run_timeout "$METRIC_TIMEOUT_PROBE" curl --silent --show-error --fail --location --head --max-time 4 --connect-timeout 2 "$url" >/dev/null 2>&1
        https_rc=$?
        if [ "$https_rc" -eq 0 ]; then
            https_good="$url"
            break
        fi
    done

    tcp_summary=$(tcp_probe_summary)
    network_probe_ok="off"
    [ "$gateway_rc" -eq 0 ] && [ "$dns_rc" -eq 0 ] && [ "$https_rc" -eq 0 ] && network_probe_ok="on"

    print_key_vals \
        network_probe_ok "\"$network_probe_ok\"" \
        network_gateway_ping_ok "\"$(bool_on_off $([ "$gateway_rc" -eq 0 ] && echo 1 || echo 0))\"" \
        network_dns_ok "\"$(bool_on_off $([ "$dns_rc" -eq 0 ] && echo 1 || echo 0))\"" \
        network_https_ok "\"$(bool_on_off $([ "$https_rc" -eq 0 ] && echo 1 || echo 0))\"" \
        network_gateway "\"$(json_string "$gateway")\"" \
        network_dns_good_host "\"$(json_string "$dns_good")\"" \
        network_https_good_url "\"$(json_string "$https_good")\"" \
        network_tcp_summary "\"$(json_string "$tcp_summary")\""
}

reboot_diagnostics() {
    boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
    boot_time=$(who -b 2>/dev/null | awk '{print $3" "$4}')
    prev_last=$(run_timeout "$METRIC_TIMEOUT_NORMAL" journalctl -b -1 -n 1 --no-pager -o short-iso 2>/dev/null | cut -c1-32)
    pstore_count=$(find /sys/fs/pstore /var/lib/systemd/pstore -maxdepth 1 -type f 2>/dev/null | wc -l | awk '{print $1}')
    pstore_bytes=$(find /sys/fs/pstore /var/lib/systemd/pstore -maxdepth 1 -type f -printf '%s\n' 2>/dev/null | awk '{s += $1} END {print s + 0}')
    clean_shutdown="off"
    run_timeout "$METRIC_TIMEOUT_NORMAL" journalctl -b -1 --no-pager 2>/dev/null | tail -50 | grep -Eq 'Reached target .*Shutdown|System will reboot|systemd-shutdown' && clean_shutdown="on"

    print_key_vals \
        boot_id "\"$(json_string "$boot_id")\"" \
        boot_time "\"$(json_string "$boot_time")\"" \
        previous_boot_last_log "\"$(json_string "$prev_last")\"" \
        previous_boot_clean "\"$clean_shutdown\"" \
        pstore_record_count "$pstore_count" \
        pstore_total_bytes "$pstore_bytes"
}

##### Core network functions #####

HTTP_HEADER_CTYPE="Content-Type: application/json"

HTTP_PATH_SENSOR="/api/states/sensor"
HTTP_PATH_MQTT="/api/services/mqtt/publish"

post_json_message_curl() {
    path="$1"
    json="$2"

    url="http://${HASS_SERVER}:${HASS_PORT}${path}"

    response=$(curl -m $TIMEOUT_SERVER -s -X POST -w "\\n%{http_code}\\n" -H "$HTTP_HEADER_AUTH" -H "$HTTP_HEADER_CTYPE" -d "$json" "$url")
    http_code=$(echo "$response" | tail -n 1)

    if [ "$http_code" != "200" ]; then
        debug "sent JSON: $json"
        error "received HTTP code $http_code, full response:"
        printf '%b' "$response" | head -n-1
    else
        debug "message receipt confirmed"
    fi
}

post_json_message_netcat() {
    path="$1"
    json="$2"

    data="POST $path HTTP/1.1\r
$HTTP_HEADER_AUTH\r
$HTTP_HEADER_CTYPE\r
Content-Length: ${#json}\r
\r
"
    data="${data}${json}"

    response=$(printf '%b' "$data" | eval "$NETCAT_CMD $HASS_SERVER $HASS_PORT" 2>&1)
    sleep $TIMEOUT_SERVER

    http_code=$(echo "$response" | awk '/^HTTP/{print $2; exit}')

    if [ ! $http_code ]; then
        info "message receipt not confirmed"
        return
    fi

    if [ "$http_code" != "200" ]; then
        debug "sent JSON: $json"
        error "received HTTP code $http_code, full response:"
        printf '%b' "$response"
    else
        debug "message receipt confirmed"
    fi
}

##### Network helper functions #####

post_json_message() {
    if [ $HAS_CURL -eq 1 ]; then
        post_json_message_curl "$1" "$2"
    else
        post_json_message_netcat "$1" "$2"
    fi
}

post_sensor_state() {
    path="$HTTP_PATH_SENSOR.$1"
    json="$2"

    post_json_message "$path" "$json"
}

post_mqtt() {
    topic="$1"
    json_str=$(echo "$2" | sed 's/"/\\"/g')
    msg=$(print_json topic \"$topic\" payload "\"$json_str\"" retain true)

    post_json_message "$HTTP_PATH_MQTT" "$msg"
}

##### Auto-discovery and state publishing functions #####

publish_state_loop() {
    info "publishing state to topic $STATE_TOPIC every $MQTT_PUBLISH_PERIOD s"

    time_pub_next=$(date +"%s")
    time_slow_next=0

    while true
    do
        time_now=$(date +"%s")
        time_sleep=$(( $time_pub_next - $time_now ))

        if [ $time_sleep -gt 0 ]; then
            debug "sleeping for $time_sleep s"
            sleep $time_sleep
        fi

        time_pub_next=$(( $time_pub_next + $MQTT_PUBLISH_PERIOD))
        run_slow=0
        should_run_slow_metrics && run_slow=1

        data="$(host_name)"
        [ $ENABLE_MEMORY      -eq 1 ] && val=$(memory_usage)       && append_metric "$val"
        [ $ENABLE_SWAP        -eq 1 ] && val=$(swap_usage)         && append_metric "$val"
        [ $ENABLE_DISK        -eq 1 ] && val=$(disk_usage)         && append_metric "$val"
        [ $ENABLE_DISK        -eq 1 ] && val=$(disk_usage_usb)     && append_metric "$val"
        [ $ENABLE_LOAD        -eq 1 ] && val=$(avg_load)           && append_metric "$val"
        [ $ENABLE_WIFI        -eq 1 ] && val=$(wifi_signal)        && append_metric "$val"
        [ $ENABLE_UPTIME      -eq 1 ] && val=$(uptime_duration)    && append_metric "$val"
        [ $ENABLE_PING        -eq 1 ] && val=$(ping_host)          && append_metric "$val"
        [ $ENABLE_TEMPERATURE -eq 1 ] && val=$(temperature)        && append_metric "$val"
        [ $ENABLE_TOP_CPU     -eq 1 ] && val=$(top_cpu)            && append_metric "$val"
        [ $ENABLE_NETWORK     -eq 1 ] && val=$(network_rate)       && append_metric "$val"
	[ $ENABLE_DOCKER_HEALTH -eq 1 ] && val=$(docker_health)    && append_metric "$val"
        [ $ENABLE_PI_HEALTH   -eq 1 ] && val=$(pi_health)          && append_metric "$val"
        [ $ENABLE_MIRROR_HEALTH -eq 1 ] && val=$(mirror_health)    && append_metric "$val"
        [ $ENABLE_NETWORK_PROBES -eq 1 ] && val=$(network_probes)  && append_metric "$val"
        [ $ENABLE_REBOOT_DIAGNOSTICS -eq 1 ] && [ "$run_slow" -eq 1 ] && val=$(reboot_diagnostics) && append_metric "$val"

        json="{${data}}"

        if [ "$SYSMON_PRINT_ONLY" -eq 1 ]; then
            debug "print-only mode, not publishing state message"
        else
            debug "publishing state message"
            post_mqtt "$STATE_TOPIC" "$json"
        fi

        if [ "$RUN_ONCE" -eq 1 ]; then
            printf '%s\n' "$json"
            return
        fi

    done
}

publish_discovery_binary_sensor() {
    param="$1"
    name="$2"
    device_class="$3"

    config_topic="$HASS_MQTT_PREFIX/binary_sensor/$DEVICE_NAME/$param/config"

    device_name="System statistics $DEVICE_NAME"
    version="$(uname -a)"
    device=$(print_json identifiers '["'"$DEVICE_NAME"'"]' name "\"$device_name\"" sw_version "\"$version\"")

    msg=$(print_key_vals name "\"$name\"")
    msg=$msg,$(print_key_vals state_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals json_attributes_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals expire_after \"$((5 * $MQTT_PUBLISH_PERIOD))\")
    msg=$msg,$(print_key_vals value_template "\"{{ value_json.${param} }}\"")
    msg=$msg,$(print_key_vals unique_id \"$DEVICE_NAME-$param\")
    msg=$msg,$(print_key_vals device "$device")
    msg=$msg,$(print_key_vals payload_on \"on\")
    msg=$msg,$(print_key_vals payload_off \"off\")
    [ $device_class ] && msg="$msg,$(print_key_vals device_class \"$device_class\")"

    msg={$msg}

    debug "sending discovery message for binary_sensor $param"
    post_mqtt "$config_topic" "$msg"
}


publish_discovery_sensor() {
    param="$1"
    name="$2"
    unit_of_measurement="$3"
    device_class="$4"

    config_topic="$HASS_MQTT_PREFIX/sensor/$DEVICE_NAME/$param/config"

    device_name="System statistics $DEVICE_NAME"
    version="$(uname -a)"
    device=$(print_json identifiers '["'"$DEVICE_NAME"'"]' name "\"$device_name\"" sw_version "\"$version\"")

    msg=$(print_key_vals name "\"$name\"")
    msg=$msg,$(print_key_vals state_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals json_attributes_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals expire_after \"$((5 * $MQTT_PUBLISH_PERIOD))\")
    msg=$msg,$(print_key_vals value_template "\"{{ value_json.${param} }}\"")
    msg=$msg,$(print_key_vals unique_id \"$DEVICE_NAME-$param\")
    msg=$msg,$(print_key_vals device "$device")
    [ $device_class ]        && msg="$msg,$(print_key_vals device_class \"$device_class\")"
    [ $unit_of_measurement ] && msg=$msg,$(print_key_vals unit_of_measurement \"$unit_of_measurement\")

    msg={$msg}

    debug "sending discovery message for state $param"
    post_mqtt "$config_topic" "$msg"

}

publish_discovery_all() {
    info "sending discovery messages"

    [ $ENABLE_UPTIME -eq 1 ] && publish_discovery_sensor uptime_sec "Uptime" "s" "duration"

    [ $ENABLE_PING   -eq 1 ] && publish_discovery_sensor ping_rtt_ms "Ping RTT" "ms" "duration"    

    [ $ENABLE_LOAD   -eq 1 ] && publish_discovery_sensor avg_load_1min_pc "CPU load (1 min avg)" "%"
    [ $ENABLE_LOAD   -eq 1 ] && publish_discovery_sensor avg_load_5min_pc "CPU load (5 min avg)" "%"
    [ $ENABLE_LOAD   -eq 1 ] && publish_discovery_sensor avg_load_10min_pc "CPU load (10 min avg)" "%"

    [ $ENABLE_MEMORY -eq 1 ] && publish_discovery_sensor mem_free_kB "Memory free" "kB"
    [ $ENABLE_MEMORY -eq 1 ] && publish_discovery_sensor mem_used_pc "Memory used" "%"

    [ $ENABLE_SWAP   -eq 1 ] && publish_discovery_sensor swap_free_kB "Swap free" "kB"
    [ $ENABLE_SWAP   -eq 1 ] && publish_discovery_sensor swap_used_pc "Swap used" "%"

    [ $ENABLE_WIFI   -eq 1 ] && publish_discovery_sensor wifi_link_pc "WiFi link" "%"
    [ $ENABLE_WIFI   -eq 1 ] && publish_discovery_sensor wifi_level_dbm "WiFi level" "dBm" "signal_strength"

    [ $ENABLE_NETWORK -eq 1 ] && publish_discovery_sensor network_up "Network up" "MB/s" 
    [ $ENABLE_NETWORK -eq 1 ] && publish_discovery_sensor network_down "Network down" "MB/s"

    [ $ENABLE_DISK   -eq 1 ] && publish_discovery_sensor disk_free_Mb "Disk free" "MB"
    [ $ENABLE_DISK   -eq 1 ] && publish_discovery_sensor disk_used_pc "Disk used" "%"
    [ $ENABLE_DISK   -eq 1 ] && publish_discovery_sensor disk_usb_free_Mb "Disk USB free" "MB"
    [ $ENABLE_DISK   -eq 1 ] && publish_discovery_sensor disk_usb_used_pc "Disk USB used" "%"

    if [ "$ENABLE_DOCKER_HEALTH" -eq 1 ]; then
        for container in $DOCKER_CONTAINERS; do
            param="${container}_health"
            name="$(printf '%s' "$container" | cut -c1 | tr '[:lower:]' '[:upper:]')$(printf '%s' "$container" | cut -c2- ) Health"
            publish_discovery_binary_sensor "$param" "$name" "connectivity"
        done
    fi

    if [ $ENABLE_TOP_CPU -eq 1 ]; then
        i=1
        while [ $i -le $CONFIG_TOP_CPU_MAX ]; do
            publish_discovery_sensor top_${i}_command_cpu_pc "Top $i command CPU load" "%"
            publish_discovery_sensor top_${i}_command_name "Top $i command name" ""

            i=$(($i+1))
        done
    fi

    if [ $ENABLE_TEMPERATURE -eq 1 ]; then
        for sensor_name in $(temperature_sensor_names); do        
            var_name="temperature_${sensor_name}_C"
            sensor_name=$(echo $sensor_name | sed 's/_temp$//' | sed 's/_/ /')

            publish_discovery_sensor $var_name "Temperature $sensor_name" "°C" "temperature"
        done
    fi

    if [ $ENABLE_PI_HEALTH -eq 1 ]; then
        publish_discovery_sensor pi_throttled_raw "Pi throttled raw" ""
        publish_discovery_binary_sensor pi_under_voltage_now "Pi undervoltage now" "problem"
        publish_discovery_binary_sensor pi_freq_capped_now "Pi frequency capped now" "problem"
        publish_discovery_binary_sensor pi_throttled_now "Pi throttled now" "problem"
        publish_discovery_binary_sensor pi_soft_temp_limit_now "Pi soft temperature limit now" "problem"
        publish_discovery_binary_sensor pi_under_voltage_seen "Pi undervoltage seen" "problem"
        publish_discovery_binary_sensor pi_throttled_seen "Pi throttled seen" "problem"
        publish_discovery_binary_sensor watchdog_active "Watchdog active" "running"
        publish_discovery_sensor watchdog_bootstatus "Watchdog bootstatus" ""
    fi

    if [ $ENABLE_MIRROR_HEALTH -eq 1 ]; then
        publish_discovery_binary_sensor magicmirror_online "MagicMirror online" "running"
        publish_discovery_sensor magicmirror_pm2_status "MagicMirror PM2 status" ""
        publish_discovery_sensor magicmirror_pm2_restarts "MagicMirror PM2 restarts" ""
        publish_discovery_sensor magicmirror_pm2_memory_mb "MagicMirror PM2 memory" "MB"
        publish_discovery_binary_sensor electron_present "Electron present" "running"
        publish_discovery_sensor electron_pid "Electron PID" ""
        publish_discovery_sensor electron_rss_mb "Electron RSS" "MB"
        publish_discovery_sensor electron_anon_mb "Electron anonymous RSS" "MB"
        publish_discovery_binary_sensor vision_worker_present "Vision worker present" "running"
        publish_discovery_binary_sensor resize_worker_present "Resize worker present" "running"
    fi

    if [ $ENABLE_NETWORK_PROBES -eq 1 ]; then
        publish_discovery_binary_sensor network_probe_ok "Network probe OK" "connectivity"
        publish_discovery_binary_sensor network_gateway_ping_ok "Gateway ping OK" "connectivity"
        publish_discovery_binary_sensor network_dns_ok "DNS OK" "connectivity"
        publish_discovery_binary_sensor network_https_ok "HTTPS OK" "connectivity"
        publish_discovery_sensor network_gateway "Network gateway" ""
        publish_discovery_sensor network_dns_good_host "DNS good host" ""
        publish_discovery_sensor network_https_good_url "HTTPS good URL" ""
        publish_discovery_sensor network_tcp_summary "TCP probe summary" ""
    fi

    if [ $ENABLE_REBOOT_DIAGNOSTICS -eq 1 ]; then
        publish_discovery_sensor boot_id "Boot ID" ""
        publish_discovery_sensor boot_time "Boot time" ""
        publish_discovery_sensor previous_boot_last_log "Previous boot last log" ""
        publish_discovery_binary_sensor previous_boot_clean "Previous boot clean" ""
        publish_discovery_sensor pstore_record_count "Pstore record count" ""
        publish_discovery_sensor pstore_total_bytes "Pstore total bytes" "B"
    fi
}

##### main #####

setup() {
    config_file_name="$(basename $0 .sh).config"
    config_path_full="${PATH_CONFIG}/${config_file_name}"

    if [ -f "$config_path_full" ]; then
        info "loading config from $config_path_full"
        . "$config_path_full"
    fi

    # need to set this here in case token gets loaded from file
    HTTP_HEADER_AUTH="Authorization: Bearer $HASS_TOKEN"

    if cmd_exists curl; then
        HAS_CURL=1
        debug  "using curl"
        return 0
    elif cmd_exists netcat; then
        HAS_NETCAT=1
        NETCAT_CMD="netcat"
        debug "using netcat"
    elif cmd_exists nc; then
        HAS_NETCAT=1
        NETCAT_CMD="nc"
        debug "using nc"
    else
        error "missing curl and netcat/nc, please install one"
        exit 1
    fi

    if ( $NETCAT_CMD 2>&1 | grep "\-w" > /dev/null ); then
        debug "netcat supports delay parameter"
        NETCAT_CMD="$NETCAT_CMD -w $TIMEOUT_SERVER"
        TIMEOUT_SERVER=0
    else
        warning "netcat does not support delay parameter (-w), messages may not be reliably sent and confirmed"
        HAS_NETCAT_BASIC=1
    fi
}

start() {
    HAS_CURL=0
    HAS_NETCAT=0
    HAS_NETCAT_BASIC=0
    NETCAT_CMD="netcat"

    # figure out MAC address on given interface, or first active one found
    [ -z "$NETWORK_IFACE" ] && NETWORK_IFACE=$(active_nic)
    MAC_ID="$(macid $NETWORK_IFACE)"
    if [ -z "$MAC_ID" ]; then
        error "couldn't determine MAC address, is interface up?"
        exit 1
    fi

    DEVICE_NAME="$MAC_ID-$(cat /proc/sys/kernel/hostname)"
    STATE_TOPIC="$MQTT_PUB_PATH/$DEVICE_NAME/state"

    info "using device name: $DEVICE_NAME"

    setup
    if [ "$SYSMON_PRINT_ONLY" -eq 1 ]; then
        info "print-only mode, skipping discovery"
    else
        publish_discovery_all

        # HACK: send discovery twice to improve chances with basic netcat
        if [ $HAS_NETCAT_BASIC -eq 1 ]; then
            info "discovery messages may not have been delivered, resending"
            publish_discovery_all
        fi
    fi

    publish_state_loop
}

RUN_ONCE=0

# determine where to load config -- first parameter or script directory
if [ "$1" = "--once" ]; then
    RUN_ONCE=1
    SYSMON_PRINT_ONLY=1
    shift
fi

if [ ! -z "$1" ]; then
    PATH_CONFIG="$1"
else
    PATH_CONFIG="$(dirname $0)"
fi

start
