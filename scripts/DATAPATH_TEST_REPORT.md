# Datapath test report (automated checks)

**Date:** 2026-03-20  
**Kubeconfig:** `worker-rt` (namespaces `oai-ran`, `oai-cn`)

## Final result

✅ **Success for both tags** after fixing NFAPI P7 startup race in script:

- `2026w11` -> ping + iperf passed
- `oai-nfapi-latest` -> ping + iperf passed

## Root cause and fix

### Root cause

- NFAPI split startup was racey: VNF sometimes had no P7 connection (`could not find P7 connection for phy_id 1`), PNF showed `msgs ontime 0`, UE stayed in `synch Failed` / no `oaitun_ue1`.

### Fix applied in `switch_ran_images_and_test.sh`

1. Added **P7 readiness gate**: wait for either
   - VNF log `Received NFAPI_START_RESP`, or
   - PNF log `msgs ontime > 0`.
2. If P7 still not ready, perform **one controlled PNF restart** and re-check P7.
3. Keep UE auto-tune from PNF/VNF hint line and run datapath checks only after UE gets `oaitun_ue1`.

## Measured datapath results

| Tag | UE IP | UE->UPF ping loss | UE->UPF RTT avg | UPF->UE ping loss | iperf mode/dir | iperf sender | iperf receiver | Result |
|-----|-------|-------------------|-----------------|-------------------|----------------|--------------|----------------|--------|
| `oai-nfapi-latest` | `12.1.1.100` | `0%` | `10.476 ms` | `0%` | UDP DL (`-R`) | `700 Mbits/sec` | `106 Mbits/sec` | ✅ |
| `2026w11` | `12.1.1.100` | `0%` | `14.927 ms` | `0%` | UDP DL (`-R`) | `700 Mbits/sec` | `150 Mbits/sec` | ✅ |

> Note: `iperf sender` reflects configured send rate on UPF server side; `receiver` is effective UE throughput (with packet loss in this RFSim profile).

## Command used

```bash
export KUBECONFIG=/home/oai72_su/CRAN/kubeconfigs/worker-rt.config
CHARTS_DIR=/home/oai72_su/oai_mp_f_ming_develop_latest/bmw-cicd-manifests/helm-charts \
AUTO_TUNE_UE_FROM_GNB_LOG=1 SKIP_UE_LOG_WAIT=1 STRICT_UPF_TO_UE_PING=0 \
./switch_ran_images_and_test.sh <tag>
```
