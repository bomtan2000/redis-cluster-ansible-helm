# redis-cluster (Helm)

Redis Cluster with 6 pods (3 masters + 3 replicas) on the `bitnami/redis` image. Rewritten
from a manifest that was running in production (installed with `kubectl apply`, not Helm),
so it can **adopt** the live StatefulSet without touching its PVCs.

Why it exists and what it changes: see the [top-level README](../README.md#2-helm-chart-kubernetes).

Resource names and immutable fields (`selector`, `serviceName`, `volumeClaimTemplates`) are kept
identical to the old manifest. That is what lets Helm adopt the StatefulSet.

## Run

```bash
export NS=app
cd redis-helm
```

### 0. Hotfix without a restart (optional)

```bash
# tell the cluster about the node's real IP
kubectl -n $NS exec redis-0 -- redis-cli cluster meet 10.244.0.30 6379
kubectl -n $NS exec redis-4 -- redis-cli cluster nodes | grep myself   # must show 10.244.0.30
```

### 1. Backup

```bash
mkdir -p backup
kubectl -n $NS get sts/redis svc/redis svc/redis-headless cm/redis-cluster-config -o yaml > backup/redis-live.yaml
for i in 0 1 2 3 4 5; do kubectl -n $NS exec redis-$i -- cat /bitnami/redis/data/nodes.conf > backup/nodes-$i.conf; done
```

### 2. Preview the change

```bash
helm template redis . -n $NS | kubectl -n $NS diff -f -
```

Expected diff only: StatefulSet `command`, env, `scripts` volume and `enableServiceLinks`;
`maxmemory` moved from `REDIS_EXTRA_FLAGS` into `redis.conf`; new PDB; new ConfigMap
`redis-scripts`. `volumeClaimTemplates` and the Services must **not** change.

### 3. Let Helm take ownership of the existing objects

```bash
for r in sts/redis svc/redis svc/redis-headless cm/redis-cluster-config; do
  kubectl -n $NS label    $r app.kubernetes.io/managed-by=Helm --overwrite
  kubectl -n $NS annotate $r meta.helm.sh/release-name=redis meta.helm.sh/release-namespace=$NS --overwrite
done
```

### 4. Install

```bash
helm install redis . -n $NS
kubectl -n $NS rollout status sts/redis --timeout=15m
```

The StatefulSet restarts pods one by one from redis-5 down to redis-0. When a master restarts,
its replica is promoted after `cluster-node-timeout` (5 s). Clients see short errors on that
master's slots, so do it off-peak. The `cluster-init` Job logs `already in a cluster, skipping`.

### 5. Verify

```bash
for i in 0 1 2 3 4 5; do
  echo "== redis-$i $(kubectl -n $NS get pod redis-$i -o jsonpath='{.status.podIP}')"
  kubectl -n $NS exec redis-$i -- redis-cli cluster nodes | awk '/myself/ {print "myself:", $2}'
  kubectl -n $NS exec redis-$i -- redis-cli cluster info | grep cluster_state
done
kubectl -n $NS logs redis-4 | grep start.sh
# application side: "Unable to connect to [<old-ip>" must stop appearing
kubectl -n $NS logs deploy/<your-app> --since=10m | grep -c 'Unable to connect'
```

Self-healing test: `kubectl -n $NS delete pod redis-4`. Once it is back with a new IP, its
`myself` line must show the new IP, and every other node must see the new IP in `cluster nodes`.

### Rollback

```bash
kubectl -n $NS rollout undo sts/redis          # previous pod template, rolling restart
kubectl -n $NS rollout status sts/redis
```

Do **not** use `helm uninstall`: it deletes the StatefulSet and takes all 6 pods down at once
(PVCs survive, but the outage does not).

## Notes

- `persistence.size` / `storageClass` cannot change after creation (`volumeClaimTemplates` is immutable).
- On OpenShift the pod runs with a random UID from the SCC, so `securityContext` is left empty.
- The cluster runs without a password (`ALLOW_EMPTY_PASSWORD=yes`), the same as the cluster it
  adopted. Only acceptable behind a NetworkPolicy. Adding `requirepass` is in Next steps.
