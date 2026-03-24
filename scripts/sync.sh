#!/usr/bin/env bash
#
# sync.sh — Core sync logic for Lovable-to-Production repos
#
# Reads .factory-sync.yml from the production repo, clones the source
# Lovable repo, and copies included paths while respecting exclusions.
# Outputs a branch name and changeset summary for the calling workflow.
#
# Usage: ./sync.sh <production-repo-dir>
#
# Requires: yq, rsync, git
#
set -euo pipefail

PROD_DIR="${1:?Usage: sync.sh <production-repo-dir>}"
SYNC_CONFIG="${PROD_DIR}/.factory-sync.yml"

if [[ ! -f "$SYNC_CONFIG" ]]; then
  echo "::error::No .factory-sync.yml found in ${PROD_DIR}"
  exit 1
fi

# Parse sync config
SOURCE_REPO=$(yq '.source_repo' "$SYNC_CONFIG")
SOURCE_BRANCH=$(yq '.source_branch // "main"' "$SYNC_CONFIG")
TARGET_BRANCH=$(yq '.target_branch // "staging"' "$SYNC_CONFIG")

if [[ -z "$SOURCE_REPO" || "$SOURCE_REPO" == "null" ]]; then
  echo "::error::source_repo not set in .factory-sync.yml"
  exit 1
fi

echo "Sync config:"
echo "  source: ${SOURCE_REPO}@${SOURCE_BRANCH}"
echo "  target: ${TARGET_BRANCH}"

# Clone source repo into temp directory
SOURCE_DIR=$(mktemp -d)
trap 'rm -rf "$SOURCE_DIR"' EXIT

echo "Cloning source repo ${SOURCE_REPO}..."
git clone --depth=1 --branch "${SOURCE_BRANCH}" \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${SOURCE_REPO}.git" \
  "${SOURCE_DIR}" 2>&1

SOURCE_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD)
echo "Source HEAD: ${SOURCE_SHA}"

# Build rsync include/exclude filters from config
RSYNC_FILTERS=$(mktemp)

# First, add excludes (these take priority)
EXCLUDE_COUNT=$(yq '.exclude_paths | length' "$SYNC_CONFIG")
for (( i=0; i<EXCLUDE_COUNT; i++ )); do
  pattern=$(yq ".exclude_paths[$i]" "$SYNC_CONFIG")
  echo "- ${pattern}" >> "$RSYNC_FILTERS"
done

# Then add includes
INCLUDE_COUNT=$(yq '.include_paths | length' "$SYNC_CONFIG")
for (( i=0; i<INCLUDE_COUNT; i++ )); do
  pattern=$(yq ".include_paths[$i]" "$SYNC_CONFIG")
  # For directory globs like src/pages/**, we need to include the parent dirs
  parent_dir=$(dirname "$pattern")
  while [[ "$parent_dir" != "." ]]; do
    echo "+ ${parent_dir}/" >> "$RSYNC_FILTERS"
    parent_dir=$(dirname "$parent_dir")
  done
  echo "+ ${pattern}" >> "$RSYNC_FILTERS"
done

# Exclude everything else
echo "- *" >> "$RSYNC_FILTERS"

echo "Rsync filter rules:"
cat "$RSYNC_FILTERS"

# Create sync branch in production repo
SYNC_BRANCH="lovable-sync/${SOURCE_SHA}-$(date +%Y%m%d-%H%M%S)"

# Ensure we're on the target branch
git -C "$PROD_DIR" fetch origin "${TARGET_BRANCH}" 2>&1 || true
git -C "$PROD_DIR" checkout -B "$SYNC_BRANCH" "origin/${TARGET_BRANCH}" 2>&1

# Rsync from source to production
echo "Syncing files..."
rsync -av --delete \
  --filter="merge ${RSYNC_FILTERS}" \
  "${SOURCE_DIR}/" \
  "${PROD_DIR}/" \
  2>&1

rm -f "$RSYNC_FILTERS"

# Check for changes
if git -C "$PROD_DIR" diff --quiet && git -C "$PROD_DIR" diff --cached --quiet; then
  # Also check for untracked files
  UNTRACKED=$(git -C "$PROD_DIR" ls-files --others --exclude-standard)
  if [[ -z "$UNTRACKED" ]]; then
    echo "No changes detected — source and target are in sync."
    echo "sync_needed=false" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
  fi
fi

# Stage all changes (exclude the tooling checkout)
git -C "$PROD_DIR" add -A -- ':!.lovable-sync'

# Generate changeset summary
DIFF_STAT=$(git -C "$PROD_DIR" diff --cached --stat)
FILES_CHANGED=$(git -C "$PROD_DIR" diff --cached --name-only | wc -l | tr -d ' ')

echo "Changes detected: ${FILES_CHANGED} files"
echo "$DIFF_STAT"

# Commit
git -C "$PROD_DIR" \
  -c user.name="lovable-sync[bot]" \
  -c user.email="lovable-sync[bot]@users.noreply.github.com" \
  commit -m "sync: update from ${SOURCE_REPO}@${SOURCE_SHA}

Automated sync of Lovable-managed files.
Source: ${SOURCE_REPO}@${SOURCE_SHA} (${SOURCE_BRANCH})
Files changed: ${FILES_CHANGED}"

# Push the sync branch
git -C "$PROD_DIR" push origin "$SYNC_BRANCH" 2>&1

# Export outputs for the workflow
{
  echo "sync_needed=true"
  echo "sync_branch=${SYNC_BRANCH}"
  echo "source_sha=${SOURCE_SHA}"
  echo "files_changed=${FILES_CHANGED}"
} >> "${GITHUB_OUTPUT:-/dev/null}"

# Also export the diff stat for PR body (multiline)
{
  echo "diff_stat<<EOF"
  echo "$DIFF_STAT"
  echo "EOF"
} >> "${GITHUB_OUTPUT:-/dev/null}"

echo "Sync branch pushed: ${SYNC_BRANCH}"
