#!/usr/bin/env bash
# ============================================================================
#  lib.sh — helper functions for the nous-research-spark installer
# ============================================================================

# ---- pretty output ---------------------------------------------------------
_c_reset=$'\033[0m'; _c_bold=$'\033[1m'; _c_grn=$'\033[32m'
_c_ylw=$'\033[33m'; _c_red=$'\033[31m'; _c_cyn=$'\033[36m'

banner() { echo; echo "${_c_bold}${_c_cyn}============================================================${_c_reset}"; \
           echo "${_c_bold}${_c_cyn}  $*${_c_reset}"; \
           echo "${_c_bold}${_c_cyn}============================================================${_c_reset}"; echo; }
step()   { echo; echo "${_c_bold}▶ $*${_c_reset}"; }
ok()     { echo "  ${_c_grn}✓${_c_reset} $*"; }
warn()   { echo "  ${_c_ylw}!${_c_reset} $*" >&2; }
die()    { echo "  ${_c_red}✗ $*${_c_reset}" >&2; exit 1; }

STATE_DIR="${HOME}/.hermes-spark"
mkdir -p "${STATE_DIR}"

# ---- Step 1: preflight -----------------------------------------------------
preflight() {
  [[ "$(uname -s)" == "Linux" ]] || die "This installer targets Linux (DGX OS)."
  ok "OS: $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-Linux}")  ($(uname -m))"

  for bin in curl git docker; do
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found. Install it and re-run."
  done
  ok "curl / git / docker present"

  # docker usable without sudo?
  if ! docker ps >/dev/null 2>&1; then
    warn "Docker needs sudo for the current user. Adding you to the 'docker' group..."
    sudo usermod -aG docker "$USER" || die "Could not add user to docker group."
    die "Added to 'docker' group. Log out/in (or run: newgrp docker) and re-run this installer."
  fi
  ok "Docker usable without sudo"

  # nvidia runtime present?
  if docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia'; then
    ok "NVIDIA container runtime available"
  else
    warn "NVIDIA container runtime not detected in 'docker info'. GPU passthrough may fail."
  fi

  # GPU visible?
  if command -v nvidia-smi >/dev/null 2>&1; then
    ok "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo '?')"
  else
    warn "nvidia-smi not found on host (container GPU access may still work)."
  fi

  # user systemd (for the boot-persistent service)?
  if systemctl --user show-environment >/dev/null 2>&1; then
    ok "systemd user instance available"
  else
    warn "No systemd --user session. Will enable linger so the service can run on boot."
  fi
}

# ---- Step 2: HF token ------------------------------------------------------
prompt_hf_token() {
  HF_TOKEN="${HF_TOKEN:-}"
  # reuse a previously saved token
  if [[ -z "${HF_TOKEN}" && -f "${STATE_DIR}/hf_token" ]]; then
    HF_TOKEN="$(cat "${STATE_DIR}/hf_token")"
    [[ -n "${HF_TOKEN}" ]] && ok "Reusing saved HuggingFace token from ${STATE_DIR}/hf_token"
  fi
  if [[ -z "${HF_TOKEN}" ]]; then
    echo "  The model '${MODEL_HANDLE}' is public, so a token is optional."
    echo "  Providing one lifts HF download rate limits (recommended)."
    if [[ -t 0 ]]; then
      read -r -s -p "  Paste HuggingFace token (hf_...) or press Enter to skip: " HF_TOKEN
      echo
    else
      warn "Non-interactive shell; proceeding without an HF token."
    fi
  fi
  if [[ -n "${HF_TOKEN}" ]]; then
    umask 077; printf '%s' "${HF_TOKEN}" > "${STATE_DIR}/hf_token"
    ok "HuggingFace token stored (0600) at ${STATE_DIR}/hf_token"
  else
    rm -f "${STATE_DIR}/hf_token" 2>/dev/null || true
    warn "No token set — downloads use anonymous rate limits."
  fi
  export HF_TOKEN
}

