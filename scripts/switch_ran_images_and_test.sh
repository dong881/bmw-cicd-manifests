#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: $(basename "$0") <tag>"
  echo "Example: $(basename "$0") ming-nfapi-latest"
  exit 2
fi

RUN_MODE="${RUN_MODE:-full}"   # full|test  (test = only ping+iperf using current running pods)

KUBECONFIG_PATH="${KUBECONFIG:-/home/oai72_su/CRAN/kubeconfigs/worker-rt.config}"
RAN_NS="${RAN_NS:-oai-ran}"
CN_NS="${CN_NS:-}"
CHARTS_DIR="${CHARTS_DIR:-/home/oai72_su/CRAN/bmw-cicd-manifests/helm-charts}"
REGISTRY_SERVER="${REGISTRY_SERVER:-bmw.ece.ntust.edu.tw}"
REGISTRY_PROJECT="${REGISTRY_PROJECT:-minghong}"
AUTO_TUNE_UE_FROM_GNB_LOG="${AUTO_TUNE_UE_FROM_GNB_LOG:-1}"
UE_LOG_GLOBAL_OPTS="${UE_LOG_GLOBAL_OPTS:- --log_config.global_log_options level,nocolor,time}"
UE_HINT_WAIT_SECONDS="${UE_HINT_WAIT_SECONDS:-120}"
IPERF_MODE="${IPERF_MODE:-udp}"          # udp|tcp
IPERF_BW="${IPERF_BW:-700M}"             # only used for UDP
IPERF_TIME_SECONDS="${IPERF_TIME_SECONDS:-10}"
PING_WAIT_SECONDS="${PING_WAIT_SECONDS:-60}"          # wait for CN->UE ping before iperf
PING_COUNT="${PING_COUNT:-2}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-1}"
IPERF_DIRECTION="${IPERF_DIRECTION:-dl}"   # dl|ul (traffic direction)
IPERF_RETRIES="${IPERF_RETRIES:-5}"        # iperf attempts before giving up

export KUBECONFIG="${KUBECONFIG_PATH}"

if [[ -z "${CN_NS}" ]]; then
  CN_NS="$(kubectl get pods --all-namespaces -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
fi
if [[ -z "${CN_NS}" ]]; then
  echo "ERROR: could not detect UPF namespace via label app.kubernetes.io/name=oai-upf"
  exit 1
fi

echo "=== Context ==="
echo "KUBECONFIG=${KUBECONFIG}"
echo "RAN_NS=${RAN_NS}"
echo "CN_NS=${CN_NS}"
echo "CHARTS_DIR=${CHARTS_DIR}"
echo "REGISTRY_SERVER=${REGISTRY_SERVER}"
echo "REGISTRY_PROJECT=${REGISTRY_PROJECT}"
echo "RUN_MODE=${RUN_MODE}"
echo "AUTO_TUNE_UE_FROM_GNB_LOG=${AUTO_TUNE_UE_FROM_GNB_LOG}"
echo "UE_HINT_WAIT_SECONDS=${UE_HINT_WAIT_SECONDS}"
echo "IPERF_MODE=${IPERF_MODE}"
echo "IPERF_BW=${IPERF_BW}"
echo "IPERF_TIME_SECONDS=${IPERF_TIME_SECONDS}"
echo "PING_WAIT_SECONDS=${PING_WAIT_SECONDS}"
echo "IPERF_DIRECTION=${IPERF_DIRECTION}"
echo "IPERF_RETRIES=${IPERF_RETRIES}"
echo "TAG=${TAG}"
echo

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1"; exit 1; }; }
need kubectl
need helm

pick_upf_tool_container() {
  local ns="$1"
  local pod="$2"
  for c in tcpdump upf; do
    if kubectl -n "$ns" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$c')].name}" 2>/dev/null | grep -q "$c"; then
      if kubectl -n "$ns" exec "$pod" -c "$c" -- sh -lc 'command -v ping >/dev/null 2>&1 && command -v iperf3 >/dev/null 2>&1' >/dev/null 2>&1; then
        echo "$c"
        return 0
      fi
    fi
  done
  # Fallback: first container that has both tools
  for c in $(kubectl -n "$ns" get pod "$pod" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}' 2>/dev/null); do
    if kubectl -n "$ns" exec "$pod" -c "$c" -- sh -lc 'command -v ping >/dev/null 2>&1 && command -v iperf3 >/dev/null 2>&1' >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

echo "=== Precheck: regcred exists (optional, for private registry) ==="
if kubectl -n "${RAN_NS}" get secret regcred >/dev/null 2>&1; then
  echo "OK: ${RAN_NS}/regcred exists"
else
  echo "WARN: ${RAN_NS}/regcred not found (image pulls may fail for private registry)"
fi
echo

UE_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"
PNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-pnf -o jsonpath='{.items[0].metadata.name}')"
VNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-vnf -o jsonpath='{.items[0].metadata.name}')"

