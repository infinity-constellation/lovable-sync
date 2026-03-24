#!/usr/bin/env bash
#
# drift-check.sh — Detect drift between Lovable source and production repo
#
# Compares Lovable-owned paths between the source repo and the production
# repo's target branch. Reports divergence without making changes.
#
# Usage: ./drift-check.sh <production-repo-dir>
#
# Requires: yq, rsync, git, diff
#
set -euo pipefail

PROD_DIR="${1:?Usage: drift-check.sh <production-repo-dir>}"
SYNC_CONFIG="${PROD_DIR}/.lovable-sync.yml"

if [[ ! -f "$SYNC_CONFIG" ]]; then
  echo "::error::No .lovable-sync.yml found in ${PROD_DIR}"
  exit 1
fi

# Parse sync config
SOURCE_REPO=$(yq '.source_repo' "$SYNC_CONFIG")
SOURCE_BRANCH=$(yq '.source_branch // "main"' "$SYNC_CONFIG")
TARGET_BRANCH=$(yq '.target_branch // "staging"' "$SYNC_CONFIG")

echo "Drift check config:"
echo "  source: ${SOURCE_REPO}@${SOURCE_BRANCH}"
echo "  target: ${TARGET_BRANCH}"

# Clone source repo
SOURCE_DIR=$(mktemp -d)
trap 'rm -rf "$SOURCE_DIR"' EXIT

echo "Cloning source repo ${SOURCE_REPO}..."
git clone --depth=1 --branch "${SOURCE_BRANCH}" \
  "https://x-access-token:${GITHUB_TOKEN}@github.com/${SOURCE_REPO}.git" \
  "${SOURCE_DIR}" 2>&1

SOURCE_SHA=$(git -C "$SOURCE_DIR" rev-parse --short HEAD)
echo "Source HEAD: ${SOURCE_SHA}"

# Ensure production repo is on target branch
git -C "$PROD_DIR" fetch origin "${TARGET_BRANCH}" 2>&1 || true
git -C "$PROD_DIR" checkout "origin/${TARGET_BRANCH}" --detach 2>&1
PROD_SHA=$(git -C "$PROD_DIR" rev-parse --short HEAD)
echo "Production HEAD (${TARGET_BRANCH}): ${PROD_SHA}"

# Build list of included paths from config
INCLUDE_PATHS=()
INCLUDE_COUNT=$(yq '.include_paths | length' "$SYNC_CONFIG")
for (( i=0; i<INCLUDE_COUNT; i++ )); do
  pattern=$(yq ".include_paths[$i]" "$SYNC_CONFIG")
  INCLUDE_PATHS+=("$pattern")
done

# Build exclude list
EXCLUDE_PATHS=()
EXCLUDE_COUNT=$(yq '.exclude_paths | length' "$SYNC_CONFIG")
for (( i=0; i<EXCLUDE_COUNT; i++ )); do
  pattern=$(yq ".exclude_paths[$i]" "$SYNC_CONFIG")
  EXCLUDE_PATHS+=("$pattern")
done

# Create temporary directories with only included files for comparison
COMPARE_SOURCE=$(mktemp -d)
COMPARE_PROD=$(mktemp -d)
trap 'rm -rf "$SOURCE_DIR" "$COMPARE_SOURCE" "$COMPARE_PROD"' EXIT

# Copy included paths from source
for pattern in "${INCLUDE_PATHS[@]}"; do
  # Use find with the pattern to locate matching files
  # Convert glob to find pattern
  base_dir=$(echo "$pattern" | sed 's|/\*\*||; s|/\*||; s|\*||')
  if [[ -d "${SOURCE_DIR}/${base_dir}" ]]; then
    mkdir -p "${COMPARE_SOURCE}/${base_dir}"
    rsync -a "${SOURCE_DIR}/${base_dir}/" "${COMPARE_SOURCE}/${base_dir}/" 2>/dev/null || true
  elif [[ -f "${SOURCE_DIR}/${pattern}" ]]; then
    dir=$(dirname "$pattern")
    mkdir -p "${COMPARE_SOURCE}/${dir}"
    cp "${SOURCE_DIR}/${pattern}" "${COMPARE_SOURCE}/${pattern}" 2>/dev/null || true
  fi