# ---- Step 3: vLLM systemd service -----------------------------------------
install_vllm_service() {
  # Ensure the service can run on boot even without an interactive login.
  loginctl enable-linger "$USER" >/dev/null 2>&1 || warn "Could not enable linger (service may only run while logged in)."

  local unit_dir="${HOME}/.config/systemd/user"
  mkdir -p "${unit_dir}"
  local hf_cache="${HOME}/.cache/huggingface"
  mkdir -p "${hf_cache}"

  # HF token file for EnvironmentFile (may be empty)
  local envfile="${STATE_DIR}/vllm.env"
  umask 077
  {
    echo "VLLM_IMAGE=${VLLM_IMAGE}"
    echo "HF_TOKEN=${HF_TOKEN:-}"
  } > "${envfile}"

  # Build the vLLM serve args
  local serve_args="--max-model-len ${MAX_MODEL_LEN} --gpu-memory-utilization ${GPU_MEMORY_UTILIZATION} ${VLLM_EXTRA_ARGS}"

  local unit_path="${unit_dir}/${VLLM_SERVICE}.service"
  local new_unit; new_unit="$(cat <<EOF
[Unit]
Description=vLLM OpenAI server (${MODEL_HANDLE}) for Hermes on DGX Spark
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${envfile}
# Clean up any stale container from a previous run
ExecStartPre=-/usr/bin/docker rm -f ${VLLM_CONTAINER}
ExecStart=/usr/bin/docker run --rm --name ${VLLM_CONTAINER} \\
  --gpus all --ipc host \\
  --ulimit memlock=-1 --ulimit stack=67108864 \\
  --entrypoint "" \\
  -p 127.0.0.1:${VLLM_PORT}:8000 \\
  -e HF_TOKEN \\
  -v ${hf_cache}:/root/.cache/huggingface \\
  \${VLLM_IMAGE} \\
  vllm serve ${MODEL_HANDLE} ${serve_args}
ExecStop=/usr/bin/docker stop ${VLLM_CONTAINER}
Restart=on-failure
RestartSec=10
# Model load can take a while on first download
TimeoutStartSec=0

[Install]
WantedBy=default.target
EOF
)"

  # Idempotency: only rewrite + restart when the unit actually changed, or
  # when the service isn't currently healthy. This avoids a needless (and
  # slow) model reload on a re-run of a healthy demo box.
  local changed=1
  if [[ -f "${unit_path}" ]] && diff -q <(printf '%s\n' "${new_unit}") "${unit_path}" >/dev/null 2>&1; then
    changed=0
  fi
  printf '%s\n' "${new_unit}" > "${unit_path}"
  systemctl --user daemon-reload
  systemctl --user enable "${VLLM_SERVICE}.service" >/dev/null 2>&1 || true

  if [[ "${changed}" -eq 0 ]] \
     && systemctl --user is-active --quiet "${VLLM_SERVICE}.service" \
     && curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
    ok "vLLM service already running and healthy — leaving it untouched (unit unchanged)"
    return 0
  fi

  if [[ "${changed}" -eq 0 ]]; then
    ok "Unit unchanged; ensuring service is started"
    systemctl --user start "${VLLM_SERVICE}.service"
  else
    ok "Wrote user unit ${unit_path}"
    systemctl --user restart "${VLLM_SERVICE}.service"
  fi
  ok "Service ${VLLM_SERVICE} active (bound to 127.0.0.1:${VLLM_PORT}, restarts on boot)"
}

wait_for_vllm() {
  echo "  Waiting for the model to load (first run downloads weights; up to ${VLLM_STARTUP_TIMEOUT}s)..."
  local waited=0 interval=10
  while (( waited < VLLM_STARTUP_TIMEOUT )); do
    if curl -sf "http://localhost:${VLLM_PORT}/health" >/dev/null 2>&1; then
      ok "vLLM is healthy at http://localhost:${VLLM_PORT}"
      # confirm the model handle is being served
      if curl -sf "http://localhost:${VLLM_PORT}/v1/models" 2>/dev/null | grep -q "${MODEL_HANDLE}"; then
        ok "Serving model: ${MODEL_HANDLE}"
      fi
      return 0
    fi
    # bail early if the service died
    if ! systemctl --user is-active --quiet "${VLLM_SERVICE}.service"; then
      warn "vLLM service is not active. Recent logs:"
      journalctl --user -u "${VLLM_SERVICE}.service" -n 30 --no-pager 2>/dev/null || true
      die "vLLM failed to start. See logs above."
    fi
    sleep "${interval}"; waited=$(( waited + interval ))
    printf '  ... %ss elapsed\r' "${waited}"
  done
  die "Timed out after ${VLLM_STARTUP_TIMEOUT}s waiting for vLLM. Check: journalctl --user -u ${VLLM_SERVICE} -e"
}

# ---- Step 4: Hermes install ------------------------------------------------
install_hermes() {
  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v hermes >/dev/null 2>&1; then
    ok "Hermes already installed ($(hermes --version 2>/dev/null | head -1 || echo present)) — skipping installer"
    return 0
  fi
  echo "  Running the official Hermes installer (non-interactive)..."
  # Piping to bash runs the installer without the interactive wizard; we
  # configure the endpoint ourselves in the next step (documented fallback).
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash \
    || die "Hermes installer failed."
  export PATH="${HOME}/.local/bin:${PATH}"
  command -v hermes >/dev/null 2>&1 || die "hermes not on PATH after install (expected ~/.local/bin/hermes)."
  ok "Hermes installed: $(command -v hermes)"
}

