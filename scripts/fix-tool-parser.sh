#!/usr/bin/env bash
# ============================================================================
#  fix-tool-parser.sh — repair a box where Hermes "spins and does nothing"
# ----------------------------------------------------------------------------
#  Symptom : you prompt the agent, it thinks briefly, then returns to an empty
#            prompt. Plain chat works; anything needing a tool silently doesn't.
#  Cause   : vLLM started with `--tool-call-parser hermes` (a JSON parser named
#            after the Hermes *model family*, NOT Hermes Agent). Qwen3.x emits
#            XML tool calls, so every one of them fails to parse -- silently.
#  Fix     : switch the running unit to `qwen3_xml`, restart, verify for real.
#
#  Idempotent and safe to re-run. Backs the unit up before touching it.
#  See TROUBLESHOOTING.md for the full write-up.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/config.env"

UNIT="${HOME}/.config/systemd/user/${VLLM_SERVICE}.service"
WANT="qwen3_xml"   # valid in vLLM 0.30: qwen3_xml | qwen3_coder

banner "Repair vLLM tool-call parser"

# --- 1. locate the unit -----------------------------------------------------
step "1/4  Inspect the service unit"
[[ -f "${UNIT}" ]] || die "No unit at ${UNIT}. Run ./scripts/install.sh first."

current="$(grep -o -- '--tool-call-parser [A-Za-z0-9_]*' "${UNIT}" | awk '{print $2}' | head -1)"
if [[ -z "${current}" ]]; then
  die "Unit has no --tool-call-parser flag. Re-run ./scripts/install.sh to regenerate it."
fi
ok "Unit currently uses: --tool-call-parser ${current}"

# --- 2. patch if needed -----------------------------------------------------
step "2/4  Apply the fix"
if [[ "${current}" == "${WANT}" ]]; then
  ok "Already set to ${WANT} — no change needed"
  patched=0
else
  cp "${UNIT}" "${UNIT}.bak.$(date +%Y%m%d%H%M%S)"
  ok "Backed up unit to ${UNIT}.bak.*"
  sed -i "s/--tool-call-parser ${current}/--tool-call-parser ${WANT}/" "${UNIT}"
  grep -q -- "--tool-call-parser ${WANT}" "${UNIT}" || die "Patch did not apply."
  ok "Patched: ${current} -> ${WANT}"
  patched=1
fi

# Keep config.env in step so a re-install can't reintroduce the bug.
if ! grep -q -- "--tool-call-parser ${WANT}" "${SCRIPT_DIR}/config.env"; then
  warn "scripts/config.env still has the old parser — run 'git pull' to update it,"
  warn "  otherwise a future ./install.sh will undo this fix."
fi

# --- 3. restart -------------------------------------------------------------
step "3/4  Restart the model service"
if [[ "${patched}" -eq 1 ]] || ! curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user restart "${VLLM_SERVICE}.service"
  echo "  Reloading model weights (usually 5-6 min on a Spark)..."
  waited=0
  while (( waited < VLLM_STARTUP_TIMEOUT )); do
    if curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
      ok "vLLM healthy after ${waited}s"; break
    fi
    systemctl --user is-active --quiet "${VLLM_SERVICE}.service" \
      || { journalctl --user -u "${VLLM_SERVICE}" -n 30 --no-pager; die "Service died on restart."; }
    sleep 10; waited=$(( waited + 10 )); printf '  ... %ss elapsed\r' "${waited}"
  done
  (( waited < VLLM_STARTUP_TIMEOUT )) || die "Timed out waiting for vLLM."
else
  ok "Service already healthy — leaving it running"
fi

# --- 4. verify for real -----------------------------------------------------
step "4/4  Verify tool calls actually parse"
probe="$(curl -s -X POST "http://localhost:${VLLM_PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL_HANDLE}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 847 * 293? Use the calculate tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"calculate\",\"description\":\"Do arithmetic\",\"parameters\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":1200}")"

if echo "${probe}" | grep -q '"tool_calls":[[:space:]]*\[' \
   && echo "${probe}" | grep -q '"finish_reason":[[:space:]]*"tool_calls"'; then
  ok "Tool calls parse correctly (finish_reason=tool_calls)"
  banner "Fixed — agentic mode is working"
  cat <<EOF

  Try it:   cd example && hermes
            "Count how many pages 2605.28774v1.pdf has and how large it is."
            (expect: 41 pages, 1,908,389 bytes)

EOF
else
  warn "Still broken. The model emitted a tool call the server could not parse."
  warn "Server-side detail:"
  journalctl --user -u "${VLLM_SERVICE}" -n 20 --no-pager 2>/dev/null \
    | grep -i -A3 'Error in extracting tool call' || true
  echo
  warn "Your build's available parsers:"
  docker exec "${VLLM_CONTAINER}" ls /usr/local/lib/python3.12/dist-packages/vllm/tool_parsers/ 2>/dev/null \
    | grep tool_parser || warn "  (could not list — is the container running?)"
  die "See TROUBLESHOOTING.md"
fi
