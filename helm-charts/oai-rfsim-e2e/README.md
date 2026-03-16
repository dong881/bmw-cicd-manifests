# oai-rfsim-e2e

Umbrella Helm chart to deploy an **OAI NFAPI gNB (VNF)** + **OAI gNB (PNF) in RFsim mode** + **OAI NR-UE (RFsim)** against an **existing Open5GS core network**.
Umbrella Helm chart to deploy an **OAI NFAPI gNB (VNF)** + **OAI gNB (PNF) in RFsim mode** + **OAI NR-UE (RFsim)** against an **existing OAI 5G Core (CN)**.

## Components (3 pods)

- `*-nfapi-gnb`: NFAPI gNB-VNF (creates `oai-nfapi-svc`)
- `*-rfsim-gnb`: RFsim gNB-PNF (creates `oai-rfsim-gnb-svc`)
- `*-nr-ue`: NR-UE (RFsim)

## Prerequisites

- OAI 5G Core is already deployed and reachable from the Kubernetes cluster.
- For `nfapiGnb.multus.nfapiInterface.create=true`, Multus must be installed and the selected `hostInterface` must exist on the target node(s).
- The UE subscriber (`nrUe.config.fullImsi/fullKey/opc`) must exist in the OAI CN subscriber database.

## End-to-end setup: OAI CN + NFAPI gNB (VNF) + RFsim gNB (PNF) + OAI NR-UE

The commands below assume:

- You are in the `~/CRAN` workspace.
- Your cluster kubeconfig is `~/CRAN/kubeconfigs/worker-rt.config`.

### 1. Export KUBECONFIG

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config
```

### 2. Deploy OAI 5G Core (CN)

```bash
cd ~/CRAN/oai-cn5g-fed

# Build / refresh chart dependencies
helm dependency build ci-scripts/charts/oai-5g-basic

# Create namespace (if not exists) and install CN
kubectl get ns oai-cn >/dev/null 2>&1 || kubectl create ns oai-cn

helm upgrade --install oai-cn \
  ./ci-scripts/charts/oai-5g-basic \
  -n oai-cn \
  -f ./bmw-oai-cn-values.yaml

# Wait until all CN pods are Ready
kubectl -n oai-cn get pods
```

You should see all core NFs `Running` (`oai-amf`, `oai-smf`, `oai-upf`, `oai-ausf`, `oai-udm`, `oai-udr`, `oai-nrf`, `oai-cn-mysql`, `oai-lmf`).

### 3. Deploy NFAPI gNB (VNF) + RFsim gNB (PNF) + OAI NR-UE

```bash
cd ~/CRAN

# Create namespace (if not exists)
kubectl get ns oai-ran >/dev/null 2>&1 || kubectl create ns oai-ran

# Install / upgrade the umbrella RAN chart
helm upgrade --install oai-rfsim \
  ./bmw-cicd-manifests/helm-charts/oai-rfsim-e2e \
  -n oai-ran

# Check pods
kubectl -n oai-ran get pods -o wide
```

You should see:

- `gnb-nfapi-vnf` (NFAPI gNB-VNF) – **Running**
- `gnb-nfapi-pnf-rfsim` (RFsim gNB-PNF) – **Running**
- `oai-rfsim-nr-ue` (OAI NR-UE RFsim) – **Running**

### 3bis. Upgrade / uninstall OAI CN and OAI gNB

**Upgrade OAI CN (keep namespace and data):**

```bash
cd ~/CRAN/oai-cn5g-fed
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config

helm dependency build ci-scripts/charts/oai-5g-basic

helm upgrade oai-cn \
  ./ci-scripts/charts/oai-5g-basic \
  -n oai-cn \
  -f ./bmw-oai-cn-values.yaml
```

**Uninstall OAI CN (delete release, keep namespace for reuse):**

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config

helm uninstall oai-cn -n oai-cn

# (optional) clean up leftover pods/services in namespace
kubectl -n oai-cn delete all --all
```

**Upgrade OAI gNB (NFAPI+RFsim+UE, keep namespace):**

