#!/bin/sh
# bunpro_calendar_sync.sh
# Fetches the next Bunpro review time and upserts a single Google Calendar event.
# Uses a fixed event ID so re-runs silently overwrite — no duplicates ever.
#
# If reviews are overdue, the event slides forward snapping to the nearest :00
# or :30, firing a fresh notification every 30 minutes until reviews are done.
#
# NOTE: Bunpro's official API key (from Settings) does not work for these
# endpoints. This script authenticates with your credentials to obtain a
# short-lived frontend_api_token on each run instead.
#
# Required env vars:
#   BUNPRO_EMAIL         — your Bunpro account email
#   BUNPRO_PASSWORD      — your Bunpro account password
#   GCAL_CLIENT_ID       — OAuth2 client ID (Desktop app type)
#   GCAL_CLIENT_SECRET   — OAuth2 client secret
#   GCAL_REFRESH_TOKEN   — long-lived refresh token
#   GCAL_CALENDAR_ID     — target calendar ID (yourname@gmail.com for primary)

set -e

# ─── 0. Sanity checks ────────────────────────────────────────────────────────

: "${BUNPRO_EMAIL:?Need BUNPRO_EMAIL}"
: "${BUNPRO_PASSWORD:?Need BUNPRO_PASSWORD}"
: "${GCAL_CLIENT_ID:?Need GCAL_CLIENT_ID}"
: "${GCAL_CLIENT_SECRET:?Need GCAL_CLIENT_SECRET}"
: "${GCAL_REFRESH_TOKEN:?Need GCAL_REFRESH_TOKEN}"
: "${GCAL_CALENDAR_ID:?Need GCAL_CALENDAR_ID}"

for cmd in curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Missing dependency: $cmd"; exit 1; }
done

COOKIE_JAR=$(mktemp)
trap 'rm -f "$COOKIE_JAR"' EXIT

# ─── 1. Login and obtain frontend_api_token ──────────────────────────────────
#
# Bunpro is a Rails app. Its login endpoint requires:
#   a) A CSRF authenticity_token fetched from the login page first
#   b) Form-encoded POST (not JSON) with that token included
#
# After login, we GET the settings page which sets the frontend_api_token cookie.

echo "Fetching Bunpro login page for CSRF token..."

LOGIN_PAGE=$(curl -sf \
  -c "$COOKIE_JAR" \
  "https://bunpro.jp/users/sign_in")

CSRF_TOKEN=$(echo "$LOGIN_PAGE" \
  | grep -oP 'name="authenticity_token"[^>]*value="\K[^"]+' \
  | head -1)

if [ -z "$CSRF_TOKEN" ]; then
  # Fallback: try meta tag format
  CSRF_TOKEN=$(echo "$LOGIN_PAGE" \
    | grep -oP '<meta name="csrf-token"[^>]*content="\K[^"]+' \
    | head -1)
fi

if [ -z "$CSRF_TOKEN" ]; then
  echo "Could not extract CSRF token from login page. Bunpro may have changed their HTML."
  exit 1
fi

echo "CSRF token obtained. Logging in..."

LOGIN_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  -X POST \
  --data-urlencode "user[email]=${BUNPRO_EMAIL}" \
  --data-urlencode "user[password]=${BUNPRO_PASSWORD}" \
  --data-urlencode "authenticity_token=${CSRF_TOKEN}" \
  "https://bunpro.jp/users/sign_in")

# Rails login returns 302 on success (redirect to dashboard).
# 200 would mean the login page was re-rendered — likely wrong credentials.
if [ "$LOGIN_STATUS" != "302" ] && [ "$LOGIN_STATUS" != "200" ]; then
  echo "Login failed: HTTP ${LOGIN_STATUS}. Check your BUNPRO_EMAIL and BUNPRO_PASSWORD."
  exit 1
fi

if [ "$LOGIN_STATUS" = "200" ]; then
  echo "Warning: login returned 200 — credentials may be wrong, but continuing."
fi

echo "Session established (HTTP ${LOGIN_STATUS}). Fetching frontend_api_token..."

# The frontend_api_token is set as a cookie when hitting the settings page.
# We capture response headers (-D -) and discard the body (-o /dev/null).
SETTINGS_HEADERS=$(curl -sf \
  -b "$COOKIE_JAR" \
  -c "$COOKIE_JAR" \
  -D - \
  -o /dev/null \
  "https://bunpro.jp/settings/account")

