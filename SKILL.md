---
name: consensus-review
description: >
  Adversarial multi-model review of a plan, decision, output, or piece of work.
  Routes the same prompt through GPT-5.5, Gemini 3.1 Pro, and Kimi K2.6
  with instructions to ATTACK the points, find weaknesses, and propose
  improvements. The orchestrator then synthesizes the attacks into a ranked
  punch list.
  Use when the user says "consensus review", "attack this", "find weaknesses",
  "review with all models", "second opinion on this", "stress test this",
  or "get consensus on".
---

# Consensus Review — Adversarial Multi-Brain Critique

Routes a single proposal through multiple frontier models in parallel with an adversarial prompt, then synthesizes the attacks into a prioritized action list. Unlike a balanced multi-model panel, every model is told to find reasons the proposal is wrong.

## Activation

Trigger on phrases like:
- "consensus review"
- "attack this"
- "find weaknesses in this"
- "review with all models" / "review with gpt and gemini and kimi"
- "dual runthrough" / "triple runthrough"
- "get a second / third opinion"
- "what could break this"
- "stress test this decision"
- "are there any ways to improve this"

## Models Used (Default)

| Model | Via | Role |
|-------|-----|------|
| **GPT-5.5** | Direct OpenAI Responses API | Deep reasoning, strict on architecture (set `CONSENSUS_GPT5_MODEL=gpt-5.5-pro` for max depth) |
| **Gemini 3.1 Pro** | OpenRouter (`google/gemini-3.1-pro-preview`) | Different training, different blind spots |
| **Kimi K2.6** | Moonshot direct (`kimi-k2.6` @ `api.moonshot.ai`) | Long-horizon reasoning, different lineage |

Override with `--models gpt5,gemini` to skip Kimi, etc.

## Usage

```bash
# Inline
bash <path-to-repo>/scripts/consensus-review.sh "<topic>" "<proposal body>"

# From a file
bash <path-to-repo>/scripts/consensus-review.sh --file /path/to/proposal.md "<topic>"

# Subset
bash <path-to-repo>/scripts/consensus-review.sh --models gpt5,gemini "<topic>" "<body>"
```

> Update the path above to point at your local clone (e.g. `~/tools/consensus-review/scripts/consensus-review.sh`).

## Required environment

```bash
export OPENAI_API_KEY=sk-...
export OPENROUTER_API_KEY=sk-or-...
export MOONSHOT_API_KEY=sk-...
```

Missing keys → that model is skipped, the others still run.

## Output Format

The script produces a markdown report at `$CONSENSUS_OUT_DIR/YYYY-MM-DD_<slug>.md` (default `./consensus-reviews/`) with:

1. **Topic** and **Proposal** (verbatim)
2. **Per-model attacks** — each model's ranked attack list with severities
3. **Synthesis** — left empty for the orchestrating session to fill in

When this skill fires, after the script returns you should:

1. Read the per-model attacks from the report
2. Group attacks that 2+ models independently surfaced (the convergent findings)
3. Call out the unique findings (only one model caught) — these are often the highest signal
4. Produce a ranked punch list: CRITICAL → HIGH → MEDIUM → LOW
5. End with a synthesized one-word verdict: SHIP / REVISE / REJECT

## Prompt Engineering (Critical)

The per-model prompt is deliberately adversarial — see `scripts/consensus-review.sh` for the verbatim text. Key constraints baked into the prompt:

- "Praise is failure" — models are explicitly told not to soften
- Minimum 8 distinct attack vectors required
- At least 2 attacks must be second-order (emergent at scale / over time / under load)
- Explicit edge-case checklist (empty inputs, race conditions, clock skew, retries without idempotency, etc.)
- Final line must be a one-word verdict

This defeats the "helpful assistant" tendency that makes models soften findings.

## When NOT To Use

- Routine, low-stakes decisions (one model's review is sufficient)
- Time-sensitive hotfixes (consensus adds ~30-60s of latency)
- Pure research questions (use a normal multi-model query instead)
- Creative brainstorming (you want balanced exchange, not attacks)