```bash
cd ~/CRAN
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config

helm upgrade oai-rfsim \
  ./bmw-cicd-manifests/helm-charts/oai-rfsim-e2e \
  -n oai-ran
```

**Uninstall OAI gNB / UE (delete release, keep namespace):**

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config

helm uninstall oai-rfsim -n oai-ran

# (optional) clean up leftover pods/services in namespace
kubectl -n oai-ran delete all --all
```

**完全移除 namespace（包含裡面所有資源）：**

```bash
export KUBECONFIG=~/CRAN/kubeconfigs/worker-rt.config

# 刪除整個 OAI CN namespace
kubectl delete ns oai-cn

# 刪除整個 OAI RAN namespace
kubectl delete ns oai-ran
```

### 4. Verify control-plane connectivity (NFAPI gNB ↔ OAI CN)

```bash
# AMF logs
kubectl -n oai-cn logs deploy/oai-amf -c amf --tail=80

# NFAPI gNB logs (NGAP/N2)
kubectl -n oai-ran logs deploy/gnb-nfapi-vnf --tail=80
```

You should see NGAP messages between gNB and AMF, and no persistent SCTP errors.

### 5. Verify RFsim links (PNF ↔ VNF, UE ↔ gNB-PNF)

```bash
# NFAPI VNF (P5/P7) logs
kubectl -n oai-ran logs deploy/gnb-nfapi-vnf --tail=120

# RFsim PNF logs
kubectl -n oai-ran logs deploy/gnb-nfapi-pnf-rfsim --tail=120

# NR-UE RFsim logs
kubectl -n oai-ran logs deploy/oai-rfsim-nr-ue --tail=120
```

- VNF logs應該顯示 `PNF_PARAM_RESPONSE / PNF_CONFIG_RESPONSE / PNF_START_RESPONSE / NFAPI_PARAM_RESP / CONFIG_RESP / START_RESP`。  
- PNF/UE logs 應該顯示 RFsim client 成功連線到 `oai-rfsim-gnb-svc:4043`。

### 6. 在 UE pod 內測試 `ping` / `iperf`

進入 UE pod：

```bash
UE_POD=$(kubectl -n oai-ran get pod -l app=oai-rfsim-nr-ue -o jsonpath='{.items[0].metadata.name}')
kubectl -n oai-ran exec -it "$UE_POD" -- bash
```

在 UE 容器內，當 UE 已經成功註冊並建立 PDU session 後：

```bash
# 檢查 UE 端 IP 以及路由
ip addr
ip route

# 測試對 CN / Internet 的連通 (視 UPF / route 設定而定)
ping -c 4 12.1.1.1        # 例如 UPF 或 traffic-server 所在網段

# 若容器內有安裝 iperf3，可進一步測試吞吐
iperf3 -c <server-ip> -u -b 50M -t 10
```

> 注意：實際可達到的目標 IP、是否有 `iperf3` binary，要依你在 CN / traffic-server 以及 UE 映像中安裝的工具為準。

## Key values to override

- **Core / OAI CN**
  - `cn.amf.host`: AMF IP or DNS name reachable from the cluster
  - `cn.plmn.mcc`, `cn.plmn.mnc`, `cn.plmn.tac`
  - `cn.slice.sst`, `cn.slice.sd`, `cn.slice.dnn`

- **NFAPI interface (Multus)**
  - `nfapiGnb.multus.nfapiInterface.hostInterface`
  - `nfapiGnb.multus.nfapiInterface.IPadd`, `nfapiGnb.multus.nfapiInterface.Netmask`

- **NR-UE subscriber + RF**
  - `nrUe.config.fullImsi`, `nrUe.config.fullKey`, `nrUe.config.opc`
  - `nrUe.config.useAdditionalOptions`
  - `nrUe.config.rfSimServer` (defaults to `oai-rfsim-gnb-svc`)

## What “Running” means here

This chart’s success criterion is that the three pods start and remain `Running`, and that:
- RFsim gNB-PNF can reach the NFAPI gNB-VNF on the configured NFAPI IP (`nfapiGnb.multus.nfapiInterface.IPadd`)
- NR-UE can resolve and reach `nrUe.config.rfSimServer`

