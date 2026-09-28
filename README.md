# nous-research-spark

**One-shot installer that turns an NVIDIA DGX Spark into a demo-ready
[Hermes Agent](https://github.com/NousResearch/hermes-agent) box** — a local
LLM served by vLLM, with the self-improving Nous Research agent wired to it and
ready to chat from the terminal.

Run one script. Everything gets installed, configured, and verified.

```bash
git clone https://github.com/nv-drollins/nous-research-spark.git
cd nous-research-spark
./scripts/install.sh
```

When it finishes, just run:

```bash
hermes
```

…and start demoing.

---

## What it sets up

| Component | Details |
|-----------|---------|
| **Model** | `nvidia/Qwen3.6-35B-A3B-NVFP4` — NVIDIA's agent-ready recipe for DGX Spark |
| **Server** | vLLM (`vllm/vllm-openai`) serving an OpenAI-compatible API on `127.0.0.1:8000`, **as a boot-persistent `systemd --user` service** |
| **Agent** | Hermes Agent, installed via the official installer and pointed at the local endpoint |
| **Tools** | web search, browser, terminal, file ops, and code execution enabled out of the box |
| **Verification** | Installer health-gates vLLM and round-trips a real prompt through Hermes before declaring success |

This follows NVIDIA's official
[Run Hermes Agent with a Local LLM](https://build.nvidia.com/spark/hermes-agent/instructions)
and [Serve LLMs with vLLM](https://build.nvidia.com/spark/vllm/instructions)
playbooks, packaged into a single reproducible script.

---

## Requirements

- **DGX Spark (GB10)** running DGX OS / Ubuntu 24.04 (aarch64)
- Docker with the NVIDIA Container Toolkit (ships on DGX OS)
- ~40 GB free disk for the vLLM image + model weights
- Internet access for the first run (to pull the image and model)

The installer checks all of this in its preflight step and tells you exactly
what's missing if anything is.

A HuggingFace token is **optional** — the model is public, but a token lifts
download rate limits. The installer prompts for one and never stores it in the
repo (it's saved with `0600` perms under `~/.hermes-spark/`).

---

## Usage

```bash
./scripts/install.sh              # full install (default)
./scripts/install.sh --skip-vllm  # configure Hermes only (vLLM already running)
./scripts/install.sh --skip-hermes# bring up the vLLM service only
./scripts/install.sh --help
```

The script is **idempotent** — safe to re-run. It skips work that's already
done (existing Hermes install, running service, cached model).

### Configuration

Everything tunable lives in [`scripts/config.env`](scripts/config.env):
the model handle, port, context length, GPU memory fraction, extra vLLM flags,
and which Hermes tools to enable. Edit it before running to customize.

### The Hermes interactive setup wizard

When Hermes is installed for the **first time**, its official installer may drop
you into an interactive setup wizard. If it does, answer as follows — this
points Hermes at the local vLLM endpoint. (The installer re-applies all of this
afterward anyway, so these choices just get you through the wizard cleanly.)

| Prompt | Choose |
|--------|--------|
| Install ripgrep / ffmpeg? | **Enter** (accept default — yes) |
| **How would you like to set up Hermes?** | **Blank Slate** |
| Select provider | **Custom endpoint (enter URL manually)** |
| API base URL | `http://localhost:8000/v1` |
| API key [optional] | leave blank, press **Enter** |
| Model selection | `nvidia/Qwen3.6-35B-A3B-NVFP4` |
| Context length | **Enter** (auto-detect → 262144) |
| Display name | **Enter** (accept default) |
| Select terminal backend | **Keep current (local)** / **Local** |
| Your minimal agent is ready. What next? | **Start with everything disabled — finish now** |

> ⚠️ **Do NOT pick "Quick Setup."** It signs in through the Nous portal instead
> of offering provider selection, so it won't point Hermes at your local model.
> **Blank Slate** is the one you want. "Full setup" also works but asks far more
> than you need.

**Interrupted mid-install?** (e.g. power loss during the Hermes step) Just re-run
`./install.sh`. It's idempotent: if Hermes is already installed it **skips the
wizard entirely**, then re-applies the model config and tool selection and
re-verifies the round-trip. So if the installer "goes right past" the Hermes
prompts on a re-run, that's expected and correct — it means Hermes was already
in place from the interrupted attempt.

---

## Try it out

The [`example/`](example/) folder has a sample research paper
(`2605.28774v1.pdf`) and a ready-made list of demo questions — from quick
summaries to live tool-calling and skill creation — so you can show the agent
off immediately:

```bash
cd example
hermes
```

See [`example/README.md`](example/README.md) for the full question set and a
suggested 3-minute demo flow.

## Troubleshooting

**Agent spins for a second, then returns to the prompt with no answer?** That
is a `--tool-call-parser` mismatch — the most likely problem you'll hit. Run:

```bash
./scripts/fix-tool-parser.sh
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the diagnosis and the why.

---

## Operating the box

```bash
# Chat with the agent
hermes

# Model service status / logs
systemctl --user status vllm-server
journalctl --user -u vllm-server -f

# Is the model API up?
curl -s http://localhost:8000/v1/models

# Restart / stop the model service
systemctl --user restart vllm-server
systemctl --user stop vllm-server
```

The vLLM service is enabled with **linger**, so it starts automatically on boot
without an interactive login. After a reboot, give it a minute or two to reload
the model weights before the first prompt.

---

## How it fits together

```
┌────────────────────────────────────────────────────────────┐
│  DGX Spark (GB10, 128GB unified memory)                     │
│                                                            │
│   systemd --user ─► docker ─► vLLM ─► Qwen3.6-35B-A3B-NVFP4 │
│                        │                                   │
│                        ▼                                   │
│              127.0.0.1:8000/v1  (OpenAI-compatible)        │
│                        ▲                                   │
│                        │                                   │
│                     Hermes Agent  ◄─ you, in the terminal  │
└────────────────────────────────────────────────────────────┘
```

The model endpoint is bound to **localhost only** — it is not exposed to the LAN.

---

## Uninstall

```bash
# Stop + remove the model service
systemctl --user disable --now vllm-server
rm ~/.config/systemd/user/vllm-server.service && systemctl --user daemon-reload

# Remove Hermes (keeps ~/.hermes data unless you choose full uninstall)
hermes uninstall

# Optional: reclaim disk
docker rmi vllm/vllm-openai:latest
rm -rf ~/.cache/huggingface/hub/models--nvidia--Qwen3.6-35B-A3B-NVFP4
```

---

## License

MIT — see [LICENSE](LICENSE).

Hermes Agent is a project of [Nous Research](https://nousresearch.com).
Model and playbooks © NVIDIA.
