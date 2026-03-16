# oai-rfsim-e2e

Umbrella Helm chart to deploy an **OAI NFAPI gNB (VNF)** + **OAI gNB (PNF) in RFsim mode** + **OAI NR-UE (RFsim)** against an **existing Open5GS core network**.

## Components (3 pods)

- `*-nfapi-gnb`: NFAPI gNB-VNF (creates `oai-nfapi-svc`)
- `*-rfsim-gnb`: RFsim gNB-PNF (creates `oai-rfsim-gnb-svc`)
- `*-nr-ue`: NR-UE (RFsim)

## Prerequisites

- Open5GS is already deployed and reachable from the Kubernetes cluster.
- For `nfapiGnb.multus.nfapiInterface.create=true`, Multus must be installed and the selected `hostInterface` must exist on the target node(s).
- The UE subscriber (`nrUe.config.fullImsi/fullKey/opc`) must exist in Open5GS.

## Install

From repository root:

```bash
helm install oai-rfsim ./bmw-cicd-manifests/helm-charts/oai-rfsim-e2e
```

## Key values to override

- **Core / Open5GS**
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

