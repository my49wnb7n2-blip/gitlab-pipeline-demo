#!/bin/sh

set -eu

SCRIPT_DIRECTORY="$(
  CDPATH='' cd -- "$(dirname -- "$0")" && pwd
)"
PROJECT_DIRECTORY="$(
  CDPATH='' cd -- "$SCRIPT_DIRECTORY/.." && pwd
)"
TEST_DATABASE="gitlab_pipeline_demo_test_$$"
TEST_WORK_DIRECTORY="$(
  mktemp -d "${TMPDIR:-/tmp}/gitlab-pipeline-demo-test.XXXXXX"
)"

cleanup() {
  dropdb --if-exists "$TEST_DATABASE" >/dev/null 2>&1 || true
  rm -f \
    "$TEST_WORK_DIRECTORY/plan.env" \
    "$TEST_WORK_DIRECTORY/cleanup-report.env"
  rmdir "$TEST_WORK_DIRECTORY" >/dev/null 2>&1 || true
}

trap cleanup 0
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for required_command in createdb dropdb pg_isready psql; do
  command -v "$required_command" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required\n' "$required_command" >&2
    exit 1
  }
done

pg_isready >/dev/null 2>&1 || {
  printf 'ERROR: local PostgreSQL is not accepting connections\n' >&2
  exit 1
}

createdb "$TEST_DATABASE"

export DATABASE_URL="postgresql:///$TEST_DATABASE"
export RETENTION_DAYS=90
export BATCH_SIZE=2
export BATCH_SLEEP_SECONDS=0
export MAX_DELETE_ROWS=100

psql "$DATABASE_URL" \
  -v ON_ERROR_STOP=1 \
  -f "$PROJECT_DIRECTORY/sql/schema.sql"
psql "$DATABASE_URL" \
  -v ON_ERROR_STOP=1 \
  -f "$PROJECT_DIRECTORY/sql/indexes.sql"
psql "$DATABASE_URL" \
  -v ON_ERROR_STOP=1 \
  -f "$PROJECT_DIRECTORY/sql/seed_test_data.sql"

cd "$TEST_WORK_DIRECTORY"

"$PROJECT_DIRECTORY/scripts/maintenance.sh" plan
"$PROJECT_DIRECTORY/scripts/maintenance.sh" apply
"$PROJECT_DIRECTORY/scripts/maintenance.sh" verify

remaining_rows="$(
  psql "$DATABASE_URL" -X -qAt \
    -c 'SELECT count(*) FROM audit_logs;'
)"
null_ids="$(
  psql "$DATABASE_URL" -X -qAt \
    -c 'SELECT count(*) FROM audit_logs WHERE id IS NULL;'
)"

[ "$remaining_rows" = "2" ] || {
  printf 'ERROR: expected 2 recent rows, found %s\n' "$remaining_rows" >&2
  exit 1
}

[ "$null_ids" = "0" ] || {
  printf 'ERROR: expected every row to have a UUID\n' >&2
  exit 1
}

printf '%s\n' "Local integration test passed"
