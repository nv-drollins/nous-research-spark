#!/usr/bin/env bash
# ============================================================================
#  nous-research-spark  —  one-shot Hermes Agent installer for NVIDIA DGX Spark
# ----------------------------------------------------------------------------
#  Run ONE command and get a demo-ready box:
#    * vLLM serving the agent-ready NVFP4 model as a boot-persistent service
#    * Hermes Agent installed and wired to the local endpoint
#    * Core agent tools enabled, verified end-to-end
#
#  Usage:
#      ./install.sh                 # full install
#      ./install.sh --help
#
#  Idempotent: safe to re-run. Follows NVIDIA's build.nvidia.com Hermes +
#  vLLM playbooks. Target: DGX Spark (GB10), DGX OS / Ubuntu 24.04, aarch64.
# ============================================================================
set -euo pipefail

# --- locate ourselves + load config ----------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.env"
LIB_FILE="${SCRIPT_DIR}/lib.sh"

# shellcheck source=/dev/null
source "${LIB_FILE}"
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# --- args -------------------------------------------------------------------
SKIP_VLLM=0
SKIP_HERMES=0
for arg in "$@"; do
  case "$arg" in
    --help|-h)
      cat <<EOF
nous-research-spark one-shot installer

  ./install.sh                 Install and configure everything
  ./install.sh --skip-vllm     Skip the vLLM service (Hermes + wiring only)
  ./install.sh --skip-hermes   Skip Hermes (bring up vLLM service only)
  ./install.sh --help          This help

Edit scripts/config.env to change the model, ports, tools, etc.
EOF
      exit 0 ;;
    --skip-vllm)   SKIP_VLLM=1 ;;
    --skip-hermes) SKIP_HERMES=1 ;;
    *) warn "Unknown argument: $arg (ignored)";;
  esac
done

# ============================================================================
banner "nous-research-spark  —  Hermes Agent on DGX Spark"
echo "  Model      : ${MODEL_HANDLE}"
echo "  vLLM        : ${VLLM_IMAGE}  (port ${VLLM_PORT}, ctx ${MAX_MODEL_LEN})"
echo "  Hermes URL : ${HERMES_BASE_URL}"
echo

# ---------------------------------------------------------------------------
# Step 1 — Preflight
# ---------------------------------------------------------------------------
step "1/6  Preflight checks"
preflight

# ---------------------------------------------------------------------------
# Step 2 — HuggingFace token (optional; model is public but token lifts limits)
# ---------------------------------------------------------------------------
step "2/6  HuggingFace token"
prompt_hf_token   # sets HF_TOKEN (may be empty) and persists to ~/.hermes-spark/hf_token

# ---------------------------------------------------------------------------
# Step 3 — vLLM as a boot-persistent systemd service
# ---------------------------------------------------------------------------
if [[ "${SKIP_VLLM}" -eq 0 ]]; then
  step "3/6  Serve the model with vLLM (systemd service)"
  install_vllm_service
  wait_for_vllm
else
  step "3/6  vLLM  (skipped by flag)"
fi

# ---------------------------------------------------------------------------
# Step 4 — Install Hermes Agent
# ---------------------------------------------------------------------------
if [[ "${SKIP_HERMES}" -eq 0 ]]; then
  step "4/6  Install Hermes Agent"
  install_hermes

  # -------------------------------------------------------------------------
  # Step 5 — Wire Hermes to the local vLLM endpoint (non-interactive)
  # -------------------------------------------------------------------------
  step "5/6  Configure Hermes -> local vLLM + enable tools"
  configure_hermes
  enable_hermes_tools

  # -------------------------------------------------------------------------
  # Step 6 — Verify end-to-end
  # -------------------------------------------------------------------------
  step "6/6  Verify"
  verify_stack
else
  step "4-6/6  Hermes  (skipped by flag)"
fi

# ---------------------------------------------------------------------------
banner "Done — your DGX Spark is demo-ready"
cat <<EOF

  Start chatting:            hermes
  Check the model service:   systemctl --user status ${VLLM_SERVICE}
  Tail model logs:           journalctl --user -u ${VLLM_SERVICE} -f
  Model API health:          curl -s http://localhost:${VLLM_PORT}/v1/models

  The vLLM service starts automatically on boot. If you rebooted just now,
  give it a couple of minutes to reload the model before the first prompt.

EOF
