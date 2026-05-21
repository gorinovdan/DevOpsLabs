#!/usr/bin/env bash
set -euo pipefail

# Send a CI/CD status broadcast via the Telegram bot HTTP API.
#
# Required environment variables:
#   TELEGRAM_BOT_TOKEN  - Telegram bot token from BotFather (e.g. "12345:ABC...").
#
# Optional environment variables:
#   TELEGRAM_CHAT_IDS         - explicit recipient chat ids, separated by
#                               commas, semicolons, whitespace, or newlines.
#   TELEGRAM_CHATS_FILE       - persistent cache of chat ids (default
#                               "${HOME}/.flowboard-telegram-chats.txt").
#   TELEGRAM_API              - override Telegram API root.
#   TELEGRAM_NOTIFY_DISABLE=1 - skip sending entirely (useful in dry-runs).
#
# Usage:
#   notify_telegram.sh <event> <status> [extra...]
#
# Special events:
#   pipeline / started|queued     - "pipeline launched" message.
#   pipeline / <overall> + extra  - if extra contains "k=v;k=v..." it is
#                                   rendered as a per-job summary table.
#   <anything else>               - per-job notification.
#
# Recipients are discovered automatically via getUpdates and cached in
# TELEGRAM_CHATS_FILE so the broadcast list grows over time. To start
# receiving notifications, send any message to the bot once.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_IDS="${TELEGRAM_CHAT_IDS:-}"
TELEGRAM_API="${TELEGRAM_API:-https://api.telegram.org}"
TELEGRAM_NOTIFY_DISABLE="${TELEGRAM_NOTIFY_DISABLE:-0}"
TELEGRAM_CHATS_FILE="${TELEGRAM_CHATS_FILE:-${HOME}/.flowboard-telegram-chats.txt}"

if [[ "${TELEGRAM_NOTIFY_DISABLE}" == "1" ]]; then
  echo "TELEGRAM_NOTIFY_DISABLE=1, skipping Telegram notification." >&2
  exit 0
fi

if [[ -z "${TELEGRAM_BOT_TOKEN}" ]]; then
  echo "Warning: TELEGRAM_BOT_TOKEN is not set; skipping Telegram broadcast." >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Warning: jq not on PATH; cannot parse Telegram updates." >&2
  exit 0
fi

event="${1:?missing event name}"
status="${2:?missing status}"
shift 2 || true
extra_message="$*"

status_icon() {
  case "${1,,}" in
    success|ok|passed)         echo "✅" ;;
    failure|failed|error)      echo "❌" ;;
    cancelled)                 echo "🟥" ;;
    skipped)                   echo "⚪️" ;;
    started|running|in_progress|queued|pending) echo "🟡" ;;
    *)                         echo "ℹ️" ;;
  esac
}

# Sanitise user-controlled fields for parse_mode=HTML.
sanitize() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

# Pull commit metadata from the locally checked out repo.
repo="${GITHUB_REPOSITORY:-flowboard}"
ref="${GITHUB_REF_NAME:-${GITHUB_REF:-local}}"
sha="${GITHUB_SHA:-$(git -C "${ROOT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)}"
short_sha="${sha::7}"
actor="${GITHUB_ACTOR:-$(git -C "${ROOT_DIR}" log -1 --pretty='%an' "${sha}" 2>/dev/null || echo '-')}"
trigger="${GITHUB_EVENT_NAME:-manual}"
workflow_name="${GITHUB_WORKFLOW:-CI/CD}"

run_url=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${GITHUB_RUN_ID}"
fi

# Render the metadata footer that all messages share.
render_footer() {
  local out=""
  out+=$'\n'"🎬 <code>$(sanitize "${workflow_name}")</code> · 🔖 <code>${short_sha}</code> · 🌿 <code>$(sanitize "${ref}")</code>"
  out+=$'\n'"👤 $(sanitize "${actor}") · ⚡ $(sanitize "${trigger}")"
  if [[ -n "${run_url}" ]]; then
    out+=$'\n'"🔗 <a href=\"${run_url}\">Open pipeline run</a>"
  fi
  printf '%s' "${out}"
}

render_pipeline_start() {
  local text="🚀 <b>FlowBoard CI/CD</b> — <i>started</i>"
  text+="$(render_footer)"
  printf '%s' "${text}"
}

render_pipeline_summary() {
  local overall_icon
  overall_icon="$(status_icon "${status}")"

  local title
  case "${status,,}" in
    success) title="<i>all green</i>" ;;
    failure) title="<i>some jobs failed</i>" ;;
    cancelled) title="<i>cancelled</i>" ;;
    *) title="<i>$(sanitize "${status}")</i>" ;;
  esac

  local text="${overall_icon} <b>FlowBoard CI/CD</b> — ${title}"

  # Parse "key=value;key=value" pairs from extra_message into a vertical table.
  if [[ -n "${extra_message}" && "${extra_message}" == *"="* ]]; then
    text+=$'\n\n<pre>'
    local pair name value icon name_padded
    while IFS=';' read -ra pairs <<< "${extra_message//;/$'\n;'}"; do
      :  # noop; we read in a different way below
      break
    done

    # Re-split on ";" producing lines.
    local raw="${extra_message}"
    while [[ -n "${raw}" ]]; do
      if [[ "${raw}" == *";"* ]]; then
        pair="${raw%%;*}"
        raw="${raw#*;}"
      else
        pair="${raw}"
        raw=""
      fi
      pair="${pair## }"
      pair="${pair%% }"
      [[ -z "${pair}" || "${pair}" != *"="* ]] && continue
      name="${pair%%=*}"
      value="${pair#*=}"
      icon="$(status_icon "${value}")"
      printf -v name_padded "%-22s" "${name}"
      text+=$'\n'"${icon}  ${name_padded}$(sanitize "${value}")"
    done
    text+=$'\n</pre>'
  fi

  text+="$(render_footer)"
  printf '%s' "${text}"
}