done

# Copy included paths from production
for pattern in "${INCLUDE_PATHS[@]}"; do
  base_dir=$(echo "$pattern" | sed 's|/\*\*||; s|/\*||; s|\*||')
  if [[ -d "${PROD_DIR}/${base_dir}" ]]; then
    mkdir -p "${COMPARE_PROD}/${base_dir}"
    rsync -a "${PROD_DIR}/${base_dir}/" "${COMPARE_PROD}/${base_dir}/" 2>/dev/null || true
  elif [[ -f "${PROD_DIR}/${pattern}" ]]; then
    dir=$(dirname "$pattern")
    mkdir -p "${COMPARE_PROD}/${dir}"
    cp "${PROD_DIR}/${pattern}" "${COMPARE_PROD}/${pattern}" 2>/dev/null || true
  fi
done

# Remove excluded paths from both comparison dirs
for pattern in "${EXCLUDE_PATHS[@]}"; do
  base_dir=$(echo "$pattern" | sed 's|/\*\*||; s|/\*||; s|\*||')
  rm -rf "${COMPARE_SOURCE:?}/${base_dir}" 2>/dev/null || true
  rm -rf "${COMPARE_PROD:?}/${base_dir}" 2>/dev/null || true
done

# Compare
DIFF_OUTPUT=$(diff -rq "$COMPARE_SOURCE" "$COMPARE_PROD" 2>/dev/null || true)

if [[ -z "$DIFF_OUTPUT" ]]; then
  echo "No drift detected. Source and production are in sync."
  {
    echo "has_drift=false"
    echo "drift_summary=No drift detected"
  } >> "${GITHUB_OUTPUT:-/dev/null}"
  exit 0
fi

# Parse drift (grep -c returns count; || true prevents pipefail exit on zero matches)
FILES_ONLY_IN_SOURCE=$(echo "$DIFF_OUTPUT" | grep -c "^Only in ${COMPARE_SOURCE}" || true)
FILES_ONLY_IN_PROD=$(echo "$DIFF_OUTPUT" | grep -c "^Only in ${COMPARE_PROD}" || true)
FILES_DIFFER=$(echo "$DIFF_OUTPUT" | grep -c "^Files .* differ$" || true)

TOTAL_DRIFT=$((FILES_ONLY_IN_SOURCE + FILES_ONLY_IN_PROD + FILES_DIFFER))

echo ""
echo "=== DRIFT DETECTED ==="
echo "  New in source (not in production): ${FILES_ONLY_IN_SOURCE}"
echo "  Only in production (not in source): ${FILES_ONLY_IN_PROD}"
echo "  Modified (different content): ${FILES_DIFFER}"
echo "  Total drifted paths: ${TOTAL_DRIFT}"
echo ""

# Clean up paths in output for readability
CLEAN_DIFF=$(echo "$DIFF_OUTPUT" | \
  sed "s|${COMPARE_SOURCE}|source|g" | \
  sed "s|${COMPARE_PROD}|production|g")

echo "$CLEAN_DIFF"

# Export outputs
{
  echo "has_drift=true"
  echo "files_only_in_source=${FILES_ONLY_IN_SOURCE}"
  echo "files_only_in_prod=${FILES_ONLY_IN_PROD}"
  echo "files_differ=${FILES_DIFFER}"
  echo "total_drift=${TOTAL_DRIFT}"
  echo "drift_summary<<EOF"
  echo "$CLEAN_DIFF"
  echo "EOF"
} >> "${GITHUB_OUTPUT:-/dev/null}"

echo ""
echo "Run the sync workflow to resolve this drift."
