#!/usr/bin/env bash
# RAN image switch + datapath check (SIMU / NFAPI).
# Linear flow: PNF -> VNF -> UE hint -> UE once -> oaitun IP -> (UE log hints) -> UE->UPF ping -> few UPF->UE pings -> iperf.
# No recovery restarts, no mid-loop UPF restart, no iperf retry loops (adjust waits via env instead).
set -euo pipefail

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: $(basename "$0") <tag>"
  echo "Example: $(basename "$0") 2026w11"
  echo "Validate two tags: $(dirname "$0")/validate_ran_tags.sh"
  exit 2
fi

RUN_MODE="${RUN_MODE:-full}"   # full | test (test = ping+iperf only, no helm)

KUBECONFIG_PATH="${KUBECONFIG:-/home/oai72_su/CRAN/kubeconfigs/worker-rt.config}"
RAN_NS="${RAN_NS:-oai-ran}"
CN_NS="${CN_NS:-}"
CHARTS_DIR="${CHARTS_DIR:-/home/oai72_su/CRAN/bmw-cicd-manifests/helm-charts}"
REGISTRY_SERVER="${REGISTRY_SERVER:-bmw.ece.ntust.edu.tw}"
REGISTRY_PROJECT="${REGISTRY_PROJECT:-minghong}"

AUTO_TUNE_UE_FROM_GNB_LOG="${AUTO_TUNE_UE_FROM_GNB_LOG:-1}"
UE_LOG_GLOBAL_OPTS="${UE_LOG_GLOBAL_OPTS:- --log_config.global_log_options level,nocolor,time}"
UE_HINT_WAIT_SECONDS="${UE_HINT_WAIT_SECONDS:-120}"
RAN_STABILIZE_SECONDS="${RAN_STABILIZE_SECONDS:-8}"
UE_TUN_WAIT_SECONDS="${UE_TUN_WAIT_SECONDS:-180}"
UPF_READY_WAIT_SECONDS="${UPF_READY_WAIT_SECONDS:-90}"
ROLLOUT_TIMEOUT_PNF_SECONDS="${ROLLOUT_TIMEOUT_PNF_SECONDS:-240}"
ROLLOUT_TIMEOUT_VNF_SECONDS="${ROLLOUT_TIMEOUT_VNF_SECONDS:-240}"
ROLLOUT_TIMEOUT_UE_SECONDS="${ROLLOUT_TIMEOUT_UE_SECONDS:-300}"
# NFAPI P7 can be racey after rollouts; check P7 and do one controlled PNF restart if missing.
P7_WAIT_SECONDS="${P7_WAIT_SECONDS:-35}"
P7_REPAIR_SLEEP_SECONDS="${P7_REPAIR_SLEEP_SECONDS:-10}"

IPERF_MODE="${IPERF_MODE:-udp}"
IPERF_BW="${IPERF_BW:-700M}"
IPERF_TIME_SECONDS="${IPERF_TIME_SECONDS:-10}"
IPERF_DIRECTION="${IPERF_DIRECTION:-dl}"
IPERF_CONNECT_TIMEOUT_MS="${IPERF_CONNECT_TIMEOUT_MS:-3000}"

# Datapath: prefer log + UE->UPF ping (fast); avoid long UPF->UE ping loops.
# UE log: OAI NR UE often prints oaitun / PDU / RRC when the stack is up (tune regex if your build differs).
UE_DATAPATH_LOG_WAIT_SECONDS="${UE_DATAPATH_LOG_WAIT_SECONDS:-45}"
UE_DATAPATH_LOG_POLL_INTERVAL="${UE_DATAPATH_LOG_POLL_INTERVAL:-2}"
UE_DATAPATH_LOG_REGEX="${UE_DATAPATH_LOG_REGEX:-oaitun|PDU session|Interface.*oaitun|RRC_CONNECTED|CM_CONNECTED|default bearer|IPv4.*address|assigned.*IP}"
SKIP_UE_LOG_WAIT="${SKIP_UE_LOG_WAIT:-0}"   # 1 = skip log polling (only IP + ping checks)

POST_UE_TUN_STABILIZE_SECONDS="${POST_UE_TUN_STABILIZE_SECONDS:-8}"
# OAI NR UE chart uses container name `nr-ue` (explicit -c avoids wrong container if sidecars exist).
UE_K8S_CONTAINER="${UE_K8S_CONTAINER:-nr-ue}"
# While waiting for oaitun, print UE log tail every N seconds (0 = disable).
UE_TUN_WAIT_LOG_EVERY="${UE_TUN_WAIT_LOG_EVERY:-30}"

