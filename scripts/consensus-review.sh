#!/usr/bin/env bash
# consensus-review.sh — Adversarial multi-model critique.
#
# Routes the same proposal through three frontier models in parallel:
#   - GPT-5.5-pro      (OpenAI Responses API)
#   - Gemini 3.1 Pro   (via OpenRouter)
#   - Kimi K2.6        (Moonshot direct)
#
# Each model is prompted to ATTACK the proposal and surface weaknesses.
# Outputs a single markdown report with per-model attacks, ready for synthesis.
#
# Usage:
#   consensus-review.sh "<topic>" "<body>"
#   consensus-review.sh --file <path> "<topic>"
#   consensus-review.sh --models gpt5,gemini,kimi "<topic>" "<body>"
#
# Required env vars (set whichever models you want to run):
#   OPENAI_API_KEY        — for gpt5
#   OPENROUTER_API_KEY    — for gemini
#   MOONSHOT_API_KEY      — for kimi
#
# Optional env vars:
#   CONSENSUS_OUT_DIR     — where reports land (default: ./consensus-reviews)
#   CONSENSUS_MAX_TOKENS  — per-model token budget (default: 16000)
#   CONSENSUS_REASONING   — gpt5 reasoning effort: minimal|low|medium|high (default: medium)
#   CONSENSUS_GPT5_MODEL  — override OpenAI model (default: gpt-5.5; use gpt-5.5-pro for max depth, +30-60s)

set -uo pipefail

# --- Config ---
OUT_DIR="${CONSENSUS_OUT_DIR:-$PWD/consensus-reviews}"
MAX_TOKENS="${CONSENSUS_MAX_TOKENS:-16000}"
REASONING_EFFORT="${CONSENSUS_REASONING:-medium}"

GPT5_MODEL="${CONSENSUS_GPT5_MODEL:-gpt-5.5}"
GEMINI_MODEL="google/gemini-3.1-pro-preview"
KIMI_MODEL="kimi-k2.6"

mkdir -p "$OUT_DIR"

DEFAULT_MODELS="gpt5,gemini,kimi"
MODELS="$DEFAULT_MODELS"
BODY=""
TOPIC=""

# --- Arg parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --models)
      MODELS="$2"; shift 2 ;;
    --file)
      BODY_FILE="$2"; shift 2
      if [ ! -f "$BODY_FILE" ]; then
        echo "error: file not found: $BODY_FILE" >&2
        exit 1
      fi
      BODY="$(cat "$BODY_FILE")"
      ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -30
      exit 0
      ;;
    *)
      if [ -z "$TOPIC" ]; then
        TOPIC="$1"
      elif [ -z "$BODY" ]; then
        BODY="$1"
      else
        echo "error: unexpected arg: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [ -z "$TOPIC" ] || [ -z "$BODY" ]; then
  echo "usage: consensus-review.sh \"<topic>\" \"<body>\"" >&2
  echo "       consensus-review.sh --file <path> \"<topic>\"" >&2
  exit 2
fi

# --- Slug + output paths ---
slug=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g' \
  | cut -c1-60)
