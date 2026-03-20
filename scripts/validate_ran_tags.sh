#!/usr/bin/env bash
# Run switch_ran_images_and_test.sh for each tag (full upgrade + ping + iperf).
# Usage:
#   ./validate_ran_tags.sh
#   TAGS="2026w11 oai-nfapi-latest" CHARTS_DIR=... ./validate_ran_tags.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SWITCH="${SCRIPT_DIR}/switch_ran_images_and_test.sh"
TAGS="${TAGS:-2026w11 oai-nfapi-latest}"

for t in ${TAGS}; do
  echo ""
  echo "######################################################################"
  echo "### TAG=${t}"
  echo "######################################################################"
  "${SWITCH}" "${t}"
done

echo ""
echo "=== All tags OK: ${TAGS} ==="