if [[ "${RUN_MODE}" == "full" ]]; then
  echo "=== Helm upgrade (force values.yaml via --reset-values) ==="
  helm upgrade oai-pnf   -n "${RAN_NS}" "${CHARTS_DIR}/oai-pnf"   -f "${CHARTS_DIR}/oai-pnf/values.yaml"   --reset-values --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-gnb"   --set "nfimage.version=${TAG}"
  helm upgrade oai-vnf   -n "${RAN_NS}" "${CHARTS_DIR}/oai-vnf"   -f "${CHARTS_DIR}/oai-vnf/values.yaml"   --reset-values --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-gnb"   --set "nfimage.version=${TAG}"
  helm upgrade oai-nr-ue -n "${RAN_NS}" "${CHARTS_DIR}/oai-nr-ue" -f "${CHARTS_DIR}/oai-nr-ue/values.yaml" --reset-values --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-nr-ue" --set "nfimage.version=${TAG}"
  echo

  echo "=== Wait for rollout ==="
  kubectl -n "${RAN_NS}" rollout status deploy/oai-pnf   --timeout=180s
  kubectl -n "${RAN_NS}" rollout status deploy/oai-vnf   --timeout=180s
  kubectl -n "${RAN_NS}" rollout status deploy/oai-nr-ue --timeout=240s
  echo

  echo "=== Pods & images ==="
  kubectl -n "${RAN_NS}" get pods -o wide
  echo "---"
  kubectl -n "${RAN_NS}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}'
  echo

  UE_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"
  PNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-pnf -o jsonpath='{.items[0].metadata.name}')"
  VNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-vnf -o jsonpath='{.items[0].metadata.name}')"
fi

if [[ "${RUN_MODE}" == "full" && "${AUTO_TUNE_UE_FROM_GNB_LOG}" == "1" ]]; then
  echo "=== Auto-tune UE RF params from gNB/VNF logs ==="
  # Prefer PNF log line when present (often printed there): "Command line parameters for OAI UE: ..."
  UE_HINT_LINE=""
  UE_HINT_SRC=""
  for i in $(seq 1 "${UE_HINT_WAIT_SECONDS}"); do
    UE_HINT_SRC="pnf"
    UE_HINT_LINE="$(kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=4000 2>/dev/null | grep -E "Command line parameters for OAI UE:" | tail -n 1 || true)"
    if [[ -z "${UE_HINT_LINE}" ]]; then
      UE_HINT_SRC="vnf"
      UE_HINT_LINE="$(kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=4000 2>/dev/null | grep -E "Command line parameters for OAI UE:" | tail -n 1 || true)"
    fi
    if [[ -n "${UE_HINT_LINE}" ]]; then
      break
    fi
    echo "Waiting for UE hint line in PNF/VNF logs... (${i}/${UE_HINT_WAIT_SECONDS})"
    sleep 1
  done

  if [[ -n "${UE_HINT_LINE}" ]]; then
    UE_HINT_OPTS="${UE_HINT_LINE#*: }"
    # Build a safe, consistent UE additional options string.
    # Keep --rfsim and global log options; take the RF/SSB args from the hint line.
    UE_ADDITIONAL="--rfsim ${UE_HINT_OPTS}${UE_LOG_GLOBAL_OPTS}"
    echo "Detected UE hint from ${UE_HINT_SRC}: ${UE_HINT_OPTS}"
    echo "Applying UE useAdditionalOptions: ${UE_ADDITIONAL}"
    UE_ADDITIONAL_ESCAPED="${UE_ADDITIONAL//,/\\,}"

    # Update UE release only (repository/version stay the same).
    helm upgrade oai-nr-ue -n "${RAN_NS}" "${CHARTS_DIR}/oai-nr-ue" \
      -f "${CHARTS_DIR}/oai-nr-ue/values.yaml" --reset-values \
      --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-nr-ue" \
      --set "nfimage.version=${TAG}" \
      --set-string "config.useAdditionalOptions=${UE_ADDITIONAL_ESCAPED}"

    kubectl -n "${RAN_NS}" rollout status deploy/oai-nr-ue --timeout=240s
    UE_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"
  else
    echo "ERROR: could not find 'Command line parameters for OAI UE' in PNF/VNF logs after ${UE_HINT_WAIT_SECONDS}s"
    echo "--- PNF matching lines (tail) ---"
    kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=4000 2>/dev/null | grep -E "Command line parameters for OAI UE:" || true
    echo "--- VNF matching lines (tail) ---"
    kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=4000 2>/dev/null | grep -E "Command line parameters for OAI UE:" || true
    echo "--- PNF last logs ---"
    kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=120 2>/dev/null || true
    echo "--- VNF last logs ---"
    kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=120 2>/dev/null || true
    exit 1
  fi
  echo
