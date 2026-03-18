# OAI RFsim (PNF/VNF/UE) debug try-log (worker-rt)

Last updated: 2026-03-18

## Goal

- Keep **PNF↔VNF P7 slot signaling** stable.
- Make **UE attach + PDU session succeed** and obtain a **UE IPv4 address** through OAI CN.

## Environment / entrypoint

- **KUBECONFIG**: `/home/oai72_su/CRAN/kubeconfigs/worker-rt.config`
- **Namespaces**:
  - RAN: `oai-ran` (PNF/VNF/UE)
  - CN: `oai-cn` (AMF/SMF/UPF/…)

## What we observed (symptoms → root cause)

### 1) UE could not connect RFsim by service name

- **Symptom**: UE log `connect() to oai-pnf:4043 failed, errno(101)` while `getent hosts oai-pnf` worked when run manually.
- **Root cause**: `nr-uesoftmodem` (certain builds) can be unreliable when passed a hostname to `--rfsimulator.serveraddr`.
- **Fix applied**: UE startup wrapper resolves `RFSIM_HOST` to a numeric IP and passes the IP to `nr-uesoftmodem`.
- **Where**: `bmw-cicd-manifests/helm-charts/oai-nr-ue/templates/deployment.yaml` (shell snippet that retries DNS then uses the IP).

### 2) UE got Connection Refused on 4043

- **Symptom**: UE log `connect() ... errno(111)` and PNF container had no listener on 4043.
- **Root cause**: RFsim server port not exposed/ready (and/or gNB crashed before opening the socket).
- **Fix applied**: add `4043/TCP` to the `oai-pnf` Service port list.
- **Where**: `bmw-cicd-manifests/helm-charts/oai-pnf/templates/service.yaml`

### 3) PNF CrashLoopBackOff (ExitCode 139) after UE connects

- **Symptom**: PNF crashes with:
  - `Assertion (b->th.beam_map == 1ULL || t->beam_ctrl->enable_beams == 1) failed!`
  - `The transmitter has enabled beam simulation while this receiver has not`
- **Root cause**: **RFsim protocol mismatch** between UE and gNB images (beam simulation header mismatch).
- **Tried (and why not)**
  - `--rfsimulator.options beams`: **invalid option** (not recognized by OAI RFsim CLI).
  - `--rfsimulator.[0].enable_beams 1` on PNF: **PNF build rejected it** (`[CONFIG] unknown option`) and exited.
  - `--rfsimulator.[0].beam_map 1` / `--rfsimulator.beam_map 1` on old UE: also **rejected at runtime** (`[CONFIG] unknown option`) despite appearing to work with `--help`.
- **Working resolution**: **align UE + gNB to the same official weekly tag** so RFsim framing/options match.

## Final working configuration (as of 2026-03-17)

### A) Images: align to official OAI weekly tag

Updated Helm values to use Docker Hub official images, same tag across PNF/VNF/UE:

- `bmw-cicd-manifests/helm-charts/oai-pnf/values.yaml`
  - `nfimage.repository: docker.io/oaisoftwarealliance/oai-gnb`
  - `nfimage.version: 2026.w09`
  - `pullPolicy: IfNotPresent`
- `bmw-cicd-manifests/helm-charts/oai-vnf/values.yaml`
  - `nfimage.repository: docker.io/oaisoftwarealliance/oai-gnb`
  - `nfimage.version: 2026.w09`
  - `pullPolicy: IfNotPresent`
- `bmw-cicd-manifests/helm-charts/oai-nr-ue/values.yaml`
  - `nfimage.repository: docker.io/oaisoftwarealliance/oai-nr-ue`
  - `nfimage.version: 2026.w09`
  - `pullPolicy: IfNotPresent`

### B) CN integration: DNN must match SMF configuration

- **Symptom**: UE received `PDU Session Establishment Reject`.
- **Root cause**: SMF returned `DNN_DENIED` because SMF allowed DNNs were `ims` and `oai`, but UE requested `internet`.
- **Fix applied**: set UE `dnn: "oai"` in `oai-nr-ue` values.
  - `bmw-cicd-manifests/helm-charts/oai-nr-ue/values.yaml` → `config.dnn: "oai"`
  - `bmw-cicd-manifests/helm-charts/oai-nr-ue/templates/configmap.yaml` already templates `dnn` from values.
- **Result**: UE log shows `Received PDU Session Establishment Accept, UE IPv4: 12.1.1.100`.

### C) UE CLI flags must match the UE image build

- **Symptom**: UE pod went `CrashLoopBackOff` while still showing PDU accept earlier in logs.
- **Root cause**: Some flags previously used with older UE builds are **not accepted** by `docker.io/oaisoftwarealliance/oai-nr-ue:2026.w09`:
  - `--sa`
  - `--nokrnmod`