FRONTEND_API_TOKEN=$(echo "$SETTINGS_HEADERS" \
  | grep -i "set-cookie" \
  | grep -i "frontend_api_token" \
  | sed 's/.*frontend_api_token=\([^;[:space:]]*\).*/\1/' \
  | tr -d '[:space:]' \
  | head -1)

# Fallback: token may already be in the cookie jar from the login response
if [ -z "$FRONTEND_API_TOKEN" ]; then
  FRONTEND_API_TOKEN=$(grep "frontend_api_token" "$COOKIE_JAR" \
    | awk '{print $NF}' \
    | tr -d '[:space:]' \
    | head -1)
fi

if [ -z "$FRONTEND_API_TOKEN" ]; then
  echo "Could not extract frontend_api_token. The login may have redirected unexpectedly."
  echo "Try inspecting Set-Cookie headers manually: curl -I -b cookies.txt https://bunpro.jp/settings/account"
  exit 1
fi

echo "frontend_api_token obtained."

# ─── 2. Fetch currently due reviews ──────────────────────────────────────────
#
# Response shape: {"total_due_grammar": N, "total_due_vocab": N}

echo "Fetching due reviews..."

DUE_RESPONSE=$(curl -sf \
  -b "$COOKIE_JAR" \
  -H "Authorization: Token token=${FRONTEND_API_TOKEN}" \
  -H "Accept: application/json" \
  "https://api.bunpro.jp/api/frontend/user/due")

DUE_COUNT=$(echo "$DUE_RESPONSE" | jq -r '(.total_due_grammar // 0) + (.total_due_vocab // 0)')
DUE_COUNT=$(echo "$DUE_COUNT" | grep -E '^[0-9]+$' || echo "0")

echo "Currently due: ${DUE_COUNT} reviews"

# ─── 3. Fetch hourly forecast for next upcoming review time ──────────────────
#
# Response shape:
#   { "grammar": {"2026-05-04T23:00Z": 8, ...}, "vocab": {"2026-05-04T23:00Z": 0, ...} }
# We sum grammar + vocab per bucket, then pick the first future bucket with count > 0.

echo "Fetching hourly forecast..."

FORECAST=$(curl -sf \
  -b "$COOKIE_JAR" \
  -H "Authorization: Token token=${FRONTEND_API_TOKEN}" \
  -H "Accept: application/json" \
  "https://api.bunpro.jp/api/frontend/user_stats/forecast_hourly")

NOW_ISO=$(date -u "+%Y-%m-%dT%H:%M:%SZ")

# Keys look like "2026-05-04T23:00Z" (no seconds). We compare them as strings
# against the current time truncated to the same format for correct ordering.
NOW_HOUR=$(date -u "+%Y-%m-%dT%H:00Z")

