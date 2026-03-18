#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
if [[ -z "${TAG}" ]]; then
  echo "Usage: $(basename "$0") <tag>"
  echo "Example: $(basename "$0") ming-nfapi-latest"
  exit 2
fi

KUBECONFIG_PATH="${KUBECONFIG:-/home/oai72_su/CRAN/kubeconfigs/worker-rt.config}"
RAN_NS="${RAN_NS:-oai-ran}"
CN_NS="${CN_NS:-}"
CHARTS_DIR="${CHARTS_DIR:-/home/oai72_su/CRAN/bmw-cicd-manifests/helm-charts}"
REGISTRY_SERVER="${REGISTRY_SERVER:-bmw.ece.ntust.edu.tw}"
REGISTRY_PROJECT="${REGISTRY_PROJECT:-minghong}"

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
echo "TAG=${TAG}"
echo

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing required command: $1"; exit 1; }; }
need kubectl
need helm

echo "=== Precheck: regcred exists (optional, for private registry) ==="
if kubectl -n "${RAN_NS}" get secret regcred >/dev/null 2>&1; then
  echo "OK: ${RAN_NS}/regcred exists"
else
  echo "WARN: ${RAN_NS}/regcred not found (image pulls may fail for private registry)"
fi
echo

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

echo "=== Ping latency (CN UPF -> UE) ==="
PING_OUT="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c tcpdump -- ping -c 5 -W 2 "${UE_IP}" 2>&1 || true)"
echo "${PING_OUT}"
PING_AVG_MS="$(echo "${PING_OUT}" | awk -F'/' '/^rtt/ {print $5}' | tr -d '\r' || true)"
echo "PING_AVG_MS=${PING_AVG_MS:-unknown}"
echo

echo "=== iperf3 throughput (CN -> UE, 10s) ==="
kubectl -n "${RAN_NS}" exec "${UE_POD}" -- bash -lc "pkill iperf3 2>/dev/null || true; nohup iperf3 -s -B ${UE_IP} -p 5201 >/tmp/iperf3-server.log 2>&1 & sleep 1; ss -lntp | grep 5201"
IPERF_OUT="$(kubectl -n "${CN_NS}" exec "${UPF_POD}" -c tcpdump -- iperf3 -c "${UE_IP}" -p 5201 -t 10 -i 2 2>&1 || true)"
echo "${IPERF_OUT}"

IPERF_SENDER_MBPS="$(echo "${IPERF_OUT}" | awk '/sender$/ {print $(NF-2)}' | tail -n 1 | tr -d '\r' || true)"
IPERF_SENDER_UNIT="$(echo "${IPERF_OUT}" | awk '/sender$/ {print $(NF-1)}' | tail -n 1 | tr -d '\r' || true)"
IPERF_RECV_MBPS="$(echo "${IPERF_OUT}" | awk '/receiver$/ {print $(NF-2)}' | tail -n 1 | tr -d '\r' || true)"
IPERF_RECV_UNIT="$(echo "${IPERF_OUT}" | awk '/receiver$/ {print $(NF-1)}' | tail -n 1 | tr -d '\r' || true)"

echo
echo "=== Summary ==="
echo "TAG=${TAG}"
echo "UE_IP=${UE_IP}"
echo "PING_AVG_MS=${PING_AVG_MS:-unknown}"
echo "IPERF_SENDER=${IPERF_SENDER_MBPS:-unknown} ${IPERF_SENDER_UNIT:-}"
echo "IPERF_RECEIVER=${IPERF_RECV_MBPS:-unknown} ${IPERF_RECV_UNIT:-}"
