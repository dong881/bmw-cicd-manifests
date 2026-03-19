# Scripts

## `switch_ran_images_and_test.sh`

Switch OAI RAN images (PNF/VNF/UE) to a given tag and run basic connectivity + throughput tests:

- **Ping**: UPF \(\rightarrow\) UE (`12.1.1.x`)
- **iperf3**: server on **UPF**, client on **UE**
  - **DL**: UE client uses `-R` (traffic UPF \(\rightarrow\) UE)
  - **UL**: UE client without `-R` (traffic UE \(\rightarrow\) UPF)

### Prerequisites

- `KUBECONFIG` points to the target cluster (default is `~/CRAN/kubeconfigs/worker-rt.config`)
- `kubectl` and `helm` installed
- Private registry secret `regcred` exists in the RAN namespace if needed

### Usage

```bash
./switch_ran_images_and_test.sh <tag>
```

Example:

```bash
./switch_ran_images_and_test.sh 2026w11
```

### Modes

- **`RUN_MODE=full` (default)**: `helm upgrade` PNF/VNF/UE to the requested tag, wait for rollouts, then test.
- **`RUN_MODE=test`**: skip Helm upgrades; only run ping/iperf against the currently running pods.

Example (test-only):

```bash
RUN_MODE=test ./switch_ran_images_and_test.sh 2026w11
```

### Key environment variables

- **Cluster / namespaces**
  - **`KUBECONFIG`**: kubeconfig path (default: `/home/oai72_su/CRAN/kubeconfigs/worker-rt.config`)
  - **`RAN_NS`**: RAN namespace (default: `oai-ran`)
  - **`CN_NS`**: CN namespace (auto-detected via UPF label if unset)
  - **`CHARTS_DIR`**: helm charts directory (default: `/home/oai72_su/CRAN/bmw-cicd-manifests/helm-charts`)

- **Image registry**
  - **`REGISTRY_SERVER`**: default `bmw.ece.ntust.edu.tw`
  - **`REGISTRY_PROJECT`**: default `minghong`

- **UE auto-tuning**
  - **`AUTO_TUNE_UE_FROM_GNB_LOG`**: `1` enables parsing `"Command line parameters for OAI UE:"` from PNF/VNF logs and reconfigures UE with matching RF params (default: `1`)
  - **`UE_HINT_WAIT_SECONDS`**: how long to wait for that hint line (default: `120`)

- **Ping**
  - **`PING_WAIT_SECONDS`**: wait for ping to become non-100% loss before iperf (default: `60`)
  - **`PING_COUNT`**: ping count per check (default: `2`)
  - **`PING_TIMEOUT_SECONDS`**: ping timeout seconds (default: `1`)

- **iperf**
  - **`IPERF_MODE`**: `udp` or `tcp` (default: `udp`)
  - **`IPERF_BW`**: UDP bitrate (default: `700M`)
  - **`IPERF_TIME_SECONDS`**: duration (default: `10`)
  - **`IPERF_DIRECTION`**: `dl` or `ul` (default: `dl`)
  - **`IPERF_RETRIES`**: attempts (default: `5`)

### Common examples

DL UDP 700M (server=UPF, reverse mode on UE client):

```bash
IPERF_MODE=udp IPERF_BW=700M IPERF_DIRECTION=dl ./switch_ran_images_and_test.sh 2026w11
```

UL UDP 700M:

```bash
IPERF_MODE=udp IPERF_BW=700M IPERF_DIRECTION=ul ./switch_ran_images_and_test.sh 2026w11
```

TCP downlink:

```bash
IPERF_MODE=tcp IPERF_DIRECTION=dl ./switch_ran_images_and_test.sh 2026w11
```