# Primary: UE -> UPF (tun0); few packets, short wait per attempt.
UE_TO_UPF_PING_COUNT="${UE_TO_UPF_PING_COUNT:-3}"
UE_TO_UPF_PING_W="${UE_TO_UPF_PING_W:-2}"

# Secondary: UPF -> UE (often slow/flaky ICMP); limited attempts, not a long wall-clock loop.
UPF_TO_UE_PING_ATTEMPTS="${UPF_TO_UE_PING_ATTEMPTS:-6}"
UPF_TO_UE_PING_INTERVAL="${UPF_TO_UE_PING_INTERVAL:-3}"
PING_COUNT="${PING_COUNT:-3}"
PING_TIMEOUT_SECONDS="${PING_TIMEOUT_SECONDS:-2}"

# Legacy name kept for summary: max time budget for UPF->UE attempts ≈ attempts * interval
PING_WAIT_SECONDS="${PING_WAIT_SECONDS:-$(( UPF_TO_UE_PING_ATTEMPTS * UPF_TO_UE_PING_INTERVAL ))}"

export KUBECONFIG="${KUBECONFIG_PATH}"

if [[ -z "${CN_NS}" ]]; then
  CN_NS="$(kubectl get pods --all-namespaces -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
fi
if [[ -z "${CN_NS}" ]]; then
  echo "ERROR: could not detect UPF namespace (label app.kubernetes.io/name=oai-upf)"
  exit 1
fi

echo "=== Context === KUBECONFIG=${KUBECONFIG} RAN_NS=${RAN_NS} CN_NS=${CN_NS} TAG=${TAG} RUN_MODE=${RUN_MODE} ==="

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing: $1"; exit 1; }; }
need kubectl
need helm

pick_upf_tool_container() {
  local ns="$1" pod="$2" c
  for c in tcpdump upf; do
    if kubectl -n "$ns" get pod "$pod" -o jsonpath="{.spec.containers[?(@.name=='$c')].name}" 2>/dev/null | grep -q "$c"; then
      if kubectl -n "$ns" exec "$pod" -c "$c" -- sh -lc 'command -v ping >/dev/null 2>&1 && command -v iperf3 >/dev/null 2>&1' >/dev/null 2>&1; then
        echo "$c"
        return 0
      fi
    fi
  done
  for c in $(kubectl -n "$ns" get pod "$pod" -o jsonpath='{range .spec.containers[*]}{.name}{" "}{end}' 2>/dev/null); do
    if kubectl -n "$ns" exec "$pod" -c "$c" -- sh -lc 'command -v ping >/dev/null 2>&1 && command -v iperf3 >/dev/null 2>&1' >/dev/null 2>&1; then
      echo "$c"
      return 0
    fi
  done
  return 1
}

refresh_ran_pod_refs() {
  UE_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-nr-ue -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  PNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-pnf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  VNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-vnf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
}

wait_upf_ready_for_ping() {
  local i tun_ip
  echo "=== UPF ready (Ready + tun0 IPv4, max ${UPF_READY_WAIT_SECONDS}s) ==="
  for i in $(seq 1 "${UPF_READY_WAIT_SECONDS}"); do
    UPF_POD="$(kubectl -n "${CN_NS}" get pod -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    [[ -z "${UPF_POD}" ]] && { sleep 1; continue; }
    kubectl -n "${CN_NS}" wait --for=condition=Ready "pod/${UPF_POD}" --timeout=2s >/dev/null 2>&1 || { sleep 1; continue; }
    UPF_TOOL_CONTAINER="$(pick_upf_tool_container "${CN_NS}" "${UPF_POD}" || true)"
    [[ -z "${UPF_TOOL_CONTAINER:-}" ]] && { sleep 1; continue; }
    tun_ip="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "ip -4 -o addr show dev tun0 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n 1" 2>/dev/null | tr -d '\r' || true)"
    if [[ -n "${tun_ip}" ]]; then
      echo "UPF ok: pod=${UPF_POD} c=${UPF_TOOL_CONTAINER} tun0=${tun_ip}"
      return 0
    fi
    sleep 1
  done
  echo "WARN: UPF tun0 not ready in ${UPF_READY_WAIT_SECONDS}s"
  return 0
}

parse_ping_loss_pct() {
  sed -n 's/.* \([0-9.]*\)% packet loss.*/\1/p' | head -n 1 | tr -d '\r'
}