render_single_job() {
  local icon
  icon="$(status_icon "${status}")"

  local job_name
  job_name="$(sanitize "${event}")"
  local status_label
  status_label="$(sanitize "${status}")"

  local text="${icon} <b>${job_name}</b> — <i>${status_label}</i>"
  if [[ -n "${extra_message}" ]]; then
    text+=$'\n\n'"$(sanitize "${extra_message}")"
  fi
  text+="$(render_footer)"
  printf '%s' "${text}"
}

# Decide which template to use.
if [[ "${event,,}" == "pipeline" && ( "${status,,}" == "started" || "${status,,}" == "queued" ) ]]; then
  message_text="$(render_pipeline_start)"
elif [[ "${event,,}" == "pipeline" && "${extra_message}" == *"="* ]]; then
  message_text="$(render_pipeline_summary)"
else
  message_text="$(render_single_job)"
fi

mkdir -p "$(dirname "${TELEGRAM_CHATS_FILE}")"
touch "${TELEGRAM_CHATS_FILE}"

# Step 1 - poll getUpdates and collect distinct chat ids from any recent activity.
configured_ids=""
if [[ -n "${TELEGRAM_CHAT_IDS}" ]]; then
  configured_ids="$(printf '%s\n' "${TELEGRAM_CHAT_IDS}" | tr ',; ' '\n' | awk 'NF')"
fi

discovered_ids=""
if updates_payload="$(curl -fsS --max-time 10 "${TELEGRAM_API}/bot${TELEGRAM_BOT_TOKEN}/getUpdates" 2>/dev/null)"; then
  if printf '%s' "${updates_payload}" | jq -e '.ok == true' >/dev/null 2>&1; then
    discovered_ids="$(printf '%s' "${updates_payload}" \
      | jq -r '
          [ .result[]? |
            ( .message.chat.id // .channel_post.chat.id //
              .edited_message.chat.id // .my_chat_member.chat.id //
              empty ) ]
          | unique
          | .[]?
        ' 2>/dev/null || true)"
  else
    echo "Warning: Telegram getUpdates returned non-ok payload." >&2
  fi
else
  echo "Warning: Telegram getUpdates request failed; relying on cached chat ids." >&2
fi

# Step 2 - merge discovered ids into the persistent cache.
if [[ -n "${configured_ids}${discovered_ids}" ]]; then
  {
    cat "${TELEGRAM_CHATS_FILE}"
    printf '%s\n' "${configured_ids}"
    printf '%s\n' "${discovered_ids}"
  } | awk 'NF && !seen[$0]++' > "${TELEGRAM_CHATS_FILE}.tmp"
  mv "${TELEGRAM_CHATS_FILE}.tmp" "${TELEGRAM_CHATS_FILE}"
fi

# Step 3 - assemble the final recipient list (cache ∪ freshly discovered).
recipients="$(awk 'NF && !seen[$0]++' "${TELEGRAM_CHATS_FILE}" 2>/dev/null || true)"
if [[ -z "${recipients}" ]]; then
  echo "Warning: no Telegram recipients known yet. Send any message to the bot to subscribe." >&2
  exit 0
fi

# Step 4 - broadcast.
sent=0
failed=0
while IFS= read -r chat_id; do
  [[ -z "${chat_id}" ]] && continue
  http_code="$(curl -sS -o /tmp/telegram_response.json -w '%{http_code}' \
    -X POST "${TELEGRAM_API}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${chat_id}" \
    --data-urlencode "text=${message_text}" \
    --data-urlencode "parse_mode=HTML" \
    --data-urlencode "disable_web_page_preview=true" \
    || echo "000")"

  if [[ "${http_code}" == "200" ]]; then
    sent=$((sent + 1))
  else
    failed=$((failed + 1))
    echo "Warning: Telegram sendMessage to chat=${chat_id} returned HTTP ${http_code}." >&2
    if [[ -f /tmp/telegram_response.json ]]; then
      sed -e 's/"\([0-9]\{6,\}:[A-Za-z0-9_-]*\)"/"<redacted>"/g' /tmp/telegram_response.json >&2 || true
      echo >&2
    fi
  fi
done <<< "${recipients}"

echo "Telegram broadcast: sent=${sent}, failed=${failed}, total_recipients=$(printf '%s\n' "${recipients}" | grep -c .)"
exit 0
