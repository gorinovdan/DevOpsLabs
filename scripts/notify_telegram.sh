#!/usr/bin/env bash
set -euo pipefail

# Send a CI/CD status broadcast via the Telegram bot HTTP API.
#
# Required environment variables:
#   TELEGRAM_BOT_TOKEN  - Telegram bot token from BotFather (e.g. "12345:ABC...").
#
# Optional environment variables:
#   TELEGRAM_CHATS_FILE       - persistent cache of chat ids (default
#                               "${HOME}/.flowboard-telegram-chats.txt").
#   TELEGRAM_API              - override Telegram API root.
#   TELEGRAM_NOTIFY_DISABLE=1 - skip sending entirely (useful in dry-runs).
#
# Usage:
#   notify_telegram.sh <event> <status> [message...]
#
# Example:
#   TELEGRAM_BOT_TOKEN=... ./scripts/notify_telegram.sh sonar-scan success "coverage 99.6%"
#
# Recipients are discovered automatically:
#   1. We call getUpdates to learn every chat that messaged the bot
#      since the last few days.
#   2. Each unique chat id is appended to TELEGRAM_CHATS_FILE so the
#      list grows over time even if Telegram's 24h getUpdates window
#      forgets old chats.
#   3. The notification is broadcast to every id in the merged set.
#
# To start receiving notifications a user (or admin of a group/channel)
# only needs to send any message to the bot once.

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
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

case "${status,,}" in
  success|ok|passed) icon="✅" ;;
  failure|failed|error) icon="❌" ;;
  cancelled|skipped) icon="⚠️" ;;
  started|running|in_progress) icon="🔄" ;;
  *) icon="ℹ️" ;;
esac

repo="${GITHUB_REPOSITORY:-local}"
ref="${GITHUB_REF_NAME:-${GITHUB_REF:-local}}"
sha="${GITHUB_SHA:-$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --short HEAD 2>/dev/null || echo unknown)}"
short_sha="${sha::7}"
run_url=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
  run_url="${GITHUB_SERVER_URL}/${repo}/actions/runs/${GITHUB_RUN_ID}"
fi

# Build the message text. HTML special chars in user-controlled fields
# are stripped to keep parse_mode=HTML safe.
sanitize() {
  printf '%s' "$1" | sed 's/[<>&]/ /g'
}

text="${icon} <b>FlowBoard CI/CD</b>"
text+=$'\n'"<b>Event:</b> $(sanitize "${event}")"
text+=$'\n'"<b>Status:</b> $(sanitize "${status}")"
text+=$'\n'"<b>Repo:</b> $(sanitize "${repo}")"
text+=$'\n'"<b>Ref:</b> $(sanitize "${ref}")"
text+=$'\n'"<b>Commit:</b> <code>${short_sha}</code>"
if [[ -n "${run_url}" ]]; then
  text+=$'\n'"<a href=\"${run_url}\">View pipeline run</a>"
fi
if [[ -n "${extra_message}" ]]; then
  text+=$'\n\n'"$(sanitize "${extra_message}")"
fi

mkdir -p "$(dirname "${TELEGRAM_CHATS_FILE}")"
touch "${TELEGRAM_CHATS_FILE}"

# Step 1 - poll getUpdates and collect distinct chat ids from any recent activity.
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
if [[ -n "${discovered_ids}" ]]; then
  {
    cat "${TELEGRAM_CHATS_FILE}"
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
    --data-urlencode "text=${text}" \
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
