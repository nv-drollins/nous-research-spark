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
#  STANDALONE: no repo, no config, no arguments needed. Everything is read
#  from the installed systemd unit, which is the source of truth on a box
#  that is already broken. Run it straight off the internet:
#
#    curl -fsSL https://raw.githubusercontent.com/nv-drollins/nous-research-spark/main/scripts/fix-tool-parser.sh | bash
#
#  Idempotent and safe to re-run. Backs the unit up before touching it.
#  See TROUBLESHOOTING.md for the full write-up.
# ============================================================================
set -euo pipefail

WANT="${WANT:-qwen3_xml}"            # valid in vLLM 0.30: qwen3_xml | qwen3_coder
SERVICE="${VLLM_SERVICE:-vllm-server}"
UNIT="${HOME}/.config/systemd/user/${SERVICE}.service"

r=$'\033[0m'; b=$'\033[1m'; g=$'\033[32m'; y=$'\033[33m'; d=$'\033[31m'; c=$'\033[36m'
banner(){ printf '\n%s%s============================================================%s\n' "$b" "$c" "$r"
          printf '%s%s  %s%s\n' "$b" "$c" "$*" "$r"
          printf '%s%s============================================================%s\n\n' "$b" "$c" "$r"; }
step(){ printf '\n%s▶ %s%s\n' "$b" "$*" "$r"; }
ok(){   printf '  %s✓%s %s\n' "$g" "$r" "$*"; }
warn(){ printf '  %s!%s %s\n' "$y" "$r" "$*" >&2; }
die(){  printf '  %s✗ %s%s\n' "$d" "$*" "$r" >&2; exit 1; }

banner "Repair vLLM tool-call parser"

# --- 1. read the unit (source of truth) -------------------------------------
step "1/4  Inspect the service unit"
[[ -f "${UNIT}" ]] || die "No unit at ${UNIT}. Run ./scripts/install.sh first."

current="$(grep -o -- '--tool-call-parser [A-Za-z0-9_]*' "${UNIT}" | awk '{print $2}' | head -1)" || true
[[ -n "${current}" ]] || die "Unit has no --tool-call-parser flag. Re-run ./scripts/install.sh."

# Derive everything else from the unit so this works with a customised install.
PORT="$(grep -o -- '-p 127\.0\.0\.1:[0-9]*' "${UNIT}" | grep -o '[0-9]*$' | head -1)"; PORT="${PORT:-8000}"
MODEL="$(grep -o -- 'vllm serve [^ ]*' "${UNIT}" | awk '{print $3}' | head -1)"
CONTAINER="$(grep -o -- '--name [A-Za-z0-9_-]*' "${UNIT}" | awk '{print $2}' | head -1)"; CONTAINER="${CONTAINER:-vllm-server}"
[[ -n "${MODEL}" ]] || die "Could not read the model handle from ${UNIT}."
ok "Unit: parser=${current}  port=${PORT}  model=${MODEL}"

# --- 2. patch ---------------------------------------------------------------
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

# A repo checkout alongside us would otherwise reintroduce the bug on reinstall.
# BASH_SOURCE is unset when piped from curl, hence the guard.
self="${BASH_SOURCE[0]:-}"
if [[ -n "${self}" ]]; then
  cfg="$(cd "$(dirname "${self}")" 2>/dev/null && pwd)/config.env"
  if [[ -f "${cfg}" ]] && ! grep -q -- "--tool-call-parser ${WANT}" "${cfg}"; then
    warn "${cfg} still has the old parser — 'git pull' to update it,"
    warn "  otherwise a future ./install.sh will undo this fix."
  fi
fi

# --- 3. restart -------------------------------------------------------------
step "3/4  Restart the model service"
if [[ "${patched}" -eq 1 ]] || ! curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user restart "${SERVICE}.service"
  echo "  Reloading model weights (usually 5-6 min on a Spark)..."
  waited=0; timeout="${VLLM_STARTUP_TIMEOUT:-1800}"
  while (( waited < timeout )); do
    curl -sf "http://localhost:${PORT}/health" >/dev/null 2>&1 && { ok "vLLM healthy after ${waited}s"; break; }
    systemctl --user is-active --quiet "${SERVICE}.service" \
      || { journalctl --user -u "${SERVICE}" -n 30 --no-pager; die "Service died on restart."; }
    sleep 10; waited=$(( waited + 10 )); printf '  ... %ss elapsed\r' "${waited}"
  done
  (( waited < timeout )) || die "Timed out waiting for vLLM."
else
  ok "Service already healthy — leaving it running"
fi

# --- 4. verify for real -----------------------------------------------------
step "4/4  Verify tool calls actually parse"
probe="$(curl -s -X POST "http://localhost:${PORT}/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 847 * 293? Use the calculate tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"calculate\",\"description\":\"Do arithmetic\",\"parameters\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":1200}")"

if grep -q '"tool_calls":[[:space:]]*\[' <<<"${probe}" \
   && grep -q '"finish_reason":[[:space:]]*"tool_calls"' <<<"${probe}"; then
  ok "Tool calls parse correctly (finish_reason=tool_calls)"
  banner "Fixed — agentic mode is working"
  cat <<EOF

  Try it:   cd example && hermes
            "Summarize 2605.28774v1.pdf in 3 sentences."

EOF
else
  warn "Still broken. The model emitted a tool call the server could not parse."
  warn "Server-side detail:"
  journalctl --user -u "${SERVICE}" -n 20 --no-pager 2>/dev/null \
    | grep -i -A3 'Error in extracting tool call' || true
  echo
  warn "Parsers your build supports (try one with: WANT=<name> $0):"
  docker exec "${CONTAINER}" ls /usr/local/lib/python3.12/dist-packages/vllm/tool_parsers/ 2>/dev/null \
    | sed 's/_tool_parser\.py$//' | grep -v '\.py$\|__' | tr '\n' ' ' || warn "  (container not running?)"
  echo
  die "See TROUBLESHOOTING.md"
fi
