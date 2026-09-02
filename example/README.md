# Example: Demo the Agent with a Research Paper

This folder contains a sample document you can use to demo Hermes Agent on the
DGX Spark, plus a set of ready-to-ask questions that show off the agent's
reasoning, tool use, and file handling — all running locally against the
`Qwen3.6-35B-A3B-NVFP4` model served by vLLM.

## The document

**`2605.28774v1.pdf`** — *"Agent Explorative Policy Optimization for Multimodal
Agentic Reasoning"* (AXPO), Kang et al., NVIDIA & KAIST, arXiv:2605.28774.

A ~13-page ML research paper. In one sentence: agentic RL (GRPO) under-trains
the *tool-calling* behavior of vision-language models — the authors call this
the **Thinking-Acting Gap** — and their method, **AXPO**, fixes it by
*resampling the tool call* from a fixed "thinking" prefix, so an 8B model can
match a 32B model on Pass@4 with 4× fewer parameters.

It's a great demo doc because it's dense, technical, has tables and numbers to
extract, and rewards multi-step reasoning — exactly what a capable local agent
should handle.

## How to run the demo

1. Make sure the stack is up (from the repo root, `./install.sh` — or check
   `systemctl --user status vllm-server`).
2. Start the agent from this folder so it can see the PDF:
   ```bash
   cd example
   hermes
   ```
3. Ask the questions below. Tip: run `/reasoning show` first so the audience can
   watch the model think through multi-step questions.

> The `file` and `code_execution` tools (enabled by the installer) let Hermes
> read the PDF and do arithmetic on the numbers it extracts. `web`/`browser`
> let it pull in outside context. `terminal` lets it work with the file on disk.

---

## Demo questions

Grouped from a quick warm-up to more involved, capability-showing asks. Every
question is answerable from the PDF (or verifiable), so you can confirm the
agent is right in real time.

### 1. Warm-up — reading & summarizing (shows: file tool, comprehension)

- "Read `2605.28774v1.pdf` in this folder and summarize it in 3 sentences for a
  non-expert."
- "What problem does this paper set out to solve, and what's the one-line pitch
  of their solution?"
- "Who are the authors and what institutions are they from? What's the arXiv ID?"
- "What is the 'Thinking-Acting Gap'? Explain it like I'm a new ML engineer."

### 2. Fact extraction — precision & tables (shows: careful reading, no hallucination)

- "What three tools does the model have access to during agentic reasoning?"
  *(Expected: a Python interpreter, a web search engine — Tavily API — and an
  image zoom-in tool.)*
- "Which nine benchmarks do they evaluate on, and what three categories are they
  grouped into?" *(Reasoning: MathVision, DynaMath, Math-VR; Perception: V\*,
  VisualProbe, HR-Bench-4K, HR-Bench-8K; Search: HR-MMSearch, MMSearch.)*
- "What base model and sizes are used in the experiments?"
  *(Qwen3-VL-Thinking at 2B / 4B / 8B, with 32B as an inference-only baseline.)*
- "Under plain GRPO, what fraction of rollouts actually attempt a tool call, and
  how often does the whole tool-using subgroup get the answer wrong?"
  *(~20–35% attempt tools; the tool-using subgroup is all-wrong on ~40% of
  questions vs ~25% for no-tool.)*

### 3. Reasoning & synthesis (shows: multi-step reasoning, the local model's quality)

- "Explain the core mechanism of AXPO — 'tool-call resampling' — in plain
  English. Why resample the tool call instead of re-rolling the whole
  trajectory?"
- "The paper lists three design choices AXPO makes on top of GRPO. What are they
  and why does each one matter?"
- "Why is tool use described as 'high-variance' while thinking is the 'safe
  default'? Give a concrete example from the paper."
- "What's the significance of the claim that an 8B model beats the 32B baseline
  on Pass@4? Why does that matter for someone deploying on a single Spark?"

### 4. Tool use — make it compute (shows: code_execution / terminal live)

- "From Table 1, at 8B, SFT+AXPO scores 62.3 average Pass@1 and SFT+GRPO scores
  60.5. Calculate the improvement and express it as a percentage gain. Use the
  code tool to be exact."
- "The paper says +25% extra resampling budget with AXPO beats +100% extra
  rollout budget with GRPO. If a GRPO run used 8 rollouts per question, how many
  does each approach use? Show the math."
- "Count how many pages the PDF has and how large the file is on disk."
  *(Uses the terminal/file tools on the real file.)*
- "Pull out every Pass@1 average score for the 8B model block (Base, GRPO, SFT,
  SFT+GRPO, SFT+AXPO) and make me a small markdown table sorted best to worst."

### 5. Grounded outside context (shows: web/browser tool + local doc together)

- "This paper builds on GRPO. Briefly, what is GRPO and where did it come from?
  Use web search, then relate it back to what this paper changes."
- "Find the project page for this paper and tell me what's on it."
  *(Hint in the PDF metadata: byungkwanlee.github.io/AXPO-page.)*
- "Are there other recent papers tackling tool-use exploration in agentic RL?
  Search, then contrast one with AXPO's approach."

### 6. Show off the agent platform (shows: skills, memory, cron — Hermes-specific)

- "Turn this paper into a 5-bullet briefing I could paste into Slack, then save
  the approach as a skill so you can do it for the next paper faster."
- "Remember that I care about parameter-efficiency and local deployment on DGX
  Spark — tailor future paper summaries to that angle."
- "Every weekday at 9am, check arXiv cs.CL for new papers about agentic
  reinforcement learning and send me the 3 most relevant titles."
  *(Great for showing built-in cron scheduling.)*

### 7. Stress / honesty check (shows: the agent won't make things up)

- "What learning rate and batch size did they use for RL training?" *(If it's
  not in the main text, a good agent says so or points to the appendix rather
  than inventing numbers.)*
- "Does this paper report results on text-only (non-multimodal) benchmarks?"
  *(Expected: no — it's specifically about multimodal agentic reasoning.)*
- "Summarize the paper's limitations." *(Tests whether it distinguishes what the
  paper actually says from plausible-sounding filler.)*

---

## Suggested 3-minute demo flow

1. `/reasoning show`, then **Q1** ("summarize in 3 sentences") — instant payoff.
2. **Q2** ("which nine benchmarks…") — precise extraction, audience can verify
   against the paper.
3. **Q4** ("calculate the improvement… use the code tool") — watch it call the
   Python tool live and compute on the numbers it just read.
4. **Q6** ("turn this into a Slack briefing and save it as a skill") — shows the
   self-improving angle unique to Hermes.

All of it runs on the Spark. Nothing leaves the box unless you ask a
web-search question.
