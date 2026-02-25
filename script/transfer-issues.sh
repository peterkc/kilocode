#!/usr/bin/env bash
# Transfers all open issues from Kilo-Org/kilo to Kilo-Org/kilocode
# Usage: ./script/transfer-issues.sh
# Requirements: gh CLI authenticated with sufficient permissions on both repos

set -euo pipefail

SRC="Kilo-Org/kilo"
DST="Kilo-Org/kilocode"

echo "Fetching issues from $SRC..."

issues=$(gh issue list --repo "$SRC" --state open --limit 1000 --json number,title,body,labels,assignees)

count=$(echo "$issues" | jq length)
echo "Found $count open issues to transfer."

echo "$issues" | jq -c '.[]' | while read -r issue; do
  number=$(echo "$issue" | jq -r '.number')
  title=$(echo "$issue" | jq -r '.title')
  body=$(echo "$issue" | jq -r '.body // ""')
  labels=$(echo "$issue" | jq -r '[.labels[].name] | join(",")')
  assignees=$(echo "$issue" | jq -r '[.assignees[].login] | join(",")')

  footer="\n\n---\n_Transferred from $SRC#$number_"
  full_body="${body}${footer}"

  args=(--repo "$DST" --title "$title" --body "$full_body")

  if [[ -n "$labels" ]]; then
    args+=(--label "$labels")
  fi

  if [[ -n "$assignees" ]]; then
    args+=(--assignee "$assignees")
  fi

  echo "Creating issue #$number: $title"
  gh issue create "${args[@]}"
done

echo "Done. All issues transferred to $DST."