fi

echo "=== UE IP (oaitun_ue1) ==="
UE_IP=""
for i in $(seq 1 120); do
  # Avoid awk `$4` so `set -u` never trips in this script.
  UE_IP="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -- bash -lc "ip -4 -o addr show dev oaitun_ue1 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1" | tr -d '\r' || true)"
  if [[ -n "${UE_IP}" ]]; then
    break
  fi
  echo "Waiting for UE oaitun_ue1 IPv4... (${i}/120)"
  sleep 1
done
if [[ -z "${UE_IP}" ]]; then
  echo "ERROR: UE has no IPv4 on oaitun_ue1 after 120s"
  kubectl -n "${RAN_NS}" exec "${UE_POD}" -- ip -br a || true
  echo
  echo "--- Recent events (RAN namespace) ---"
  kubectl -n "${RAN_NS}" get events --sort-by=.metadata.creationTimestamp | tail -n 40 || true
  echo "--- UE last logs ---"
  kubectl -n "${RAN_NS}" logs "${UE_POD}" --tail=120 || true
  echo
  echo "--- PNF last logs ---"
  kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=120 || true
  echo
  echo "--- VNF last logs ---"
  kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=120 || true
  exit 1
fi
echo "UE_IP=${UE_IP}"
echo

echo "=== Quick health hints (P7 + MAC) ==="
kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=5 || true
kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=8 || true
echo

UPF_POD="$(kubectl -n "${CN_NS}" get pod -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.name}')"
UPF_TOOL_CONTAINER="$(pick_upf_tool_container "${CN_NS}" "${UPF_POD}" || true)"
if [[ -z "${UPF_TOOL_CONTAINER}" ]]; then
  echo "ERROR: could not find a UPF pod container with both ping and iperf3"
  echo "Containers:"
  kubectl -n "${CN_NS}" get pod "${UPF_POD}" -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}' || true
  exit 1
fi
echo "UPF tool container: ${UPF_TOOL_CONTAINER}"

echo "=== Ping readiness wait (CN UPF -> UE) ==="
PING_OUT=""
PING_LOSS_PCT="100"
for i in $(seq 1 "${PING_WAIT_SECONDS}"); do
  PING_OUT="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- ping -c "${PING_COUNT}" -W "${PING_TIMEOUT_SECONDS}" "${UE_IP}" 2>&1 || true)"
  PING_LOSS_PCT="$(echo "${PING_OUT}" | awk '/packet loss/ {gsub(/%/,"",$6); print $6}' | head -n 1 || true)"
  [[ -z "${PING_LOSS_PCT}" ]] && PING_LOSS_PCT="100"
  echo "Ping check (${i}/${PING_WAIT_SECONDS}): loss=${PING_LOSS_PCT}%"
  if [[ "${PING_LOSS_PCT}" != "100" ]]; then
    break
  fi
  sleep 1
done
echo "${PING_OUT}"
PING_AVG_MS="$(echo "${PING_OUT}" | awk -F'/' '/^rtt/ {print $5}' | tr -d '\r' || true)"
echo "PING_AVG_MS=${PING_AVG_MS:-unknown}"
echo

get_bits_per_sec_value() {
  # Usage: get_bits_per_sec_value "<line>" sender|receiver
  local line="$1"
  local bw unit
  bw="$(echo "${line}" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec$/){print $(i-1); exit}}')"
  unit="$(echo "${line}" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec$/){print $i; exit}}')"
  echo "${bw:-unknown} ${unit:-}"
}

UPF_TUN_IP=""
UPF_TUN_IP="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "ip -4 -o addr show dev tun0 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n 1" 2>/dev/null | tr -d '\r' || true)"
[[ -z "${UPF_TUN_IP}" ]] && UPF_TUN_IP="12.1.1.1"

echo "UPF_TUN_IP=${UPF_TUN_IP}"
echo

echo "=== iperf3 throughput (server=UPF, client=UE, direction=${IPERF_DIRECTION}) ==="
IPERF_OUT=""
for attempt in $(seq 1 "${IPERF_RETRIES}"); do
  echo "iperf attempt ${attempt}/${IPERF_RETRIES}"
  # NOTE: iperf3 server has no -u flag; UDP is client-selected via -u.
  kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "pkill iperf3 2>/dev/null || true; nohup iperf3 -s -p 5201 >/tmp/iperf3-server-upf.log 2>&1 & sleep 1" || true

  if [[ "${IPERF_MODE}" == "udp" ]]; then
    if [[ "${IPERF_DIRECTION}" == "dl" ]]; then
      # -R makes traffic from server->client (UPF->UE) => downlink
      IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -u -b ${IPERF_BW} -R -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true")"
    else
      # UE->UPF uplink (no -R)
      IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -u -b ${IPERF_BW} -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true")"
    fi
  else
    if [[ "${IPERF_DIRECTION}" == "dl" ]]; then
      IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -R -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true")"
    else
      IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true")"
    fi
  fi

  echo "${IPERF_OUT}"
  if echo "${IPERF_OUT}" | grep -qE "iperf Done|receiver$"; then
    break
  fi
  if echo "${IPERF_OUT}" | grep -qiE "connection refused|timed out"; then
    sleep 2
    continue
  fi
