#!/bin/bash
# Create the cluster only when every node is empty. If any node already knows a peer
# or owns slots, skip: a running (or half-built) cluster is fixed by hand, never overwritten.
set -o errexit -o nounset -o pipefail

: "${REDIS_NODES:?}" "${HEADLESS_DOMAIN:?}" "${REPLICAS_PER_MASTER:?}"

log() { echo "[cluster-init] $*"; }

addrs=()
for host in $REDIS_NODES; do
    fqdn="$host.$HEADLESS_DOMAIN"
    until [[ $(redis-cli -h "$fqdn" ping 2>/dev/null) == PONG ]]; do
        log "waiting for $fqdn"
        sleep 3
    done

    info=$(redis-cli -h "$fqdn" cluster info | tr -d '\r')
    known=$(awk -F: '$1 == "cluster_known_nodes" {print $2}' <<< "$info")
    assigned=$(awk -F: '$1 == "cluster_slots_assigned" {print $2}' <<< "$info")
    if ((known > 1 || assigned > 0)); then
        log "$host already in a cluster (known_nodes=$known, slots_assigned=$assigned), skipping"
        exit 0
    fi

    # CLUSTER MEET only accepts IPs, not hostnames.
    ip=$(getent ahostsv4 "$fqdn" | awk 'NR==1 {print $1}')
    addrs+=("$ip:6379")
done

log "creating cluster: ${addrs[*]}"
redis-cli --cluster create "${addrs[@]}" --cluster-replicas "$REPLICAS_PER_MASTER" --cluster-yes

until redis-cli -h "${REDIS_NODES%% *}.$HEADLESS_DOMAIN" cluster info | grep -q '^cluster_state:ok'; do
    sleep 2
done
log "cluster_state:ok"