# Poll UE logs for NAS/PDU/tunnel strings (faster than hammering UPF->UE ICMP).
wait_ue_datapath_logs() {
  [[ "${SKIP_UE_LOG_WAIT}" == "1" ]] && { echo "=== UE log wait skipped (SKIP_UE_LOG_WAIT=1) ==="; return 0; }
  local deadline=$(( $(date +%s) + UE_DATAPATH_LOG_WAIT_SECONDS ))
  echo "=== UE log datapath hints (max ${UE_DATAPATH_LOG_WAIT_SECONDS}s, every ${UE_DATAPATH_LOG_POLL_INTERVAL}s) ==="
  while [[ $(date +%s) -lt "${deadline}" ]]; do
    if kubectl -n "${RAN_NS}" logs "${UE_POD}" -c "${UE_K8S_CONTAINER}" --tail=5000 2>/dev/null | grep -Eiq "${UE_DATAPATH_LOG_REGEX}"; then
      echo "UE log: matched (${UE_DATAPATH_LOG_REGEX})"
      return 0
    fi
    sleep "${UE_DATAPATH_LOG_POLL_INTERVAL}"
  done
  echo "WARN: no datapath regex match in UE log yet (continuing; oaitun IP + ping will decide)"
}

resolve_upf_for_exec() {
  UPF_POD="$(kubectl -n "${CN_NS}" get pod -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  UPF_TOOL_CONTAINER="$(pick_upf_tool_container "${CN_NS}" "${UPF_POD}" || true)"
}

wait_nfapi_p7_ready() {
  local i
  echo "=== Wait NFAPI P7 ready (max ${P7_WAIT_SECONDS}s) ==="
  for i in $(seq 1 "${P7_WAIT_SECONDS}"); do
    refresh_ran_pod_refs
    if [[ -n "${VNF_POD}" ]] && kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=2000 2>/dev/null | grep -q "Received NFAPI_START_RESP"; then
      echo "NFAPI P7 ready (VNF received START_RESP)"
      return 0
    fi
    if [[ -n "${PNF_POD}" ]] && kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=2000 2>/dev/null | grep -q "msgs ontime [1-9]"; then
      echo "NFAPI P7 ready (PNF reports msgs ontime > 0)"
      return 0
    fi
    sleep 1
  done
  echo "WARN: NFAPI P7 not ready within ${P7_WAIT_SECONDS}s"
  return 1
}