- **Fix applied**: remove those from UE `useAdditionalOptions` and keep only supported RFsim parameters (`--rfsim -r ... --numerology ... -C ...`).

## Quick checks / commands (copy-paste)

```bash
export KUBECONFIG=/home/oai72_su/CRAN/kubeconfigs/worker-rt.config

# RAN pods
kubectl -n oai-ran get pods -o wide

# RFsim server is up and got UE connection
kubectl -n oai-ran logs deploy/oai-pnf --since=10m | grep -E "Running as server|Client connects|Assertion" -n

# UE PDU session accept and IP
kubectl -n oai-ran logs deploy/oai-nr-ue --since=10m | grep -E "PDU Session Establishment (Accept|Reject)|UE IPv4|DNN" -n

# SMF confirms DNN and accept
kubectl -n oai-cn logs deploy/oai-smf -c smf --since=10m | grep -E "Requested DNN|unknown requested DNN|DNN_DENIED|Establishment (Accept|Reject)" -n
```


---

## [2026-03-18] Switch to custom Jenkins-built images (`2026w11`)

### Goal
Use `bmw.ece.ntust.edu.tw/infidel/oai-gnb:2026w11` and `oai-nr-ue:2026w11` built from the
`nfapi-Delay-Management` branch via Jenkins/Podman pipeline.

### Steps

#### 1. Create `regcred` in `oai-ran` namespace
The private registry `bmw.ece.ntust.edu.tw` requires authentication.
No `regcred` secret existed anywhere in the cluster.

```bash
kubectl -n oai-ran create secret docker-registry regcred \
  --docker-server=bmw.ece.ntust.edu.tw \
  --docker-username=minghong \
  '--docker-password=<pwd>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

#### 2. Enable `imagePullSecrets` in values.yaml

`oai-pnf/values.yaml` and `oai-vnf/values.yaml` had the `imagePullSecrets` block commented out.
`oai-nr-ue/values.yaml` already had it enabled.

Uncommented in both PNF and VNF:
```yaml
imagePullSecrets:
  - name: "regcred"
```

#### 3. Helm upgrade with `--reset-values -f values.yaml`

Plain `helm upgrade` without flags re-uses the old user-supplied values stored in the
release history, so `nfimage.repository` kept falling back to the previous dockerhub image.
Must pass both flags to force the chart file to take full effect:

```bash
CHARTS=/home/oai72_su/CRAN/bmw-cicd-manifests/helm-charts
helm upgrade oai-pnf   -n oai-ran $CHARTS/oai-pnf   -f $CHARTS/oai-pnf/values.yaml   --reset-values
helm upgrade oai-vnf   -n oai-ran $CHARTS/oai-vnf   -f $CHARTS/oai-vnf/values.yaml   --reset-values
helm upgrade oai-nr-ue -n oai-ran $CHARTS/oai-nr-ue -f $CHARTS/oai-nr-ue/values.yaml --reset-values
```

#### 4. Verification

All three pods reached `Running` using the private-registry images:

```
oai-nr-ue  bmw.ece.ntust.edu.tw/infidel/oai-nr-ue:2026w11   1/1 Running
oai-pnf    bmw.ece.ntust.edu.tw/infidel/oai-gnb:2026w11     1/1 Running
oai-vnf    bmw.ece.ntust.edu.tw/infidel/oai-gnb:2026w11     1/1 Running
```

- UE got `oaitun_ue1  UNKNOWN  12.1.1.100/24`
- PNF P7: `msgs ontime ~485-495 msg late 0` (stable)
- VNF MAC stats: UE in-sync, DL/UL active

#### 5. Data-plane ping & iperf (CN to UE)

```bash
# Ping from UPF to UE - 5/5 received, avg 16.4 ms
kubectl exec -n oai-cn $UPF_POD -- ping -c 5 12.1.1.100

# iperf3 DL: start server on UE, run client from UPF tcpdump container
kubectl exec -n oai-ran $UE_POD -- bash -c \
  'nohup iperf3 -s -B 12.1.1.100 -p 5201 >/tmp/iperf3-server.log 2>&1 &'
kubectl exec -n oai-cn $UPF_POD -c tcpdump -- iperf3 -c 12.1.1.100 -p 5201 -t 10
# Result: 151 Mbits/sec sender, 148 Mbits/sec receiver -- PASS
```


## “Don’t retry this” list

- Don’t use `--rfsimulator.options beams` (invalid flag).
- Don’t try to “paper over” RFsim assertion with random CLI flags when UE/gNB images are from different eras (2024 vs 2026): it tends to produce either
  - **assert/Exit 139** (beam mismatch), or
  - **unknown option → exit** (flag not supported by that build).
- Don’t assume UE CLI flags are stable across tags (e.g. `--sa`, `--nokrnmod`): always confirm on the exact image tag in use.