done

# (IPERF_OUT already printed in-loop)
SENDER_LINE="$(echo "${IPERF_OUT}" | grep -E "sender$" | tail -n 1 || true)"
RECEIVER_LINE="$(echo "${IPERF_OUT}" | grep -E "receiver$" | tail -n 1 || true)"
SENDER_BW_UNIT="$(get_bits_per_sec_value "${SENDER_LINE}" sender)"
RECEIVER_BW_UNIT="$(get_bits_per_sec_value "${RECEIVER_LINE}" receiver)"
IPERF_SENDER_MBPS="$(echo "${SENDER_BW_UNIT}" | awk '{print $1}')"
IPERF_SENDER_UNIT="$(echo "${SENDER_BW_UNIT}" | awk '{print $2}')"
IPERF_RECV_MBPS="$(echo "${RECEIVER_BW_UNIT}" | awk '{print $1}')"
IPERF_RECV_UNIT="$(echo "${RECEIVER_BW_UNIT}" | awk '{print $2}')"

echo
echo "=== Summary ==="
echo "TAG=${TAG}"
echo "UE_IP=${UE_IP}"
echo "PING_LOSS_PCT=${PING_LOSS_PCT}"
echo "PING_AVG_MS=${PING_AVG_MS:-unknown}"
echo "IPERF_SENDER=${IPERF_SENDER_MBPS:-unknown} ${IPERF_SENDER_UNIT:-}"
echo "IPERF_RECEIVER=${IPERF_RECV_MBPS:-unknown} ${IPERF_RECV_UNIT:-}"

# If ping/iperf failed but UE has IP, it's commonly stale CN state after upgrades.
# Do one controlled recovery (restart UPF + UE) and retry once.
if [[ "${PING_LOSS_PCT}" == "100" ]]; then
  echo
  echo "=== Recovery: ping failed, restarting UPF and UE then retry once ==="
  kubectl -n "${CN_NS}" rollout restart deploy/oai-upf || true
  kubectl -n "${CN_NS}" rollout status deploy/oai-upf --timeout=180s || true
  kubectl -n "${RAN_NS}" rollout restart deploy/oai-nr-ue || true
  kubectl -n "${RAN_NS}" rollout status deploy/oai-nr-ue --timeout=240s || true

  UE_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}')"
  UE_IP=""
  for i in $(seq 1 60); do
    UE_IP="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -- bash -lc "ip -4 -o addr show dev oaitun_ue1 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1" | tr -d '\r' || true)"
    [[ -n "${UE_IP}" ]] && break
    sleep 1
  done
  UPF_POD="$(kubectl -n "${CN_NS}" get pod -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.name}')"
  UPF_TOOL_CONTAINER="$(pick_upf_tool_container "${CN_NS}" "${UPF_POD}" || true)"

  echo "Retry UE_IP=${UE_IP} UPF_POD=${UPF_POD} UPF_TOOL_CONTAINER=${UPF_TOOL_CONTAINER}"
  echo "=== Ping retry ==="
  kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- ping -c 5 -W 2 "${UE_IP}" 2>&1 || true
  echo "=== iperf retry (server=UPF, client=UE, direction=${IPERF_DIRECTION}) ==="
  UPF_TUN_IP="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "ip -4 -o addr show dev tun0 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n 1" 2>/dev/null | tr -d '\r' || true)"
  [[ -z "${UPF_TUN_IP}" ]] && UPF_TUN_IP="12.1.1.1"
  kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "pkill iperf3 2>/dev/null || true; nohup iperf3 -s -p 5201 >/tmp/iperf3-server-upf.log 2>&1 & sleep 1" || true
  if [[ "${IPERF_MODE}" == "udp" ]]; then
    if [[ "${IPERF_DIRECTION}" == "dl" ]]; then
      kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -u -b ${IPERF_BW} -R -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true" || true
    else
      kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -u -b ${IPERF_BW} -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true" || true
    fi
  else
    if [[ "${IPERF_DIRECTION}" == "dl" ]]; then
      kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -R -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true" || true
    else
      kubectl -n "${RAN_NS}" exec "${UE_POD}" -- sh -lc "iperf3 -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1 || true" || true
    fi
  fi
fi