# --- full: sequential RAN + single UE deploy (works for 2026w11 and oai-nfapi-latest) ---
if [[ "${RUN_MODE}" == "full" ]]; then
  echo "=== Helm: PNF -> VNF -> (UE hint) -> UE ==="
  if [[ "${AUTO_TUNE_UE_FROM_GNB_LOG}" == "1" ]]; then
    helm upgrade oai-pnf -n "${RAN_NS}" "${CHARTS_DIR}/oai-pnf" -f "${CHARTS_DIR}/oai-pnf/values.yaml" --reset-values \
      --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-gnb" --set "nfimage.version=${TAG}"
    kubectl -n "${RAN_NS}" rollout status deploy/oai-pnf --timeout="${ROLLOUT_TIMEOUT_PNF_SECONDS}s"
    helm upgrade oai-vnf -n "${RAN_NS}" "${CHARTS_DIR}/oai-vnf" -f "${CHARTS_DIR}/oai-vnf/values.yaml" --reset-values \
      --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-gnb" --set "nfimage.version=${TAG}"
    kubectl -n "${RAN_NS}" rollout status deploy/oai-vnf --timeout="${ROLLOUT_TIMEOUT_VNF_SECONDS}s"
    if ! wait_nfapi_p7_ready; then
      echo "=== P7 repair: controlled restart of PNF (once) ==="
      kubectl -n "${RAN_NS}" rollout restart deploy/oai-pnf
      kubectl -n "${RAN_NS}" rollout status deploy/oai-pnf --timeout="${ROLLOUT_TIMEOUT_PNF_SECONDS}s"
      sleep "${P7_REPAIR_SLEEP_SECONDS}"
      wait_nfapi_p7_ready || { echo "ERROR: NFAPI P7 still not ready after one repair restart"; exit 1; }
    fi
    sleep "${RAN_STABILIZE_SECONDS}"

    UE_HINT_LINE=""
    UE_HINT_SRC=""
    for i in $(seq 1 "${UE_HINT_WAIT_SECONDS}"); do
      PNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-pnf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      VNF_POD="$(kubectl -n "${RAN_NS}" get pod -l app.kubernetes.io/name=oai-vnf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${PNF_POD}" ]]; then
        UE_HINT_SRC="pnf"
        UE_HINT_LINE="$(kubectl -n "${RAN_NS}" logs "${PNF_POD}" --tail=20000 2>/dev/null | grep -E "Command line parameters for OAI UE:" | tail -n 1 || true)"
      fi
      if [[ -z "${UE_HINT_LINE}" && -n "${VNF_POD}" ]]; then
        UE_HINT_SRC="vnf"
        UE_HINT_LINE="$(kubectl -n "${RAN_NS}" logs "${VNF_POD}" --tail=20000 2>/dev/null | grep -E "Command line parameters for OAI UE:" | tail -n 1 || true)"
      fi
      [[ -n "${UE_HINT_LINE}" ]] && break
      echo "UE hint (${i}/${UE_HINT_WAIT_SECONDS})..."
      sleep 1
    done

    if [[ -n "${UE_HINT_LINE}" ]]; then
      UE_HINT_OPTS="${UE_HINT_LINE#*: }"
      UE_ADDITIONAL="--rfsim ${UE_HINT_OPTS}${UE_LOG_GLOBAL_OPTS}"
      echo "UE hint from ${UE_HINT_SRC}: ${UE_HINT_OPTS}"
      UE_ADDITIONAL_ESCAPED="${UE_ADDITIONAL//,/\\,}"
      helm upgrade oai-nr-ue -n "${RAN_NS}" "${CHARTS_DIR}/oai-nr-ue" -f "${CHARTS_DIR}/oai-nr-ue/values.yaml" --reset-values \
        --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-nr-ue" --set "nfimage.version=${TAG}" \
        --set-string "config.useAdditionalOptions=${UE_ADDITIONAL_ESCAPED}"
    else
      echo "WARN: no UE hint line; UE uses values.yaml useAdditionalOptions"
      helm upgrade oai-nr-ue -n "${RAN_NS}" "${CHARTS_DIR}/oai-nr-ue" -f "${CHARTS_DIR}/oai-nr-ue/values.yaml" --reset-values \
        --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-nr-ue" --set "nfimage.version=${TAG}"
    fi
  else
    helm upgrade oai-pnf -n "${RAN_NS}" "${CHARTS_DIR}/oai-pnf" -f "${CHARTS_DIR}/oai-pnf/values.yaml" --reset-values \
      --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-gnb" --set "nfimage.version=${TAG}"
    helm upgrade oai-vnf -n "${RAN_NS}" "${CHARTS_DIR}/oai-vnf" -f "${CHARTS_DIR}/oai-vnf/values.yaml" --reset-values \
      --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-gnb" --set "nfimage.version=${TAG}"
    helm upgrade oai-nr-ue -n "${RAN_NS}" "${CHARTS_DIR}/oai-nr-ue" -f "${CHARTS_DIR}/oai-nr-ue/values.yaml" --reset-values \
      --set "nfimage.repository=${REGISTRY_SERVER}/${REGISTRY_PROJECT}/oai-nr-ue" --set "nfimage.version=${TAG}"
    kubectl -n "${RAN_NS}" rollout status deploy/oai-pnf --timeout="${ROLLOUT_TIMEOUT_PNF_SECONDS}s"
    kubectl -n "${RAN_NS}" rollout status deploy/oai-vnf --timeout="${ROLLOUT_TIMEOUT_VNF_SECONDS}s"
  fi
  kubectl -n "${RAN_NS}" rollout status deploy/oai-nr-ue --timeout="${ROLLOUT_TIMEOUT_UE_SECONDS}s"

  echo "=== Pods ==="
  refresh_ran_pod_refs
  kubectl -n "${RAN_NS}" get pods -o wide
  kubectl -n "${RAN_NS}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' || true
  echo
fi

refresh_ran_pod_refs

echo "=== UE oaitun_ue1 (container=${UE_K8S_CONTAINER}) ==="
UE_IP=""
for i in $(seq 1 "${UE_TUN_WAIT_SECONDS}"); do
  UE_IP="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -c "${UE_K8S_CONTAINER}" -- bash -lc "ip -4 -o addr show dev oaitun_ue1 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1" | tr -d '\r' || true)"
  [[ -n "${UE_IP}" ]] && break
  echo "oaitun (${i}/${UE_TUN_WAIT_SECONDS})..."
  if [[ "${UE_TUN_WAIT_LOG_EVERY}" =~ ^[0-9]+$ ]] && [[ "${UE_TUN_WAIT_LOG_EVERY}" -gt 0 ]] && [[ $((i % UE_TUN_WAIT_LOG_EVERY)) -eq 0 ]]; then
    echo "--- UE log tail (hint: synch Failed / no cell = align config.useAdditionalOptions with gNB; run RUN_MODE=full for auto-tune) ---"
    kubectl -n "${RAN_NS}" logs "${UE_POD}" -c "${UE_K8S_CONTAINER}" --tail=12 2>/dev/null || true
  fi
  sleep 1
