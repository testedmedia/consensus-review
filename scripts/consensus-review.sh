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
#   GEMINI_API_KEY        — for gemini (direct Google AI Studio, preferred)
#   OPENROUTER_API_KEY    — for gemini fallback (used only if GEMINI_API_KEY is unset)
#   MOONSHOT_API_KEY      — for kimi
#
# Optional env vars:
#   CONSENSUS_OUT_DIR     — where reports land (default: ./consensus-reviews)
#   CONSENSUS_MAX_TOKENS  — per-model token budget (default: 16000)
#   CONSENSUS_REASONING   — gpt5 reasoning effort: minimal|low|medium|high (default: high)
#   CONSENSUS_GPT5_MODEL  — override OpenAI model (default: gpt-5.5; use gpt-5.5-pro for max depth, +30-60s)
#   CONSENSUS_GEMINI_MODEL — override Gemini model id (Google direct: gemini-2.5-pro; OpenRouter: google/gemini-3.1-pro-preview)

set -uo pipefail

# --- Config ---
OUT_DIR="${CONSENSUS_OUT_DIR:-$PWD/consensus-reviews}"
MAX_TOKENS="${CONSENSUS_MAX_TOKENS:-16000}"
REASONING_EFFORT="${CONSENSUS_REASONING:-high}"

GPT5_MODEL="${CONSENSUS_GPT5_MODEL:-gpt-5.5-pro}"
# Default Gemini model depends on routing: direct Google AI uses bare model name,
# OpenRouter uses "google/..." prefix. Set CONSENSUS_GEMINI_MODEL to override.
GEMINI_MODEL_GOOGLE="${CONSENSUS_GEMINI_MODEL:-gemini-3.1-pro-preview}"
GEMINI_MODEL_OPENROUTER="${CONSENSUS_GEMINI_MODEL:-google/gemini-3.1-pro-preview}"
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

# --- Input size guard (warn on big inputs before burning $$$) ---
# Rough token estimate: 1 token ≈ 4 chars
body_chars=${#BODY}
approx_tokens=$((body_chars / 4))
if [ "$approx_tokens" -gt 50000 ]; then
  echo "WARNING: input body is ~${approx_tokens} tokens. With 3 models @ 16K output budget" >&2
  echo "  this run could cost ~\$3-8 USD. Press Ctrl+C to abort, or wait 5s to continue." >&2
  sleep 5
fi

# --- Slug + output paths (slug is already sanitized to [a-z0-9-] via sed) ---
# Add nanosecond suffix to prevent same-slug-same-day overwrite
slug=$(echo "$TOPIC" | tr '[:upper:]' '[:lower:]' \
  | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g' \
  | cut -c1-60)
# Empty-slug guard (e.g. topic was all punctuation)
if [ -z "$slug" ]; then slug="untitled-$(date +%s)"; fi
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

# Helper: did the last call fail? (non-zero rc OR content starts with ERROR/SKIPPED)
_call_failed() {
  local label="$1"
  local rc=$(cat "$TMP_DIR/${label}.rc" 2>/dev/null || echo "1")
  local content=$(cat "$TMP_DIR/${label}.md" 2>/dev/null || echo "")
  if [ "$rc" != "0" ]; then return 0; fi
  case "$content" in
    ERROR:*|SKIPPED:*) return 0 ;;
    *) [ -z "$(echo "$content" | tr -d '[:space:]')" ] && return 0 || return 1 ;;
  esac
}

# OpenRouter fallback model ids (override via env)
OR_FALLBACK_GPT5="${OR_FALLBACK_GPT5:-openai/gpt-5}"
OR_FALLBACK_KIMI="${OR_FALLBACK_KIMI:-moonshotai/kimi-k2-0905}"

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

  # Fallback to OpenRouter if primary OpenAI call failed and OPENROUTER_API_KEY is set
  if _call_failed "$label" && [ -n "${OPENROUTER_API_KEY:-}" ]; then
    local primary_err=$(head -3 "$out" 2>/dev/null)
    run_openrouter_model "$OR_FALLBACK_GPT5" "$label"
    if _call_failed "$label"; then
      {
        echo "PRIMARY (OpenAI) FAILED:"
        echo "$primary_err"
        echo ""
        echo "FALLBACK (OpenRouter $OR_FALLBACK_GPT5) ALSO FAILED:"
        cat "$out"
      } > "$out.merged" && mv "$out.merged" "$out"
    else
      sed -i '' '1s|^|*(routed via OpenRouter fallback — primary OpenAI errored)*\n\n|' "$out" 2>/dev/null || \
      { echo "*(routed via OpenRouter fallback — primary OpenAI errored)*"; echo ""; cat "$out"; } > "$out.tmp" && mv "$out.tmp" "$out"
    fi
  fi
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

