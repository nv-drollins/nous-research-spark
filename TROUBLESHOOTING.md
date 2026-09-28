# Troubleshooting

## Hermes accepts a prompt, thinks for a second, then returns to the prompt with no answer

**Symptom.** The install completes and reports success. `hermes` starts fine.
You ask a demo question, the spinner runs briefly, and then you are back at an
empty prompt. No answer, no error, no crash. Plain chat ("hi") may work while
every question that requires a tool silently does nothing.

**Cause.** vLLM was started with the wrong `--tool-call-parser`, so it cannot
parse the tool calls the model emits.

Versions of this repo before commit `48d09c3` shipped:

```bash
--tool-call-parser hermes     # WRONG for Qwen3.x
```

`hermes` here is a **JSON** parser named after the Hermes *model family*. It has
nothing to do with Hermes Agent — that name collision is the whole trap. Qwen3.x
emits tool calls as **XML**:

```xml
<tool_call>
<function=calculate>
<parameter=expression>
847 * 293
</parameter>
</function>
</tool_call>
```

The JSON parser chokes on the first character, and **the failure is silent at
every layer**:

1. vLLM logs a `JSONDecodeError`, swallows it, and returns
   `finish_reason: stop` with `tool_calls: null` and the raw XML stranded in
   `content`.
2. Hermes sees a turn with no tool call and no real answer. Its stall guard
   re-prompts twice, gives up, and ends the turn with `tool_turns=0`.
3. You get the prompt back.

Because plain text round-trips fine, the box looks healthy. Only *tool use* is
broken — which is the entire example demo.

---

### Diagnose (30 seconds)

The server tells you directly. This is the single most useful command:

```bash
journalctl --user -u vllm-server --no-pager | grep -i "Error in extracting tool call"
```

If you see `hermes_tool_parser.py` and `JSONDecodeError`, that is this bug:

```
ERROR [hermes_tool_parser.py:117] Error in extracting tool call from response.
json.decoder.JSONDecodeError: Expecting value: line 2 column 1 (char 1)
```

Confirm which parser is actually running:

```bash
journalctl --user -u vllm-server --no-pager | grep -o "'tool_call_parser': '[^']*'" | tail -1
```

Check the agent side too — `tool_turns=0` on a question that clearly needs a
tool is the tell:

```bash
grep -E "Reasoning-only|Stall guard|Turn ended" ~/.hermes/logs/agent.log | tail
```

---

### Fix

**Already installed and broken?** A `git pull` alone will **not** fix it — the
bad parser is baked into `~/.config/systemd/user/vllm-server.service`, which no
pull ever touches. Run the repair script. It needs no repo, no config and no
arguments (it reads everything from the installed unit):

```bash
curl -fsSL https://raw.githubusercontent.com/nv-drollins/nous-research-spark/main/scripts/fix-tool-parser.sh | bash
```

If you do have the repo checked out, `./scripts/fix-tool-parser.sh` works too.
Either way it is idempotent: on an already-fixed box it reports "no change
needed" and skips the ~6 minute model reload.

Or do it by hand:

```bash
# 1. Patch the running service unit
sed -i 's/--tool-call-parser hermes/--tool-call-parser qwen3_xml/' \
  ~/.config/systemd/user/vllm-server.service

# 2. Reload and restart (model reload takes ~5-6 min on a Spark)
systemctl --user daemon-reload
systemctl --user restart vllm-server

# 3. Wait for health
until curl -sf http://localhost:8000/health >/dev/null; do sleep 10; done
```

Also update `scripts/config.env` so a future re-install does not reintroduce it
(already fixed if you pulled):

```bash
VLLM_EXTRA_ARGS="--reasoning-parser qwen3 --enable-auto-tool-choice --tool-call-parser qwen3_xml"
```

> **Valid parser names in vLLM 0.30** are `qwen3_coder` and `qwen3_xml` (both
> map to `Qwen3EngineToolParser`). Note the module moved to `vllm.tool_parsers`
> in 0.30 — it was `vllm.entrypoints.openai.tool_parsers` in earlier releases.
>
> List what your build actually supports:
> ```bash
> docker exec vllm-server ls /usr/local/lib/python3.12/dist-packages/vllm/tool_parsers/
> ```

---

### Verify the fix

The check that matters is that a tool call comes back as **structured
`tool_calls`**, not as text stuck in `content`:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' -d '{
    "model": "nvidia/Qwen3.6-35B-A3B-NVFP4",
    "messages": [{"role":"user","content":"What is 847 * 293? Use the calculate tool."}],
    "tools": [{"type":"function","function":{
      "name":"calculate","description":"Do arithmetic",
      "parameters":{"type":"object","properties":{"expression":{"type":"string"}},
      "required":["expression"]}}}],
    "tool_choice": "auto", "max_tokens": 1200
  }' | python3 -m json.tool
```

**Good** — parser is correct:

```json
"finish_reason": "tool_calls",
"message": {
  "content": null,
  "tool_calls": [{"function": {"name": "calculate",
                  "arguments": "{\"expression\": \"847 * 293\"}"}}]
}
```

**Bad** — still broken:

```json
"finish_reason": "stop",
"message": {"content": "<tool_call>\n<function=calculate>...", "tool_calls": null}
```

Then confirm end to end:

```bash
cd example && hermes -z "Summarize 2605.28774v1.pdf in 3 sentences."
# Expect: a real summary. Before the fix you get silence or a non-answer.
```

> Avoid "how many pages is the PDF?" as your smoke test. `file` reports 13 for
> this document (it reads the first `/Count` in the page tree, a sub-node);
> the true count is 41, per `pdfinfo`. A correct agent can still look wrong if
> it happens to trust `file`. Test the plumbing, not the trivia.

---

### Why the installer did not catch this

The original `verify_stack()` only round-tripped a plain-text prompt, which
passes even when tool calling is completely broken. That is why a fresh install
reported success on a box whose demo could not work.

As of `48d09c3` the installer probes a real tool call and asserts
`finish_reason=tool_calls`, so a parser mismatch now fails loudly at install
time with the fix in the message.

---

### Applying this to a different model

This bug is not Qwen-specific — **the parser must match the format the model
emits, never the name of the agent or the serving stack**. If you swap
`MODEL_HANDLE` in `scripts/config.env`, update `--tool-call-parser` to match:

| Model family | Parser |
|---|---|
| Qwen3.x (incl. Qwen3.6-NVFP4) | `qwen3_xml` (or `qwen3_coder`) |
| Hermes / NousResearch models | `hermes` |
| Llama 3.x | `llama3_json` |
| Mistral | `mistral` |
| DeepSeek V3 | `deepseek_v3` |

When in doubt: send the `curl` probe above and look at whether the tool call
arrives in `tool_calls` or leaks into `content`.
