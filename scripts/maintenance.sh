#!/bin/sh

set -eu

export LC_ALL=C

RETENTION_DAYS="${RETENTION_DAYS:-90}"
BATCH_SIZE="${BATCH_SIZE:-5000}"
BATCH_SLEEP_SECONDS="${BATCH_SLEEP_SECONDS:-1}"
MAX_DELETE_ROWS="${MAX_DELETE_ROWS:-1000000}"

log() {
  printf '%s\n' "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_unsigned_integer() {
  variable_name="$1"
  variable_value="$2"

  case "$variable_value" in
    ''|*[!0-9]*)
      fail "$variable_name must be an unsigned integer"
      ;;
  esac
}

require_configuration() {
  : "${DATABASE_URL:?DATABASE_URL is required}"

  command -v psql >/dev/null 2>&1 ||
    fail "psql is required"

  require_unsigned_integer "RETENTION_DAYS" "$RETENTION_DAYS"
  require_unsigned_integer "BATCH_SIZE" "$BATCH_SIZE"
  require_unsigned_integer "BATCH_SLEEP_SECONDS" "$BATCH_SLEEP_SECONDS"
  require_unsigned_integer "MAX_DELETE_ROWS" "$MAX_DELETE_ROWS"

  [ "$RETENTION_DAYS" -gt 0 ] ||
    fail "RETENTION_DAYS must be greater than zero"
  [ "$BATCH_SIZE" -gt 0 ] ||
    fail "BATCH_SIZE must be greater than zero"
  [ "$MAX_DELETE_ROWS" -gt 0 ] ||
    fail "MAX_DELETE_ROWS must be greater than zero"
}

calculate_cutoff() {
  psql "$DATABASE_URL" \
    -X \
    -qAt \
    -v ON_ERROR_STOP=1 \
    -v retention_days="$RETENTION_DAYS" <<'SQL'
SELECT to_char(
  (
    CURRENT_TIMESTAMP -
    make_interval(days => (:'retention_days')::integer)
  ) AT TIME ZONE 'UTC',
  'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'
);
SQL
}

count_eligible_rows() {
  cutoff_at="$1"

  psql "$DATABASE_URL" \
    -X \
    -qAt \
    -v ON_ERROR_STOP=1 \
    -v cutoff_at="$cutoff_at" <<'SQL'
SELECT count(*)
FROM audit_logs
WHERE created_at < (:'cutoff_at')::timestamptz;
SQL
}

load_plan() {
  if [ -z "${CUTOFF_AT:-}" ] && [ -f plan.env ]; then
    set -a
    # shellcheck disable=SC1091
    . ./plan.env
    set +a
  fi

  : "${CUTOFF_AT:?Run the plan action first or provide CUTOFF_AT}"
  : "${ELIGIBLE_ROWS:?Run the plan action first or provide ELIGIBLE_ROWS}"

  require_unsigned_integer "ELIGIBLE_ROWS" "$ELIGIBLE_ROWS"
}

plan_cleanup() {
  cutoff_at="$(calculate_cutoff)"
  eligible_rows="$(count_eligible_rows "$cutoff_at")"

  require_unsigned_integer "eligible row count" "$eligible_rows"

  log "Environment: ${CI_ENVIRONMENT_NAME:-local}"
  log "Retention days: $RETENTION_DAYS"
  log "Cutoff: $cutoff_at"
  log "Rows eligible for deletion: $eligible_rows"

  if [ "$eligible_rows" -gt "$MAX_DELETE_ROWS" ]; then
    fail "eligible rows ($eligible_rows) exceed MAX_DELETE_ROWS ($MAX_DELETE_ROWS)"
  fi

  umask 077
  {
    printf 'CUTOFF_AT=%s\n' "$cutoff_at"
    printf 'ELIGIBLE_ROWS=%s\n' "$eligible_rows"
  } > plan.env

  log "Plan written to plan.env"
}

apply_cleanup() {
  load_plan

  current_eligible_rows="$(count_eligible_rows "$CUTOFF_AT")"
  require_unsigned_integer "current eligible row count" "$current_eligible_rows"

  if [ "$current_eligible_rows" -gt "$MAX_DELETE_ROWS" ]; then
    fail "current eligible rows ($current_eligible_rows) exceed MAX_DELETE_ROWS ($MAX_DELETE_ROWS)"
  fi

  total_deleted=0

  while :; do
    deleted_rows="$(
      PGOPTIONS="-c lock_timeout=5000 -c statement_timeout=60000" \
        psql "$DATABASE_URL" \
          -X \
          -qAt \
          -v ON_ERROR_STOP=1 \
          -v cutoff_at="$CUTOFF_AT" \
          -v batch_size="$BATCH_SIZE" <<'SQL'
WITH doomed AS (
  SELECT id
  FROM audit_logs
  WHERE created_at < (:'cutoff_at')::timestamptz
  ORDER BY created_at, id
  LIMIT (:'batch_size')::integer
  FOR UPDATE SKIP LOCKED
),
deleted AS (
  DELETE FROM audit_logs AS target
  USING doomed
  WHERE target.id = doomed.id
  RETURNING target.id
)
SELECT count(*) FROM deleted;
SQL
    )"

    require_unsigned_integer "deleted row count" "$deleted_rows"
    total_deleted=$((total_deleted + deleted_rows))

    log "Deleted this batch: $deleted_rows; total deleted: $total_deleted"

    [ "$deleted_rows" -gt 0 ] || break

    if [ "$BATCH_SLEEP_SECONDS" -gt 0 ]; then
      sleep "$BATCH_SLEEP_SECONDS"
    fi
  done

  umask 077
  {
    printf 'CUTOFF_AT=%s\n' "$CUTOFF_AT"
    printf 'PLANNED_ROWS=%s\n' "$ELIGIBLE_ROWS"
    printf 'DELETED_ROWS=%s\n' "$total_deleted"
  } > cleanup-report.env

  log "Cleanup completed; total deleted: $total_deleted"
}

verify_cleanup() {
  load_plan

  remaining_rows="$(count_eligible_rows "$CUTOFF_AT")"
  require_unsigned_integer "remaining row count" "$remaining_rows"

  log "Cutoff: $CUTOFF_AT"
  log "Rows still older than cutoff: $remaining_rows"

  [ "$remaining_rows" -eq 0 ] ||
    fail "verification failed: $remaining_rows rows still need cleanup"

  log "Verification passed"
}

usage() {
  printf 'Usage: %s {plan|apply|verify}\n' "$0" >&2
  exit 2
}

require_configuration

case "${1:-}" in
  plan)
    plan_cleanup
    ;;
  apply)
    apply_cleanup
    ;;
  verify)
    verify_cleanup
    ;;
  *)
    usage
    ;;
esac