run_gemini_google_direct() {
  local label="gemini"
  local out="$TMP_DIR/${label}.md"

  local payload
  payload=$(MT="$MAX_TOKENS" python3 -c "
import json, os, sys
prompt = sys.stdin.read()
print(json.dumps({
    'contents': [{'parts': [{'text': prompt}]}],
    'generationConfig': {
        'temperature': 0.3,
        'maxOutputTokens': int(os.environ['MT']),
    },
}))
" <<< "$PROMPT")

  local response
  response=$(curl -s --max-time 600 -X POST \
    "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL_GOOGLE}:generateContent?key=${GEMINI_API_KEY}" \
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
    cands = data.get('candidates', [])
    if not cands:
        print('ERROR: no candidates in response')
        sys.exit(1)
    parts = cands[0].get('content', {}).get('parts', [])
    text = '\n'.join(p.get('text','') for p in parts if p.get('text'))
    if not text:
        print('ERROR: empty content')
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

run_gemini() {
  # Prefer direct Google AI Studio (your GEMINI_API_KEY) over OpenRouter
  if [ -n "${GEMINI_API_KEY:-}" ]; then
    run_gemini_google_direct
    _wrap_gemini_with_fallback
  elif [ -n "${OPENROUTER_API_KEY:-}" ]; then
    run_openrouter_model "$GEMINI_MODEL_OPENROUTER" "gemini"
  else
    echo "SKIPPED: neither GEMINI_API_KEY nor OPENROUTER_API_KEY set" > "$TMP_DIR/gemini.md"
    echo "1" > "$TMP_DIR/gemini.rc"
  fi
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

  # Fallback to OpenRouter if Moonshot failed and OPENROUTER_API_KEY is set
  if _call_failed "$label" && [ -n "${OPENROUTER_API_KEY:-}" ]; then
    local primary_err=$(head -3 "$out" 2>/dev/null)
    run_openrouter_model "$OR_FALLBACK_KIMI" "$label"
    if _call_failed "$label"; then
      {
        echo "PRIMARY (Moonshot) FAILED:"
        echo "$primary_err"
        echo ""
        echo "FALLBACK (OpenRouter $OR_FALLBACK_KIMI) ALSO FAILED:"
        cat "$out"
      } > "$out.merged" && mv "$out.merged" "$out"
    else
      { echo "*(routed via OpenRouter fallback — Moonshot errored)*"; echo ""; cat "$out"; } > "$out.tmp" && mv "$out.tmp" "$out"
    fi
  fi
}

# Apply same fallback chain to Gemini Google-direct path
_wrap_gemini_with_fallback() {
  if _call_failed "gemini" && [ -n "${OPENROUTER_API_KEY:-}" ] && [ -n "${GEMINI_API_KEY:-}" ]; then
    # Only fall back if Google-direct was actually tried (GEMINI_API_KEY set) and failed.
    # If user has no GEMINI_API_KEY, run_gemini already went to OpenRouter directly — no fallback needed.
    local primary_err=$(head -3 "$TMP_DIR/gemini.md" 2>/dev/null)
    run_openrouter_model "$GEMINI_MODEL_OPENROUTER" "gemini"
    if _call_failed "gemini"; then
      {
        echo "PRIMARY (Google AI direct) FAILED:"
        echo "$primary_err"
        echo ""
        echo "FALLBACK (OpenRouter) ALSO FAILED:"
        cat "$TMP_DIR/gemini.md"
      } > "$TMP_DIR/gemini.md.merged" && mv "$TMP_DIR/gemini.md.merged" "$TMP_DIR/gemini.md"
    else
      { echo "*(routed via OpenRouter fallback — Google AI errored)*"; echo ""; cat "$TMP_DIR/gemini.md"; } > "$TMP_DIR/gemini.md.tmp" && mv "$TMP_DIR/gemini.md.tmp" "$TMP_DIR/gemini.md"
    fi
  fi
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

# --- Fail-loud: count models that produced valid (non-error) output ---
success_count=0
for m in "${MODEL_LIST[@]}"; do
  if ! _call_failed "$m"; then
    success_count=$((success_count + 1))
  fi
done

if [ "$success_count" -eq 0 ]; then
  echo "" >&2
  echo "!!! ZERO MODELS PRODUCED VALID OUTPUT — this is not a consensus review !!!" >&2
  echo "Check API keys, network, or provider status. Report file written but is empty." >&2
  exit 3
elif [ "$success_count" -eq 1 ] && [ ${#MODEL_LIST[@]} -gt 1 ]; then
  echo "" >&2
  echo "!!! WARNING: only 1 of ${#MODEL_LIST[@]} requested models succeeded — this is NOT a consensus." >&2
  echo "Report is one-model output. Don't ship decisions on it." >&2
  exit 4
fi

