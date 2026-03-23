# lovable-sync

Reusable GitHub Actions workflows for syncing Lovable-connected repos to production repos.

## Problem

Lovable generates code in its own GitHub repo and syncs two-way with the `main` branch. Production repos need additional scaffolding (Dockerfiles, CI/CD workflows, Helm values, nginx configs) that Lovable doesn't know about. Without automation, the Lovable repo and production repo drift apart, and manual merges become painful.

## How It Works

```
artifact-atlas-view (Lovable <-> GitHub, two-way sync on main)
        |
        |  push to main triggers dispatch
        v
infinity-factory-web (staging branch = deployed)
        |
        |  sync workflow: clone source, rsync included paths, open PR
        v
    PR targeting staging --> CI validates --> merge --> deploy
```

1. Lovable pushes to `main` in the Lovable-connected repo
2. A dispatch workflow in that repo fires `repository_dispatch` to the production repo
3. The production repo's sync workflow calls this repo's reusable workflow
4. The reusable workflow reads `.factory-sync.yml` from the production repo
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

## Setup Guide: Onboarding a New Lovable App

### Prerequisites

- A Lovable-connected repo (e.g., `artifact-atlas-view`) — this is created by Lovable and must NOT be renamed
- A production repo (e.g., `infinity-factory-web`) with deployment scaffolding
- A GitHub PAT (classic) or fine-grained token with:
  - `repo` scope on both the Lovable repo and the production repo
  - Used for cross-repo cloning and dispatch

### Step 1: Create a GitHub PAT

1. Go to https://github.com/settings/tokens
2. Create a **classic** token (or fine-grained with repo access to both repos)
3. Grant `repo` scope
4. Copy the token — you'll use it in two places

### Step 2: Add `.factory-sync.yml` to the production repo

Create `.factory-sync.yml` in the **root** of the production repo (on whatever branch you want the sync to target, typically `staging`):

```yaml
# .factory-sync.yml
source_repo: infinity-constellation/your-lovable-repo
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
  - .factory-sync.yml
  - scripts/**

pr:
  labels:
    - lovable-sync
    - automated
  assignees: []
  auto_merge: false
```

Adjust `include_paths` and `exclude_paths` for your app. The rule of thumb:
- **include**: anything Lovable generates (pages, components, data, config files)
- **exclude**: anything you added for production (CI, Docker, Helm, lockfiles, lint overrides)

### Step 3: Add caller workflows to the production repo

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

jobs:
  sync:
    uses: infinity-constellation/lovable-sync/.github/workflows/sync.yml@main
    with:
      dry_run: ${{ github.event.inputs.dry_run == 'true' || false }}
    secrets:
      source_repo_token: ${{ secrets.LOVABLE_SYNC_TOKEN }}
```

**`.github/workflows/lovable-drift-check.yml`** — scheduled drift detection:

```yaml
name: Lovable Drift Check

on:
  workflow_dispatch: {}
  schedule:
    - cron: '0 6 * * 1'  # Every Monday at 6am UTC

jobs:
  drift-check:
    uses: infinity-constellation/lovable-sync/.github/workflows/drift-check.yml@main
    secrets:
      source_repo_token: ${{ secrets.LOVABLE_SYNC_TOKEN }}
```

### Step 4: Add the token as a repository secret

In the **production repo** settings:

1. Go to Settings > Secrets and variables > Actions
2. Add a new repository secret: `LOVABLE_SYNC_TOKEN`
3. Paste the PAT from Step 1

### Step 5: Add dispatch workflow to the Lovable repo

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
      - name: Trigger sync in production repo
        uses: peter-evans/repository-dispatch@v3
        with:
          repository: infinity-constellation/your-production-repo
          token: ${{ secrets.SYNC_DISPATCH_TOKEN }}
          event-type: lovable-sync
          client-payload: |
            {
              "source_repo": "${{ github.repository }}",
              "source_sha": "${{ github.sha }}",
              "source_ref": "${{ github.ref }}",
              "source_message": "${{ github.event.head_commit.message }}"
            }
```

