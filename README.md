# lovable-sync

Reusable GitHub Actions workflows for one-way syncing a [Lovable](https://lovable.dev)-connected GitHub repo into a separate production repo.

## Why This Exists

### Lovable already has GitHub sync — why do I need this?

Lovable has **built-in two-way sync** between the Lovable platform and a single GitHub repo. That sync is:

- **Whole-repo**: every file in the repo is mirrored 1:1 between Lovable and GitHub
- **Two-way**: edits in Lovable push to GitHub; edits on GitHub pull back into Lovable
- **Locked to one repo**: the repo is created by Lovable and [cannot be renamed](https://docs.lovable.dev/integrations/git-integration/github#important-considerations) without permanently breaking the link
- **Default-branch only**: Lovable syncs only the default branch (typically `main`)

This works perfectly for the **Lovable editing loop** — but it doesn't cover deployment. Production apps need things Lovable doesn't know about:

- Dockerfiles and container configs
- CI/CD pipelines (build, test, deploy)
- Helm charts / Kubernetes manifests
- nginx configs, environment files
- Lockfiles for a different package manager (`npm` vs `bun`)

You can't add these to the Lovable repo without Lovable syncing them back and potentially conflicting. And you can't use the Lovable repo directly as your production repo because Lovable owns the whole thing.

### What lovable-sync does

`lovable-sync` bridges the gap. It's a **one-way, selective sync** from the Lovable-connected GitHub repo into a separate production repo:

```
Lovable platform
    ↕  (built-in two-way sync — whole repo, main branch)
your-lovable-repo (GitHub)
    ↓  (lovable-sync — one-way, selective paths, opens PR)
your-production-repo (GitHub)
    ↓  (your CI/CD — build, test, deploy)
production
```

- **One-way**: Lovable repo → production repo. Never the reverse.
- **Selective**: Only paths you configure get synced (`src/`, `index.html`, config files). Production-only files (`Dockerfile`, `.github/workflows/`, `devops/`) are never touched.
- **PR-based**: Changes arrive as a pull request for review, not direct pushes.
- **Drift detection**: A scheduled workflow detects when the two repos have diverged.

The two tools are **complementary**: Lovable's sync keeps Lovable and its GitHub repo in lockstep. `lovable-sync` moves the code that matters from that repo into your production pipeline.

## How It Works

1. Lovable pushes to `main` in the Lovable-connected repo
2. A dispatch workflow in that repo fires `repository_dispatch` to the production repo
3. The production repo's caller workflow invokes this repo's reusable workflow
4. The reusable workflow reads `.lovable-sync.yml` from the production repo
5. It clones the Lovable repo, rsyncs only the included paths (respecting exclusions), and opens a PR targeting the configured branch
6. CI runs on the PR. Merge manually or enable auto-merge.

## Components

| File | Purpose |
|------|---------|
| `.github/workflows/sync.yml` | Reusable sync workflow (called via `workflow_call`) |
| `.github/workflows/drift-check.yml` | Reusable drift detection workflow |
| `scripts/sync.sh` | Core sync logic (rsync with include/exclude from config) |
| `scripts/drift-check.sh` | Core drift comparison logic |
| `examples/` | Example configs and caller workflows |

## Setup Guide

### Prerequisites

- A Lovable-connected repo (created by Lovable — do NOT rename it)
- A production repo with your deployment scaffolding
- Authentication: either a **GitHub App** (recommended) or a **PAT** (see Step 1)

### Step 1: Set Up Authentication

#### Option A: GitHub App (Recommended)

A dedicated GitHub App provides short-lived tokens with no rotation concerns.

1. Create a GitHub App in your org with these permissions:
   - **Repository permissions**: `contents: write`, `pull_requests: write`, `metadata: read`
2. Install the app on both the Lovable repo and the production repo
3. Note the **App ID** and download the **private key** (PEM file)
4. Add these as repository secrets on **both repos**:
   - `LOVABLE_SYNC_APP_ID` — the App ID
   - `LOVABLE_SYNC_APP_PRIVATE_KEY` — the PEM file contents

#### Option B: Personal Access Token (PAT)

1. Go to https://github.com/settings/tokens
2. Create a **classic** token (or fine-grained with repo access to both repos)
3. Grant `repo` scope
4. Add it as a repository secret:
   - On the **production repo**: `LOVABLE_SYNC_TOKEN`
   - On the **Lovable repo**: `SYNC_DISPATCH_TOKEN` (can be the same PAT)

### Step 2: Add `.lovable-sync.yml` to the Production Repo

Create `.lovable-sync.yml` in the **root** of the production repo on the target branch (typically `staging`):

```yaml
# .lovable-sync.yml
source_repo: your-org/your-lovable-repo
source_branch: main
target_branch: staging

# Paths owned by Lovable — these get synced (overwritten) from source
include_paths:
  - src/pages/**
  - src/components/**
  - src/data/**
  - src/hooks/**
  - src/lib/**
  - src/App.tsx
  - src/main.tsx
  - src/index.css
  - src/App.css
  - index.html
  - package.json
  - tsconfig*.json
  - vite.config.ts
  - tailwind.config.ts
  - postcss.config.js
  - components.json

# Paths owned by production — never overwritten by sync
exclude_paths:
  - .github/**
  - devops/**
  - Dockerfile.production
  - package-lock.json
  - eslint.config.js
  - .lovable-sync.yml
  - scripts/**

pr:
  labels:
    - lovable-sync
    - automated
  assignees: []
  auto_merge: false
```

Adjust `include_paths` and `exclude_paths` for your app:
- **include**: anything Lovable generates (pages, components, data, config files)
- **exclude**: anything you added for production (CI, Docker, Helm, lockfiles, lint configs)

### Step 3: Add Caller Workflows to the Production Repo

Create two workflow files in the production repo's `.github/workflows/`:

**`.github/workflows/lovable-sync.yml`** — triggers the sync:

```yaml
name: Lovable Sync

on:
  repository_dispatch:
    types: [lovable-sync]
  workflow_dispatch:
    inputs:
      dry_run:
        description: "Dry run (report only, no PR)"
        type: boolean
        default: false

permissions:
  contents: write
  pull-requests: write

jobs:
  sync:
    uses: your-org/lovable-sync/.github/workflows/sync.yml@main
    with:
      dry_run: ${{ github.event.inputs.dry_run == 'true' || false }}
    secrets:
      # GitHub App auth (recommended):
      app_id: ${{ secrets.LOVABLE_SYNC_APP_ID }}
      app_private_key: ${{ secrets.LOVABLE_SYNC_APP_PRIVATE_KEY }}
      # OR PAT auth (legacy):
      # source_repo_token: ${{ secrets.LOVABLE_SYNC_TOKEN }}
```

**`.github/workflows/lovable-drift-check.yml`** — scheduled drift detection:

```yaml
name: Lovable Drift Check

on:
  workflow_dispatch: {}
  schedule:
    - cron: '0 6 * * 1'  # Every Monday at 6am UTC

permissions:
  contents: read

jobs:
  drift-check:
    uses: your-org/lovable-sync/.github/workflows/drift-check.yml@main
    secrets:
      # GitHub App auth (recommended):
      app_id: ${{ secrets.LOVABLE_SYNC_APP_ID }}
      app_private_key: ${{ secrets.LOVABLE_SYNC_APP_PRIVATE_KEY }}
      # OR PAT auth (legacy):
      # source_repo_token: ${{ secrets.LOVABLE_SYNC_TOKEN }}
```

> **Important**: The `permissions` block is required. Without it, the default `GITHUB_TOKEN` may not have sufficient permissions and the workflow will fail at startup with no logs.

### Step 4: Add Dispatch Workflow to the Lovable Repo

Create `.github/workflows/dispatch-sync.yml` in the **Lovable-connected repo**:

```yaml
name: Dispatch Lovable Sync

on:
  push:
    branches: [main]
    paths:
      - 'src/**'
      - 'index.html'
      - 'package.json'
      - 'vite.config.ts'
      - 'tailwind.config.ts'
      - 'tsconfig*.json'
      - 'components.json'

jobs:
  dispatch:
    runs-on: ubuntu-latest
    steps:
      - name: Generate GitHub App token
        id: app-token
        uses: actions/create-github-app-token@v1
        with:
          app-id: ${{ secrets.LOVABLE_SYNC_APP_ID }}
          private-key: ${{ secrets.LOVABLE_SYNC_APP_PRIVATE_KEY }}
          owner: ${{ github.repository_owner }}

      - name: Trigger sync in production repo
        uses: peter-evans/repository-dispatch@v3
        with:
          repository: your-org/your-production-repo
          token: ${{ steps.app-token.outputs.token }}
          event-type: lovable-sync
          client-payload: |
            {
              "source_repo": "${{ github.repository }}",
              "source_sha": "${{ github.sha }}",
              "source_ref": "${{ github.ref }}",
              "source_message": "${{ github.event.head_commit.message }}"
            }
```

> If using a PAT instead of a GitHub App, replace the app-token step with `token: ${{ secrets.SYNC_DISPATCH_TOKEN }}`.

### Step 5: Test It

1. Run the sync workflow manually from the production repo's Actions tab (`workflow_dispatch`)
2. Use `dry_run: true` for the first run to see what would change
3. Verify the PR diff — only included paths should be changed, excluded paths untouched
4. Merge the PR and confirm your CI/CD picks it up

## Configuration Reference

### `.lovable-sync.yml`

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `source_repo` | yes | -- | GitHub `org/repo` of the Lovable-connected repo |
| `source_branch` | no | `main` | Branch to read from in the source repo |
| `target_branch` | no | `staging` | Branch to target for sync PRs in the production repo |
| `include_paths` | yes | -- | Glob patterns of paths to sync from source |
| `exclude_paths` | no | `[]` | Glob patterns of paths to never overwrite |
| `pr.labels` | no | `[]` | Labels to apply to sync PRs |
| `pr.assignees` | no | `[]` | GitHub usernames to assign to sync PRs |
| `pr.auto_merge` | no | `false` | Enable auto-merge (squash) if CI passes |

### Secrets

**GitHub App (recommended):**

| Secret | Where | Description |
|--------|-------|-------------|
| `LOVABLE_SYNC_APP_ID` | Both repos | GitHub App ID |
| `LOVABLE_SYNC_APP_PRIVATE_KEY` | Both repos | GitHub App private key (PEM) |

**PAT (legacy):**

| Secret | Where | Description |
|--------|-------|-------------|
| `LOVABLE_SYNC_TOKEN` | Production repo | PAT with `repo` scope for cloning source and creating PRs |
| `SYNC_DISPATCH_TOKEN` | Lovable repo | PAT with `repo` scope for cross-repo dispatch |

These can be the same PAT if it has access to both repos.

## Gotchas

- **Never rename a Lovable-connected repo.** Lovable docs warn that renaming breaks the sync permanently with no way to re-link.
- **`package-lock.json` should be excluded.** Lovable uses `bun.lock`; production repos typically use `npm`. Regenerate the lockfile in CI after sync.
- **The sync is one-way.** Production-only changes (in excluded paths) are never pushed back to the Lovable repo.
- **File conflicts**: If the same file is modified in both repos, the sync overwrites with the Lovable version. Keep production-specific changes in excluded paths or separate files.
- **Caller workflows need a `permissions` block.** Without explicit permissions, the default `GITHUB_TOKEN` may be read-only, causing `startup_failure` with no error logs.
- **Reusable workflows must be in a public repo** (or the org must be on GitHub Enterprise for `internal` visibility). This repo is public for that reason.

## License

MIT