NEXT_REVIEW_AT=$(echo "$FORECAST" | jq -r --arg now "$NOW_HOUR" '
  .grammar as $g | .vocab as $v |
  ($g | keys) |
  map(select(. > $now)) |
  map(select( (($g[.] // 0) + ($v[.] // 0)) > 0 )) |
  sort |
  first // empty
')

if [ -z "$NEXT_REVIEW_AT" ] && [ "$DUE_COUNT" -eq 0 ]; then
  echo "No upcoming or overdue reviews. Nothing to do."
  exit 0
fi

# If no future bucket found but reviews are due now, use a placeholder —
# the sliding-window block below will snap it to the correct :00 or :30.
if [ -z "$NEXT_REVIEW_AT" ]; then
  NEXT_REVIEW_AT="$NOW_ISO"
fi

# Normalise to full ISO-8601 with seconds so date parsing works everywhere
# Input "2026-05-04T23:00Z" → "2026-05-04T23:00:00Z"
NEXT_REVIEW_AT=$(echo "$NEXT_REVIEW_AT" | sed 's/T\([0-9][0-9]\):\([0-9][0-9]\)Z$/T::00Z/')

echo "Next review bucket: ${NEXT_REVIEW_AT}"

# ─── 4. Sliding window — snap to nearest :00 or :30 if reviews are overdue ───

NOW_EPOCH=$(date -u "+%s")
REVIEW_EPOCH=$(date -u -d "${NEXT_REVIEW_AT}" "+%s" 2>/dev/null \
  || date -u -jf "%Y-%m-%dT%H:%M:%SZ" "${NEXT_REVIEW_AT}" "+%s")

if [ "$REVIEW_EPOCH" -le "$NOW_EPOCH" ] || [ "$DUE_COUNT" -gt 0 ]; then
  echo "Reviews overdue — sliding window to nearest :00 or :30..."
  # Round DOWN to the closest past half-hour boundary.
  # The calendar update itself re-fires the notification on mobile.
  NOW_MINUTE=$(date -u "+%M")
  if [ "$NOW_MINUTE" -lt 30 ]; then
    NEXT_REVIEW_AT=$(date -u "+%Y-%m-%dT%H:00:00Z")
  else
    NEXT_REVIEW_AT=$(date -u "+%Y-%m-%dT%H:30:00Z")
  fi
fi

# End time = start + 1 hour (keeps the event visible on mobile calendar)
EVENT_END=$(date -u -d "${NEXT_REVIEW_AT} + 1 hour" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -v+1H -jf "%Y-%m-%dT%H:%M:%SZ" "${NEXT_REVIEW_AT}" "+%Y-%m-%dT%H:%M:%SZ")

echo "Event window: ${NEXT_REVIEW_AT} → ${EVENT_END}"

# ─── 5. Build the event title ────────────────────────────────────────────────

if [ "$DUE_COUNT" -gt 0 ]; then
  COUNT_FOR_TITLE="$DUE_COUNT"
  SUFFIX="ready"
else
  # Sum grammar + vocab for the next bucket from the forecast
  BUCKET_KEY=$(echo "$NEXT_REVIEW_AT" | sed 's/T\([0-9][0-9]\):\([0-9][0-9]\):00Z$/T:Z/')
  COUNT_FOR_TITLE=$(echo "$FORECAST" | jq -r --arg t "$BUCKET_KEY" '
    ((.grammar[$t] // 0) + (.vocab[$t] // 0))
  ')
  COUNT_FOR_TITLE=$(echo "$COUNT_FOR_TITLE" | grep -E '^[0-9]+$' || echo "0")
  SUFFIX="incoming"
fi

PLURAL=""
[ "$COUNT_FOR_TITLE" -ne 1 ] && PLURAL="s"
EVENT_TITLE="📝 Bunpro — ${COUNT_FOR_TITLE} review${PLURAL} ${SUFFIX}"

echo "Event title: '${EVENT_TITLE}'"

# ─── 6. Exchange refresh token for a short-lived Google access token ─────────

echo "Getting Google access token..."

ACCESS_TOKEN=$(curl -sf \
  -X POST \
  -d "client_id=${GCAL_CLIENT_ID}&client_secret=${GCAL_CLIENT_SECRET}&refresh_token=${GCAL_REFRESH_TOKEN}&grant_type=refresh_token" \
  "https://oauth2.googleapis.com/token" \
  | jq -r '.access_token')

# ─── 7. Upsert the Calendar event ────────────────────────────────────────────
# Google Calendar event IDs: only lowercase a–v and 0–9 (base32hex). No w/x/y/z.

FIXED_EVENT_ID="bunpr0nextreviewaut0"

CAL_ID_ENCODED=$(jq -rn --arg v "$GCAL_CALENDAR_ID" '$v | @uri')

EVENT_BODY=$(jq -n \
  --arg id    "$FIXED_EVENT_ID" \
  --arg title "$EVENT_TITLE" \
  --arg time  "$NEXT_REVIEW_AT" \
  --arg end   "$EVENT_END" \
  '{
    id: $id,
    summary: $title,
    description: "Auto-synced by bunpro-calendar-sync.\nhttps://bunpro.jp/review",
    start: { dateTime: $time, timeZone: "UTC" },
    end:   { dateTime: $end,  timeZone: "UTC" },
    reminders: {
      useDefault: true
    },
    colorId: "2"
  }')

# Try PUT (update) first; fall back to POST (create) on 404
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -X PUT \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$EVENT_BODY" \
  "https://www.googleapis.com/calendar/v3/calendars/${CAL_ID_ENCODED}/events/${FIXED_EVENT_ID}")

if [ "$HTTP_STATUS" = "404" ]; then
  echo "Event not found — creating for the first time..."
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$EVENT_BODY" \
    "https://www.googleapis.com/calendar/v3/calendars/${CAL_ID_ENCODED}/events")
fi

if [ "$HTTP_STATUS" -ge 200 ] && [ "$HTTP_STATUS" -lt 300 ]; then
  echo "Done. Event upserted (HTTP ${HTTP_STATUS}): '${EVENT_TITLE}' at ${NEXT_REVIEW_AT}"
else
  echo "Calendar API error: HTTP ${HTTP_STATUS}"
  exit 1
fi