In the **Lovable repo** settings:

1. Go to Settings > Secrets and variables > Actions
2. Add a new repository secret: `SYNC_DISPATCH_TOKEN`
3. Paste the same PAT from Step 1

### Step 6: Test it

1. Run the sync workflow manually from the production repo's Actions tab (workflow_dispatch)
2. Verify a PR is created targeting the correct branch
3. Check the PR diff — only included paths should be changed, excluded paths untouched
4. Merge the PR and confirm CI/CD picks it up

### Step 7 (optional): Run the first sync manually

For repos with significant drift (many commits ahead), you may want to run the first sync manually via `workflow_dispatch` to review the PR carefully before enabling automated dispatch.

## Configuration Reference

### `.factory-sync.yml`

| Field | Required | Default | Description |
|-------|----------|---------|-------------|
| `source_repo` | yes | — | GitHub `org/repo` of the Lovable-connected repo |
| `source_branch` | no | `main` | Branch to read from in the source repo |
| `target_branch` | no | `staging` | Branch to target for sync PRs in the production repo |
| `include_paths` | yes | — | Glob patterns of paths to sync from source |
| `exclude_paths` | no | `[]` | Glob patterns of paths to never overwrite |
| `pr.labels` | no | `[]` | Labels to apply to sync PRs |
| `pr.assignees` | no | `[]` | GitHub usernames to assign to sync PRs |
| `pr.auto_merge` | no | `false` | Enable auto-merge (squash) if CI passes |

### Secrets

| Secret | Where | Description |
|--------|-------|-------------|
| `LOVABLE_SYNC_TOKEN` | Production repo | PAT with `repo` scope — used to clone the Lovable source repo and create PRs |
| `SYNC_DISPATCH_TOKEN` | Lovable repo | PAT with `repo` scope — used to fire `repository_dispatch` to the production repo |

These can be the same PAT if it has access to both repos.

## Important Notes

- **Never rename a Lovable-connected repo.** Lovable docs warn that renaming breaks the sync permanently with no way to re-link.
- **`package-lock.json` is excluded by default.** Lovable uses `bun.lock`; production repos typically use `npm`. The lockfile should be regenerated in CI after sync.
- **The sync is one-way** (Lovable repo -> production repo). Production-only changes (in excluded paths) are never pushed back to the Lovable repo.
- **Conflicts**: If the same file is modified in both repos (e.g., `src/App.tsx` edited manually in production AND by Lovable), the sync will overwrite with the Lovable version. Keep production-specific changes in excluded paths or separate files.

## Related Repos

This repo handles **sync automation only**. The full Lovable-to-Production pipeline spans several repos:

| Repo | Owns | Docs |
|------|------|------|
| [`lovable-sync`](https://github.com/infinity-constellation/lovable-sync) | Reusable sync & drift-check workflows, `.factory-sync.yml` contract | This README |
| [`devshop-infra`](https://github.com/infinity-constellation/devshop-infra) | Terraform modules (CD pipeline, ECR, CodeBuild, EKS access), Helm charts, buildspecs, infrastructure context | `CONTEXT.md` — sections: Lovable App Pipeline, Infinity Factory Deployment |
| [`launchpad-lovable-wrapper`](https://github.com/infinity-constellation/launchpad-lovable-wrapper) | Reference app-level scaffolding: Dockerfile, nginx.conf (OpenResty + OIDC Lua), Helm values, CI/CD workflows | `README.md` |

### What lives where

- **"How do I set up sync for a new Lovable app?"** — This repo (`lovable-sync` README)
- **"How do I create the Terraform infra for a new app?"** — `devshop-infra` CONTEXT.md, Lovable App Pipeline section
- **"What goes in a production repo's Dockerfile / nginx / Helm values?"** — `launchpad-lovable-wrapper` as the reference implementation
- **"What decisions were made for a specific app?"** — That app's production repo (e.g., `infinity-factory-web/.factory-sync.yml` and `devops/`)
