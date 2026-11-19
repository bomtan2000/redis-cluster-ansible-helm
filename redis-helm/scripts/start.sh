#!/bin/bash
# Sync the IPs in nodes.conf with the current pod IPs, then run the bitnami entrypoint.
#
# Redis only re-learns its own IP when it receives a MEET. After a pod restart with a new
# IP, the "myself" line in nodes.conf still holds the old IP and the node advertises a
# dead address to clients (Lettuce times out on ~1/3 of keys) while cluster_state stays ok.
# This script:
#   1. writes the real IP into the myself line and runs with --cluster-announce-ip $POD_IP;
#   2. replaces old peer IPs with new ones (resolved via the headless DNS), using the
#      host -> IP map saved on the previous start. Needed when the whole cluster restarts
#      at once (node reboot) and every pod gets a new IP, otherwise no node finds the others.
set -o errexit -o nounset -o pipefail

: "${POD_IP:?}" "${REDIS_NODES:?}" "${HEADLESS_DOMAIN:?}"
data_dir="${REDIS_DATA_DIR:-/bitnami/redis/data}"
nodes_conf="$data_dir/nodes.conf"
ip_map="$data_dir/nodes.ips"
dns_wait="${DNS_WAIT_SECONDS:-60}"

log() { echo "[start.sh] $*"; }

declare -A old_ip=() new_ip=()
if [[ -f $ip_map ]]; then
    while read -r host ip; do
        [[ -n $host && -n $ip ]] && old_ip[$host]=$ip
    done < "$ip_map"
fi

new_ip[$HOSTNAME]=$POD_IP
deadline=$((SECONDS + dns_wait))
for host in $REDIS_NODES; do
    [[ $host == "$HOSTNAME" ]] && continue
    ip=""
    until ip=$(getent ahostsv4 "$host.$HEADLESS_DOMAIN" | awk 'NR==1 {print $1}') && [[ -n $ip ]]; do
        ((SECONDS >= deadline)) && break
        sleep 2
    done
    if [[ -n $ip ]]; then
        new_ip[$host]=$ip
    elif [[ -n ${old_ip[$host]:-} ]]; then
        log "cannot resolve $host, keeping old IP ${old_ip[$host]}"
        new_ip[$host]=${old_ip[$host]}
    else
        log "cannot resolve $host"
    fi
done

if [[ -f $nodes_conf ]]; then
    pairs=""
    for host in "${!old_ip[@]}"; do
        old=${old_ip[$host]} new=${new_ip[$host]:-}
        [[ -n $new && $old != "$new" ]] && pairs+="$old $new "
    done

    # Column 2 is ip:port@cport[,hostname,...]; rewrite every node in one awk pass
    # so two pods that swapped IPs with each other are still handled correctly.
    tmp=$(mktemp "$data_dir/nodes.conf.XXXXXX")
    awk -v self="$POD_IP" -v pairs="$pairs" '
        BEGIN { n = split(pairs, a, " "); for (i = 1; i < n; i += 2) m[a[i]] = a[i + 1] }
        $1 == "vars" || NF < 3 { print; next }
        {
            ip = substr($2, 1, index($2, ":") - 1)
            rest = substr($2, length(ip) + 1)
            if ($3 ~ /(^|,)myself(,|$)/) ip = self
            else if (ip in m) ip = m[ip]
            $2 = ip rest
            print
        }' "$nodes_conf" > "$tmp"

    if cmp -s "$nodes_conf" "$tmp"; then
        rm -f "$tmp"
    else
        log "updating IPs in nodes.conf:"
        diff "$nodes_conf" "$tmp" | grep '^[<>]' | awk '{print "  " $1, $3, $4}' || true
        cp -p "$nodes_conf" "$nodes_conf.bak"
        mv "$tmp" "$nodes_conf"
    fi
fi

tmp=$(mktemp "$data_dir/nodes.ips.XXXXXX")
for host in "${!new_ip[@]}"; do
    echo "$host ${new_ip[$host]}"
done | sort > "$tmp"
mv "$tmp" "$ip_map"

exec /opt/bitnami/scripts/redis/entrypoint.sh /opt/bitnami/scripts/redis/run.sh \
    --cluster-announce-ip "$POD_IP" "$@"