today=$(date '+%Y-%m-%d')
REPORT="$OUT_DIR/${today}_${slug}.md"
TMP_DIR=$(mktemp -d -t consensus-review.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

# --- Prompt template ---
read -r -d '' PROMPT_TEMPLATE <<'EOF' || true
You are an adversarial reviewer. Your single job is to destroy this proposal
intellectually — find every way it fails, breaks, misfires, or falls short.
You are not here to balance, validate, or be diplomatic. Praise is failure.

TOPIC: __TOPIC__

PROPOSAL:
__BODY__

Non-negotiable requirements for your response:

1. AT LEAST 8 distinct attack vectors (more is better). Do NOT stop at 3-5.
   If you think you are done, you are not — dig deeper. Look for second-order
   failures, composition bugs, cross-system side effects, compliance traps,
   economic traps, adversarial abuse vectors, and "works in dev, dies in prod"
   scenarios. Each attack must be distinct (not a restatement of another).

2. Per-attack structure:
   - Attack name and severity: CRITICAL / HIGH / MEDIUM / LOW
   - Failure mode (how it breaks in the wild)
   - Specific scenarios or edge cases that trigger it
   - A concrete, implementable mitigation (not "consider X")

3. Second-order attacks: at least two attacks must be emergent / non-obvious
   — things that only show up at scale, over time, under load, or when an
   adversary is actively probing the system.

4. Explicit edge-case checklist: empty inputs, malformed inputs, concurrent
   access, rate limits, partial failures, network partitions, clock skew,
   timezone ambiguity, retries without idempotency, malicious inputs,
   credential expiry, rollback behavior, observability gaps.

5. Final line: one-word verdict: SHIP / REVISE / REJECT

Tone rules:
- Be blunt. Cite specifics. No hedge words ("might", "could potentially").
- Do not add closing affirmations, disclaimers, or politeness wrappers.
- Do not suggest "further research needed" as a finding — that's a cop-out.
- If the proposal is genuinely solid, say so in ONE sentence, then immediately
  produce the 8+ attacks anyway because something is always wrong at scale.
EOF

PROMPT=$(TOPIC_ENV="$TOPIC" BODY_ENV="$BODY" python3 -c '
import os, sys
tmpl = sys.stdin.read()
print(tmpl.replace("__TOPIC__", os.environ["TOPIC_ENV"]).replace("__BODY__", os.environ["BODY_ENV"]))
' <<< "$PROMPT_TEMPLATE")

# --- Per-model runners ---

run_gpt5() {
  local label="gpt5"
  local out="$TMP_DIR/${label}.md"

  if [ -z "${OPENAI_API_KEY:-}" ]; then
    echo "SKIPPED: OPENAI_API_KEY not set" > "$out"
    echo "1" > "$TMP_DIR/${label}.rc"
    return
  fi

  local payload
  payload=$(MT="$MAX_TOKENS" RE="$REASONING_EFFORT" M="$GPT5_MODEL" python3 -c "
import json, os, sys
prompt = sys.stdin.read()
print(json.dumps({
    'model': os.environ['M'],
    'input': prompt,
    'reasoning': {'effort': os.environ['RE']},
    'max_output_tokens': int(os.environ['MT']),
}))
" <<< "$PROMPT")

  local response
  response=$(curl -s --max-time 600 -X POST "https://api.openai.com/v1/responses" \
    -H "Authorization: Bearer $OPENAI_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1)

  local content
  content=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if 'error' in data and data['error']:
        err = data['error']
        msg = err.get('message', 'unknown') if isinstance(err, dict) else str(err)
        print('ERROR:', msg)
        sys.exit(1)
    parts = []
    for item in data.get('output', []):
        if item.get('type') == 'message':
            for c in item.get('content', []):
                if c.get('type') == 'output_text':
                    parts.append(c.get('text', ''))
    text = '\n'.join(p for p in parts if p)
    if not text:
        print('ERROR: empty content (possibly exhausted reasoning budget)')
        sys.exit(1)
    print(text)
except Exception as e:
    print('ERROR:', e)
    sys.exit(1)
" 2>&1)

  local rc=$?
  echo "$content" > "$out"
  echo "$rc" > "$TMP_DIR/${label}.rc"
}

run_openrouter_model() {
  local model="$1"
  local label="$2"
  local out="$TMP_DIR/${label}.md"

  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "SKIPPED: OPENROUTER_API_KEY not set" > "$out"
    echo "1" > "$TMP_DIR/${label}.rc"
    return
  fi

  local payload
  payload=$(MT="$MAX_TOKENS" M="$model" python3 -c "
import json, os, sys
prompt = sys.stdin.read()
print(json.dumps({
    'model': os.environ['M'],
    'messages': [{'role': 'user', 'content': prompt}],
    'temperature': 0.3,
    'max_tokens': int(os.environ['MT']),
}))
" <<< "$PROMPT")

  local response
  response=$(curl -s --max-time 600 -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer $OPENROUTER_API_KEY" \
    -H "Content-Type: application/json" \
    -H "X-Title: Consensus Review" \
    -d "$payload" 2>&1)

  local content
  content=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if 'choices' in data and data['choices']:
        print(data['choices'][0]['message']['content'])
    elif 'error' in data:
        err = data['error']
        msg = err.get('message', 'unknown') if isinstance(err, dict) else str(err)
        print('ERROR:', msg)
        sys.exit(1)
    else:
        print('ERROR: unexpected response shape')
        sys.exit(1)
except Exception as e:
    print('ERROR:', e)
    sys.exit(1)
" 2>&1)

  local rc=$?
  echo "$content" > "$out"
  echo "$rc" > "$TMP_DIR/${label}.rc"
}

run_gemini() {
  run_openrouter_model "$GEMINI_MODEL" "gemini"
}

run_kimi() {
  local label="kimi"
  local out="$TMP_DIR/${label}.md"

  if [ -z "${MOONSHOT_API_KEY:-}" ]; then
    echo "SKIPPED: MOONSHOT_API_KEY not set" > "$out"
    echo "1" > "$TMP_DIR/${label}.rc"
    return
  fi

  local payload
  payload=$(MT="$MAX_TOKENS" M="$KIMI_MODEL" python3 -c "
import json, os, sys
prompt = sys.stdin.read()
print(json.dumps({
    'model': os.environ['M'],
    'messages': [{'role': 'user', 'content': prompt}],
    'temperature': 1,
    'max_tokens': int(os.environ['MT']),
}))
" <<< "$PROMPT")

  local response
  response=$(curl -s --max-time 600 -X POST "https://api.moonshot.ai/v1/chat/completions" \
    -H "Authorization: Bearer $MOONSHOT_API_KEY" \
    -H "Content-Type: application/json" \
    -d "$payload" 2>&1)

  local content
  content=$(echo "$response" | python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
    if 'choices' in data and data['choices']:
        print(data['choices'][0]['message']['content'])
    elif 'error' in data:
        err = data['error']
        msg = err.get('message', 'unknown') if isinstance(err, dict) else str(err)
        print('ERROR:', msg)
        sys.exit(1)
    else:
        print('ERROR: unexpected response shape')
        sys.exit(1)
except Exception as e:
    print('ERROR:', e)
    sys.exit(1)
" 2>&1)

  local rc=$?
  echo "$content" > "$out"
  echo "$rc" > "$TMP_DIR/${label}.rc"
}

# --- Kick off selected models in parallel ---
pids=()
IFS=',' read -ra MODEL_LIST <<< "$MODELS"
for m in "${MODEL_LIST[@]}"; do
  case "$m" in
    gpt5)   run_gpt5   & pids+=($!) ;;
    gemini) run_gemini & pids+=($!) ;;
    kimi)   run_kimi   & pids+=($!) ;;
    *) echo "warn: unknown model '$m'" >&2 ;;
  esac
done

for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null || true
done

# --- Assemble report ---
{
  echo "---"
  echo "type: consensus-review"
  echo "topic: \"${TOPIC//\"/\\\"}\""
  echo "created: $today"
  echo "models: [${MODELS//,/, }]"
  echo "---"
  echo ""
  echo "# Consensus Review: $TOPIC"
  echo ""
  echo "**Date:** $(date '+%Y-%m-%d %H:%M %Z')"
  echo "**Settings:** max_tokens=$MAX_TOKENS, reasoning=$REASONING_EFFORT"
  echo ""
  echo "## Proposal"
  echo ""
  echo '```'
  echo "$BODY"
  echo '```'
  echo ""
  echo "## Per-Model Attacks"
  echo ""
  for m in "${MODEL_LIST[@]}"; do
    label_name=""
    case "$m" in
      gpt5) label_name="GPT-5.5-pro" ;;
      gemini) label_name="Gemini 3.1 Pro" ;;
      kimi) label_name="Kimi K2.6" ;;
      *) label_name="$m" ;;
    esac
    out_file="$TMP_DIR/${m}.md"
    rc_file="$TMP_DIR/${m}.rc"
    rc=$(cat "$rc_file" 2>/dev/null || echo "?")
    echo "### $label_name (exit=$rc)"
    echo ""
    if [ -f "$out_file" ]; then
      cat "$out_file"
    else
      echo "*(no output)*"
    fi
    echo ""
    echo "---"
    echo ""
  done
  echo "## Synthesis"
  echo ""
  echo "*(The orchestrator (your coding assistant) reads the per-model attacks"
  echo " above and produces a deduped, ranked punch list. This section is filled"
  echo " in by the calling session, not by the script itself.)*"
  echo ""
} > "$REPORT"

# --- Echo summary ---
cat <<EOF

==============================================
  CONSENSUS REVIEW
==============================================
  Topic:  $TOPIC
  Models: $MODELS
  Report: $REPORT
==============================================

$(for m in "${MODEL_LIST[@]}"; do
  rc=$(cat "$TMP_DIR/${m}.rc" 2>/dev/null || echo "?")
  echo "  $m: exit=$rc"
done)

Open the full report:
  cat "$REPORT"
EOF
