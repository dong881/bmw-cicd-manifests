## Automatic Deployment Scripts

- [x] OAI gNB from public repo
- [x] OAI gNB from local repo
- [x] Helm Charts

### Requirements

1. OAI
- Whereabouts CNI
- ...

## worker-rt lab: OAI CN + NFAPI split gNB (PNF/VNF) + RFsim UE (step-by-step)

This section documents the verified flow on `worker-rt`:
- Namespace **`oai-cn`**: OAI 5GC (AMF/SMF/UPF/...)
- Namespace **`oai-ran`**: RAN (PNF, VNF, NR-UE)

### 0) Set kubeconfig

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
```

### 1) Verify core network is healthy

```bash
kubectl -n oai-cn get pods -o wide
```

### 2) (First time) Create `regcred` pull secret for private registry

The PNF/VNF/UE images are pulled from `bmw.ece.ntust.edu.tw`.
Create the Kubernetes pull secret in `oai-ran` (only needed once per cluster):

```bash
kubectl -n oai-ran create secret docker-registry regcred \
  --docker-server=bmw.ece.ntust.edu.tw \
  --docker-username=<username> \
  '--docker-password=<password>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify: `kubectl -n oai-ran get secret regcred`

### 3) Deploy/upgrade RAN (PNF, VNF, UE)

> **Important**: Always pass `--reset-values -f <values.yaml>` when upgrading.
> Without these flags, Helm re-uses old user-supplied values from the release history,
> and `nfimage.repository` silently falls back to the previously stored image (usually dockerhub).

```bash
cd ~/CRAN/bmw-cicd-manifests/helm-charts

helm -n oai-ran upgrade --install oai-pnf   ./oai-pnf   -f ./oai-pnf/values.yaml   --reset-values
helm -n oai-ran upgrade --install oai-vnf   ./oai-vnf   -f ./oai-vnf/values.yaml   --reset-values
helm -n oai-ran upgrade --install oai-nr-ue ./oai-nr-ue -f ./oai-nr-ue/values.yaml --reset-values

kubectl -n oai-ran rollout status deploy/oai-pnf
kubectl -n oai-ran rollout status deploy/oai-vnf
kubectl -n oai-ran rollout status deploy/oai-nr-ue
kubectl -n oai-ran get pods -o wide
```

### 4) Verify UE got a UE IP (PDU session accept)

```bash
kubectl -n oai-ran logs deploy/oai-nr-ue --since=10m | grep -E "PDU Session Establishment Accept|UE IPv4" -n || true
```

Also confirm the UE tunnel interface exists inside the UE pod:

```bash
UE_POD="$(kubectl -n oai-ran get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"
kubectl -n oai-ran exec "$UE_POD" -- ip -br a
```

### 5) Test data plane: CN ping UE

The `upf` container may not include `ping`, but the UPF pod usually has a `tcpdump` sidecar that does.

```bash
kubectl -n oai-cn exec deploy/oai-upf -c tcpdump -- ping -c 4 -W 1 12.1.1.100
```

### 6) Test throughput: CN → UE iperf3

Start an `iperf3` server inside the UE pod (bind to `oaitun_ue1` IP), then run the client from the UPF pod (tcpdump container).

```bash
UE_POD="$(kubectl -n oai-ran get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"

# start server in background (restarts are safe)
kubectl -n oai-ran exec "$UE_POD" -- sh -lc 'pkill iperf3 2>/dev/null || true; nohup iperf3 -s -B 12.1.1.100 -p 5201 >/tmp/iperf3-server.log 2>&1 & sleep 1; ss -lntp | grep 5201'

# run client from CN
kubectl -n oai-cn exec deploy/oai-upf -c tcpdump -- iperf3 -c 12.1.1.100 -p 5201 -t 10 -P 1
```

### 7) If CN→UE ping/iperf fails (common: stale TEID / unknown TEID drops)

Symptom in `oai-vnf` logs:
- `Received a incoming packet on unknown TEID (...) Dropping!`

This usually means UPF/gNB have stale session state after multiple UE restarts or image/values changes.
The fastest recovery is to restart UPF and UE to force a clean PDU session:

```bash
kubectl -n oai-cn  rollout restart deploy/oai-upf
kubectl -n oai-cn  rollout status  deploy/oai-upf

kubectl -n oai-ran rollout restart deploy/oai-nr-ue
kubectl -n oai-ran rollout status  deploy/oai-nr-ue
```

Then repeat steps 3–5.

