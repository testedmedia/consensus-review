# consensus-review

Adversarial multi-model review of any plan, decision, design doc, or piece of work.

Routes the same proposal through three frontier models in parallel, with each instructed to **attack** the proposal and surface weaknesses. The orchestrator (e.g. your coding assistant) then synthesizes the attacks into a deduped, ranked punch list.

Use it when:
- Stakes are high (production launch, irreversible decision, client-facing deliverable)
- A single-model review already passed but you want a stress test
- You suspect you're missing something and one model alone might share your blind spots

## Models

| Model | Provider | Why it's in the panel |
|-------|----------|-----------------------|
| **GPT-5.5** | OpenAI (`/v1/responses`) | Deep reasoning, strict on architecture (set `CONSENSUS_GPT5_MODEL=gpt-5.5-pro` for max depth — costs ~30-60s extra latency) |
| **Gemini 3.1 Pro** | OpenRouter | Different training distribution, catches cross-platform / runtime / timezone bugs |
| **Kimi K2.6** | Moonshot direct | Non-US training lineage, long-horizon reasoning, strong on agentic flows |

You can run a subset (e.g. just GPT-5.5 + Gemini) with `--models gpt5,gemini`.

## Install

```bash
git clone https://github.com/<owner>/consensus-review.git
cd consensus-review
chmod +x scripts/consensus-review.sh
```

Optionally add it to your PATH:

```bash
ln -s "$PWD/scripts/consensus-review.sh" /usr/local/bin/consensus-review
```

### Use as a Claude Code skill

If you use [Claude Code](https://docs.anthropic.com/claude/docs/claude-code), drop the `SKILL.md` into your skills directory so it activates on natural-language triggers ("consensus review", "attack this", "find weaknesses", etc.):

```bash
mkdir -p ~/.claude/skills/consensus-review
cp SKILL.md ~/.claude/skills/consensus-review/
# Update the script path inside SKILL.md to wherever you cloned this repo.
```

## API keys

Set whichever you have. Missing keys cause the corresponding model to be skipped (the script still runs the others).

```bash
export OPENAI_API_KEY=sk-...
export OPENROUTER_API_KEY=sk-or-...
export MOONSHOT_API_KEY=sk-...
```

Get keys:
- OpenAI: https://platform.openai.com/api-keys
- OpenRouter: https://openrouter.ai/keys
- Moonshot (Kimi): https://platform.moonshot.ai/console/api-keys

> Note: `gpt-5.5` requires an OpenAI org with access to the GPT-5.5 family. If your org isn't on that tier you'll see `insufficient_quota` errors. Swap to another model via `CONSENSUS_GPT5_MODEL=<model-id>` or run a subset with `--models gemini,kimi`.

## Usage

```bash
# Inline
./scripts/consensus-review.sh "Topic" "Body of the proposal to attack."

# From a file
./scripts/consensus-review.sh --file proposal.md "Topic"

# Run a subset of models
./scripts/consensus-review.sh --models gpt5,gemini "Topic" "Body"
```

Optional env knobs:

| Env var | Default | What it does |
|---------|---------|--------------|
| `CONSENSUS_OUT_DIR` | `./consensus-reviews` | Where reports are written |
| `CONSENSUS_MAX_TOKENS` | `16000` | Per-model token budget |
| `CONSENSUS_REASONING` | `medium` | GPT-5 reasoning effort (`minimal`/`low`/`medium`/`high`) — bump to `high` for deeper critique, costs latency |
| `CONSENSUS_GPT5_MODEL` | `gpt-5.5` | OpenAI model id — use `gpt-5.5-pro` for max depth (+30-60s latency) |

## Output

A markdown report at `$CONSENSUS_OUT_DIR/YYYY-MM-DD_<slug>.md`:

1. **Topic** + **Proposal** (verbatim)
2. **Per-model attacks** — each model's ranked attack list
3. **Synthesis** — empty section for your assistant to fill in with the deduped, ranked punch list

The script intentionally does **not** auto-synthesize; that step belongs to the orchestrator in the loop (you, or a coding agent reading the report). That's the design — the script is the data layer, synthesis is the judgment layer.

## Prompt design

Every model gets the same adversarial prompt:

- "Praise is failure." Models are explicitly told not to balance or be diplomatic.
- Minimum 8 distinct attack vectors required.
- At least 2 attacks must be second-order (emergent at scale / over time / under load / under adversarial probing).
- Explicit edge-case checklist (empty inputs, race conditions, clock skew, retries without idempotency, etc.).
- Final line is a one-word verdict: `SHIP / REVISE / REJECT`.

This is deliberately tuned to defeat the helpful-assistant tendency to soften findings. See `scripts/consensus-review.sh` for the full prompt template.

## How this differs from a single-model review

A single model's blind spots correlate strongly within its training distribution. Three models trained on different corpora produce attacks that overlap on the obvious issues and diverge on the non-obvious ones — and the **unique** findings (only one model caught) are often the most valuable.

## Requirements

- Bash
- `curl`
- `python3` (used for JSON build/parse — no extra packages)
- macOS or Linux

## License

MIT