# ---- Step 5: Hermes config + tools ----------------------------------------
configure_hermes() {
  export PATH="${HOME}/.local/bin:${PATH}"
  hermes config set model.provider "${HERMES_PROVIDER}" >/dev/null
  hermes config set model.base_url "${HERMES_BASE_URL}"  >/dev/null
  hermes config set model.default  "${HERMES_MODEL}"     >/dev/null
  ok "Hermes -> provider=${HERMES_PROVIDER}, base_url=${HERMES_BASE_URL}, model=${HERMES_MODEL}"
}

enable_hermes_tools() {
  export PATH="${HOME}/.local/bin:${PATH}"
  [[ -z "${HERMES_TOOLS// }" ]] && { warn "No tools requested in config; leaving minimal."; return 0; }
  # Hermes exposes toolset enablement via the `hermes tools enable NAME`
  # subcommand (NOT a config.yaml key). Tool changes apply on the next
  # session, which is exactly what we want for a fresh demo box.
  local enabled=()
  IFS=',' read -r -a _tools <<< "${HERMES_TOOLS}"
  for t in "${_tools[@]}"; do
    t="$(echo "$t" | xargs)"; [[ -z "$t" ]] && continue
    if hermes tools enable "$t" >/dev/null 2>&1; then
      enabled+=("$t")
    else
      warn "Could not enable toolset '${t}' (enable it later with: hermes tools)"
    fi
  done
  if ((${#enabled[@]})); then ok "Enabled toolsets: ${enabled[*]}"; fi
}

# ---- Step 6: verify --------------------------------------------------------
verify_stack() {
  export PATH="${HOME}/.local/bin:${PATH}"
  # 1) endpoint reachable
  curl -sf "http://localhost:${VLLM_PORT}/v1/models" >/dev/null 2>&1 \
    && ok "vLLM /v1/models reachable" \
    || warn "vLLM /v1/models not reachable"

  # 2) tool-calling actually parses.
  # This is the check that matters for an AGENT box. A plain text round-trip
  # passes even when --tool-call-parser is wrong; tool calls then silently fail
  # to parse and the agent looks like it "does nothing". Assert a real tool call
  # comes back as structured tool_calls (not raw text stuck in `content`).
  echo "  Verifying tool-call parsing (--tool-call-parser ${VLLM_EXTRA_ARGS##*--tool-call-parser })..."
  local tc_probe
  tc_probe="$(curl -s -X POST "http://localhost:${VLLM_PORT}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL_HANDLE}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 847 * 293? Use the calculate tool.\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"calculate\",\"description\":\"Do arithmetic\",\"parameters\":{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\"}},\"required\":[\"expression\"]}}}],\"tool_choice\":\"auto\",\"max_tokens\":1200}" 2>/dev/null)"
  if echo "${tc_probe}" | grep -q '"tool_calls":[[:space:]]*\[' \
     && echo "${tc_probe}" | grep -q '"finish_reason":[[:space:]]*"tool_calls"'; then
    ok "Tool calls parse correctly (finish_reason=tool_calls)"
  else
    warn "TOOL CALLING IS BROKEN — the model emitted a tool call the server could not parse."
    warn "  The agent will accept prompts, think, then return to the prompt without acting."
    warn "  Almost always a --tool-call-parser mismatch in scripts/config.env."
    warn "  Qwen3.x emits XML tool calls and needs: --tool-call-parser qwen3_xml"
    warn "  Check the server side with: journalctl --user -u ${VLLM_SERVICE} | grep -i 'Error in extracting tool call'"
  fi

  # 3) hermes can call the model non-interactively
  echo "  Asking Hermes to round-trip a prompt through the local model..."
  local out
  # `hermes chat -q` is the canonical non-interactive query; `-z` is an alias
  # in some builds. Try the documented form first, then fall back.
  if out="$(hermes chat -q 'Reply with exactly: HERMES_OK' 2>/dev/null)" \
     || out="$(hermes -z 'Reply with exactly: HERMES_OK' 2>/dev/null)"; then
    if echo "$out" | grep -q 'HERMES_OK'; then
      ok "Hermes <-> vLLM round-trip succeeded (HERMES_OK)"
    else
      warn "Hermes replied but not exactly HERMES_OK. Raw: $(echo "$out" | tail -1)"
    fi
  else
    warn "Non-interactive round-trip failed. Try 'hermes' interactively and send 'hello'."
  fi
}