done
[[ -z "${UE_IP}" ]] && {
  echo "ERROR: no oaitun_ue1 IPv4 after ${UE_TUN_WAIT_SECONDS}s"
  kubectl -n "${RAN_NS}" logs "${UE_POD}" -c "${UE_K8S_CONTAINER}" --tail=120 || true
  echo "Fix: align oai-nr-ue config (RF/SSB) with PNF/VNF; use AUTO_TUNE_UE_FROM_GNB_LOG=1 and RUN_MODE=full, or edit helm-charts/oai-nr-ue/values.yaml useAdditionalOptions."
  exit 1
}
echo "UE_IP=${UE_IP}"

[[ "${POST_UE_TUN_STABILIZE_SECONDS}" =~ ^[0-9]+$ ]] && [[ "${POST_UE_TUN_STABILIZE_SECONDS}" -gt 0 ]] && sleep "${POST_UE_TUN_STABILIZE_SECONDS}"

wait_upf_ready_for_ping
[[ -z "${UPF_TOOL_CONTAINER:-}" ]] && {
  UPF_POD="$(kubectl -n "${CN_NS}" get pod -l app.kubernetes.io/name=oai-upf -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  UPF_TOOL_CONTAINER="$(pick_upf_tool_container "${CN_NS}" "${UPF_POD}" || true)"
}
[[ -z "${UPF_TOOL_CONTAINER:-}" ]] && { echo "ERROR: UPF has no container with ping+iperf3"; exit 1; }

UPF_TUN_IP="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "ip -4 -o addr show dev tun0 2>/dev/null | tr -s ' ' | cut -d' ' -f4 | cut -d/ -f1 | head -n 1" 2>/dev/null | tr -d '\r' || true)"
[[ -z "${UPF_TUN_IP}" ]] && UPF_TUN_IP="12.1.1.1"
echo "UPF_TUN_IP=${UPF_TUN_IP}"

wait_ue_datapath_logs

# Primary: UE -> core (ICMP toward UPF tun0); validates route without long UPF->UE timeouts.
STRICT_UPF_TO_UE_PING="${STRICT_UPF_TO_UE_PING:-0}"
echo "=== Datapath: UE -> UPF (${UPF_TUN_IP}) ==="
UE_TO_UPF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -c "${UE_K8S_CONTAINER}" -- sh -lc "LANG=C LC_ALL=C ping -c '${UE_TO_UPF_PING_COUNT}' -W '${UE_TO_UPF_PING_W}' '${UPF_TUN_IP}'" 2>&1 || true)"
echo "${UE_TO_UPF_OUT}"
UE_TO_UPF_LOSS="$(echo "${UE_TO_UPF_OUT}" | parse_ping_loss_pct || true)"
[[ -z "${UE_TO_UPF_LOSS}" ]] && UE_TO_UPF_LOSS="100"
PING_AVG_MS="$(echo "${UE_TO_UPF_OUT}" | awk -F'/' '/^rtt/ {print $5}' | tr -d '\r' || true)"
if [[ "${UE_TO_UPF_LOSS}" == "100" ]] || ! awk -v x="${UE_TO_UPF_LOSS}" 'BEGIN{exit !(x+0 < 100)}'; then
  echo "ERROR: UE->UPF ping failed (loss=${UE_TO_UPF_LOSS}%). Fix session/route before iperf."
  exit 1
fi

