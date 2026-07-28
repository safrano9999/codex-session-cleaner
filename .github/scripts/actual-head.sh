#!/usr/bin/env bash
# Source of truth: SCRIPTS/githubactions. Generated copies are overwritten.
set -euo pipefail

artifact_name="actual-head"
log_file="${ACTUAL_HEAD_FILE:-actual-head.txt}"
actual_head_temporary=""

cleanup() {
  [[ -z "${actual_head_temporary:-}" ]] ||
    rm -rf -- "$actual_head_temporary"
}
trap cleanup EXIT

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "$1 is required" >&2
    exit 1
  }
}

start_build() {
  local started_epoch started_at

  : "${GITHUB_ENV:?GITHUB_ENV is required}"
  started_epoch="$(date +%s)"
  started_at="$(TZ=Europe/Vienna date '+%Y-%m-%d %H:%M:%S %z (%Z)')"
  {
    printf 'ACTUAL_HEAD_STARTED_EPOCH=%s\n' "$started_epoch"
    printf 'ACTUAL_HEAD_STARTED_AT=%s\n' "$started_at"
  } >> "$GITHUB_ENV"
}

finish_build() {
  local repository commit short_commit commit_message
  local finished_epoch finished_at duration_seconds duration
  local artifact_rows artifact_record artifact_id artifact_head
  local artifact_zip previous_log previous_head
  local hours minutes seconds

  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  : "${GITHUB_SHA:?GITHUB_SHA is required}"
  : "${GH_TOKEN:?GH_TOKEN is required}"
  : "${ACTUAL_HEAD_STARTED_EPOCH:?Run actual-head.sh start first}"
  : "${ACTUAL_HEAD_STARTED_AT:?Run actual-head.sh start first}"
  require_command gh
  require_command git
  require_command unzip

  repository="$GITHUB_REPOSITORY"
  commit="$GITHUB_SHA"
  [[ "$commit" =~ ^[0-9a-f]{40}$ ]] || {
    echo "Invalid GITHUB_SHA: $commit" >&2
    exit 1
  }
  short_commit="${commit:0:12}"
  commit_message="$(
    git log -1 --format=%B "$commit" |
      tr '\r\n\t' '   ' |
      sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/[|]/\//g'
  )"
  [ -n "$commit_message" ] || commit_message="(empty commit message)"

  finished_epoch="$(date +%s)"
  finished_at="$(TZ=Europe/Vienna date '+%Y-%m-%d %H:%M:%S %z (%Z)')"
  duration_seconds=$((finished_epoch - ACTUAL_HEAD_STARTED_EPOCH))
  (( duration_seconds >= 0 )) || {
    echo "Build duration cannot be negative" >&2
    exit 1
  }
  hours=$((duration_seconds / 3600))
  minutes=$(((duration_seconds % 3600) / 60))
  seconds=$((duration_seconds % 60))
  printf -v duration '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"

  actual_head_temporary="$(mktemp -d)"
  previous_log="$actual_head_temporary/previous-actual-head.txt"
  artifact_zip="$actual_head_temporary/actual-head.zip"

  artifact_rows="$(
    gh api --paginate \
      "/repos/${repository}/actions/artifacts?name=${artifact_name}&per_page=100" \
      --jq '.artifacts[] | [.created_at, .id, .expired, .workflow_run.head_sha] | @tsv' |
      sort -t $'\t' -k1,1r -k2,2nr
  )"
  artifact_record="$(awk -F '\t' '$3 == "false" {print $2 "\t" $4; exit}' <<< "$artifact_rows")"
  IFS=$'\t' read -r artifact_id artifact_head <<< "$artifact_record"
  if [ -n "$artifact_id" ]; then
    [[ "$artifact_head" =~ ^[0-9a-f]{40}$ ]] || {
      echo "Existing $artifact_name artifact has no valid workflow HEAD" >&2
      exit 1
    }
    gh api "/repos/${repository}/actions/artifacts/${artifact_id}/zip" \
      > "$artifact_zip"
    unzip -p "$artifact_zip" "$log_file" > "$previous_log"
    previous_head="$(awk 'NF {line=$0} END {print line}' "$previous_log")"
    [[ "$previous_head" =~ ^[0-9a-f]{40}$ ]] || {
      echo "Existing $log_file has no valid final commit ID" >&2
      exit 1
    }
    [[ "$previous_head" == "$artifact_head" ]] || {
      echo "Existing $log_file HEAD does not match its workflow run" >&2
      exit 1
    }
  fi

  {
    [ ! -s "$previous_log" ] || {
      cat "$previous_log"
      tail -c 1 "$previous_log" | grep -q $'\n' || printf '\n'
    }
    printf '%s | finished=%s | duration=%s (%ss) | commit=%s | message=%s\n' \
      "$ACTUAL_HEAD_STARTED_AT" \
      "$finished_at" \
      "$duration" \
      "$duration_seconds" \
      "$short_commit" \
      "$commit_message"
    printf '%s\n' "$commit"
  } > "$log_file"

  printf 'Updated %s; current build commit: %s\n' "$log_file" "$commit"
}

cleanup_build_logs() {
  local keep_id artifact_ids artifact_id

  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  : "${GH_TOKEN:?GH_TOKEN is required}"
  keep_id="${1:-}"
  [[ "$keep_id" =~ ^[0-9]+$ ]] || {
    echo "Usage: actual-head.sh cleanup ARTIFACT_ID" >&2
    exit 2
  }
  require_command gh

  artifact_ids="$(
    gh api --paginate \
      "/repos/${GITHUB_REPOSITORY}/actions/artifacts?name=${artifact_name}&per_page=100" \
      --jq ".artifacts[] | select(.id < ${keep_id}) | .id"
  )"
  while IFS= read -r artifact_id; do
    [ -n "$artifact_id" ] || continue
    if ! gh api -X DELETE \
      "/repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}" >/dev/null; then
      echo "WARNING: could not delete previous $artifact_name artifact $artifact_id" >&2
    fi
  done <<< "$artifact_ids"
  printf 'Kept %s artifact %s as the current build log\n' "$artifact_name" "$keep_id"
}

case "${1:-}" in
  start)
    start_build
    ;;
  finish)
    finish_build
    ;;
  cleanup)
    cleanup_build_logs "${2:-}"
    ;;
  *)
    echo "Usage: actual-head.sh {start|finish|cleanup ARTIFACT_ID}" >&2
    exit 2
    ;;
esac