# Secondary: UPF -> UE (limited attempts; ICMP can be asymmetric or rate-limited).
PING_OUT=""
PING_LOSS_PCT="100"
echo "=== Datapath: UPF -> UE (${UPF_TO_UE_PING_ATTEMPTS} tries, ${UPF_TO_UE_PING_INTERVAL}s apart) ==="
for attempt in $(seq 1 "${UPF_TO_UE_PING_ATTEMPTS}"); do
  resolve_upf_for_exec
  [[ -z "${UPF_POD}" || -z "${UPF_TOOL_CONTAINER:-}" ]] && { sleep "${UPF_TO_UE_PING_INTERVAL}"; continue; }
  PING_OUT="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "LANG=C LC_ALL=C ping -c '${PING_COUNT}' -W '${PING_TIMEOUT_SECONDS}' '${UE_IP}'" 2>&1 || true)"
  PING_LOSS_PCT="$(echo "${PING_OUT}" | parse_ping_loss_pct || true)"
  [[ -z "${PING_LOSS_PCT}" ]] && PING_LOSS_PCT="100"
  echo "UPF->UE try ${attempt}/${UPF_TO_UE_PING_ATTEMPTS} loss=${PING_LOSS_PCT}%"
  if awk -v x="${PING_LOSS_PCT}" 'BEGIN{exit !(x+0 < 100)}'; then
    PING_AVG_MS="$(echo "${PING_OUT}" | awk -F'/' '/^rtt/ {print $5}' | tr -d '\r' || true)"
    break
  fi
  [[ "${attempt}" -lt "${UPF_TO_UE_PING_ATTEMPTS}" ]] && sleep "${UPF_TO_UE_PING_INTERVAL}"
done
echo "${PING_OUT}"
if [[ "${STRICT_UPF_TO_UE_PING}" == "1" ]] && [[ "${PING_LOSS_PCT}" == "100" ]]; then
  echo "ERROR: UPF->UE ping failed (STRICT_UPF_TO_UE_PING=1)"
  exit 1
fi
[[ "${PING_LOSS_PCT}" == "100" ]] && echo "WARN: UPF->UE ping still 100% (UE->UPF ok; continuing to iperf — set STRICT_UPF_TO_UE_PING=1 to fail here)"

get_bits_per_sec_value() {
  local line="$1"
  echo "${line}" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec$/){print $(i-1), $i; exit}}'
}

echo "=== iperf3 (UPF server, UE client, ${IPERF_DIRECTION}) ==="
kubectl -n "${CN_NS}" exec "${UPF_POD}" -c "${UPF_TOOL_CONTAINER}" -- sh -lc "pkill iperf3 2>/dev/null || true; nohup iperf3 -s -p 5201 >/tmp/iperf3.log 2>&1 & sleep 1" || true

if [[ "${IPERF_MODE}" == "udp" ]]; then
  if [[ "${IPERF_DIRECTION}" == "dl" ]]; then
    IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -c "${UE_K8S_CONTAINER}" -- sh -lc "iperf3 --connect-timeout ${IPERF_CONNECT_TIMEOUT_MS} -u -b ${IPERF_BW} -R -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1" || true)"
  else
    IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -c "${UE_K8S_CONTAINER}" -- sh -lc "iperf3 --connect-timeout ${IPERF_CONNECT_TIMEOUT_MS} -u -b ${IPERF_BW} -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1" || true)"
  fi
else
  if [[ "${IPERF_DIRECTION}" == "dl" ]]; then
    IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -c "${UE_K8S_CONTAINER}" -- sh -lc "iperf3 --connect-timeout ${IPERF_CONNECT_TIMEOUT_MS} -R -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1" || true)"
  else
    IPERF_OUT="$(kubectl -n "${RAN_NS}" exec "${UE_POD}" -c "${UE_K8S_CONTAINER}" -- sh -lc "iperf3 --connect-timeout ${IPERF_CONNECT_TIMEOUT_MS} -c ${UPF_TUN_IP} -p 5201 -t ${IPERF_TIME_SECONDS} -i 2 2>&1" || true)"
  fi
fi
echo "${IPERF_OUT}"

echo "${IPERF_OUT}" | grep -qE "iperf Done|receiver$" || { echo "ERROR: iperf did not complete"; exit 1; }

SENDER_LINE="$(echo "${IPERF_OUT}" | grep -E "sender$" | tail -n 1 || true)"
RECEIVER_LINE="$(echo "${IPERF_OUT}" | grep -E "receiver$" | tail -n 1 || true)"
SENDER_BW_UNIT="$(get_bits_per_sec_value "${SENDER_LINE}")"
RECEIVER_BW_UNIT="$(get_bits_per_sec_value "${RECEIVER_LINE}")"

echo
echo "=== OK === TAG=${TAG} UE_IP=${UE_IP} UE_to_UPF_loss=${UE_TO_UPF_LOSS}% UPF_to_UE_loss=${PING_LOSS_PCT}% RTT_MS=${PING_AVG_MS:-?}"
echo "IPERF sender: ${SENDER_BW_UNIT:-?}  receiver: ${RECEIVER_BW_UNIT:-?}"
