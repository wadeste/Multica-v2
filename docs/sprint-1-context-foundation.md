# Multica Sprint 1 — Context Foundation
> Goal: agents know what project they're in, what the code looks like, and what "done" means.  
> No behaviour-breaking changes. All additions are additive.

---

## Overview

| Day | Focus | Risk |
|---|---|---|
| 1 | Inject acceptance criteria + project context into agent prompt | Zero — no DB changes |
| 2 | DB migration: repo_url, repo_branch, brief, done_checklist | Low — additive columns |
| 3 | API + TypeScript types for new project fields | Low |
| 4 | UI: project settings panel (repo, brief, DoD editor) | Low |
| 5 | Daemon: auto-checkout + inject brief + DoD into agent runtime config | Medium |
| 6 | End-to-end testing + staging deploy | — |

---

## Day 1 — Agent Context (zero DB changes)

### Task 1.1 — Pass project data through daemon task dispatch

**Problem:** `TaskContextForEnv` in `server/internal/daemon/execenv/execenv.go` has no project fields. The daemon never fetches the project when building task context.

**Files to change:**
- `server/internal/daemon/execenv/execenv.go` — add `ProjectContextForEnv` struct + field on `TaskContextForEnv`
- `server/internal/daemon/daemon.go` — fetch project by `issue.ProjectID` when claiming a task, populate `ProjectContextForEnv`

**New struct (execenv.go):**
```go
type ProjectContextForEnv struct {
    ID          string
    Title       string
    Description string
}
```

**Add to TaskContextForEnv:**
```go
Project *ProjectContextForEnv // nil when issue has no project
```

**Daemon change (daemon.go):**
After fetching the issue on task claim, if `issue.ProjectID` is set, call `db.GetProject(ctx, issue.ProjectID)` and populate `ProjectContextForEnv`. Nil-safe — issues without projects work as before.

---

### Task 1.2 — Inject project context into CLAUDE.md / AGENTS.md

**File:** `server/internal/daemon/execenv/runtime_config.go`  
**Function:** `buildMetaSkillContent()`

**Add after "Agent Identity" section, before "Available Commands":**
```
## Project

**Project:** {title}
{description — if set}
```

Only rendered when `ctx.Project != nil`.

---

### Task 1.3 — Inject acceptance criteria into agent prompt

**Problem:** `issue.AcceptanceCriteria` is fetched by the daemon but never passed to `execenv` or injected into the agent's runtime config.

**Files to change:**
- `server/internal/daemon/execenv/execenv.go` — add `AcceptanceCriteria string` to `TaskContextForEnv`
- `server/internal/daemon/daemon.go` — populate `AcceptanceCriteria` from the issue (need to decode the jsonb — check its shape first)
- `server/internal/daemon/execenv/runtime_config.go` — inject into workflow section

**Check acceptance_criteria shape first:**
```bash
cd server && grep -r "AcceptanceCriteria\|acceptance_criteria" internal/ pkg/ --include="*.go" | head -20
```

**Inject in runtime_config.go** — add after the issue step in the assignment workflow:
```
## Acceptance Criteria

Before marking this issue done, verify all of the following:

{acceptance_criteria content}
```

Only rendered when non-empty.

---

## Day 2 — Database Migration

### Task 2.1 — Write migration 059

**File:** `server/migrations/059_project_agent_context.up.sql`

```sql
ALTER TABLE project
    ADD COLUMN repo_url     TEXT,
    ADD COLUMN repo_branch  TEXT NOT NULL DEFAULT 'main',
    ADD COLUMN brief        TEXT,
    ADD COLUMN done_checklist JSONB;
```

**Rollback:** `server/migrations/059_project_agent_context.down.sql`
```sql
ALTER TABLE project
    DROP COLUMN IF EXISTS repo_url,
    DROP COLUMN IF EXISTS repo_branch,
    DROP COLUMN IF EXISTS brief,
    DROP COLUMN IF EXISTS done_checklist;
```

**done_checklist shape:**
```json
[
  { "label": "Tests added or updated", "required": true },
  { "label": "PR link posted in final comment", "required": true },
  { "label": "Acceptance criteria addressed", "required": false }
]
```

---

### Task 2.2 — Update sqlc queries

**File:** `server/pkg/db/queries/project.sql`

Add new columns to `CreateProject` and `UpdateProject`:

```sql
-- name: CreateProject :one
INSERT INTO project (
    workspace_id, title, description, icon, status,
    lead_type, lead_id, repo_url, repo_branch, brief, done_checklist
) VALUES (
    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
) RETURNING *;

-- name: UpdateProject :one
UPDATE project SET
    title           = COALESCE(sqlc.narg('title'), title),
    description     = sqlc.narg('description'),
    icon            = sqlc.narg('icon'),
    status          = COALESCE(sqlc.narg('status'), status),
    lead_type       = sqlc.narg('lead_type'),
    lead_id         = sqlc.narg('lead_id'),
    repo_url        = sqlc.narg('repo_url'),
    repo_branch     = COALESCE(sqlc.narg('repo_branch'), repo_branch),
    brief           = sqlc.narg('brief'),
    done_checklist  = sqlc.narg('done_checklist'),
    updated_at      = now()
WHERE id = $1
RETURNING *;
```

**Run:** `make sqlc` to regenerate Go types.

---

## Day 3 — API + TypeScript Types

### Task 3.1 — Update Go Project model (auto-generated, check output)

After `make sqlc`, `server/pkg/db/generated/models.go` will have:
```go
type Project struct {
    // ... existing fields ...
    RepoUrl       pgtype.Text  `json:"repo_url"`
    RepoBranch    string       `json:"repo_branch"`
    Brief         pgtype.Text  `json:"brief"`
    DoneChecklist []byte       `json:"done_checklist"`
}
```

---

### Task 3.2 — Update API handler

**File:** `server/internal/handler/project.go`

Add new fields to the create/update request structs and response mapping. Pass through `repo_url`, `repo_branch`, `brief`, `done_checklist`.

Key points:
- `done_checklist` is JSON — marshal/unmarshal as `[]DoneChecklistItem`
- `repo_branch` defaults to `"main"` at DB level — API can omit it
- All new fields are nullable/optional — no breaking change

---

### Task 3.3 — Update TypeScript types

**File:** `packages/core/types/project.ts`

```typescript
export interface DoneChecklistItem {
  label: string;
  required: boolean;
}

export interface Project {
  // ... existing fields ...
  repo_url: string | null;
  repo_branch: string;
  brief: string | null;
  done_checklist: DoneChecklistItem[] | null;
}

export interface CreateProjectRequest {
  // ... existing fields ...
  repo_url?: string;
  repo_branch?: string;
  brief?: string;
  done_checklist?: DoneChecklistItem[];
}

export interface UpdateProjectRequest {
  // ... existing fields ...
  repo_url?: string | null;
  repo_branch?: string;
  brief?: string | null;
  done_checklist?: DoneChecklistItem[] | null;
}
```

---

### Task 3.4 — Update API client

**File:** `packages/core/api/client.ts`

`createProject()` and `updateProject()` already pass through the request body directly — no changes needed as long as the types are updated.

---

## Day 4 — Project Settings UI

### Task 4.1 — Add repository section to project settings

**File:** `packages/views/projects/components/project-detail.tsx`

Add a collapsible "Repository" section in the project header/settings area (where title, description, lead, status already live):

```
Repository URL   [_________________________]
Branch           [main___________________]
```

- Input for `repo_url` (placeholder: `https://github.com/org/repo`)
- Input for `repo_branch` (placeholder: `main`, default: `main`)
- Save on blur or explicit save button — match the existing pattern for description edits
- Show a git icon + truncated repo name when set, empty state prompt when not

---

### Task 4.2 — Add project brief editor

**File:** `packages/views/projects/components/project-detail.tsx`

Add a "Project Brief" section below the description. Uses the existing `ContentEditor` component (already used for issue descriptions) — same editing experience.

Suggested placeholder content (shown when brief is empty):
```
## About this project
What are we building and why?

## Tech stack & conventions
Key technologies, patterns, important file paths.

## Rules
- Things agents must always do
- Things agents must never do
```

This is the agent's "CLAUDE.md for the project" — make that clear in the UI label/tooltip.

---

### Task 4.3 — Add Definition of Done checklist editor

**File:** `packages/views/projects/components/project-detail.tsx`

A simple checklist builder:
- List of items, each with a label and "required" toggle
- Add item button
- Drag to reorder (optional for Sprint 1 — can be simple list)
- Each item: `[☑ required] [label text] [delete]`

Use existing `Checkbox` from `@multica/ui` and a simple `useState` for edit mode. Save via `useUpdateProject` mutation.

---

## Day 5 — Daemon: Auto-checkout + Brief Injection

### Task 5.1 — Add project repo fields to execenv context

**File:** `server/internal/daemon/execenv/execenv.go`

Extend `ProjectContextForEnv`:
```go
type ProjectContextForEnv struct {
    ID          string
    Title       string
    Description string
    RepoURL     string // empty = no auto-checkout
    RepoBranch  string // defaults to "main"
    Brief       string // empty = not set
    DoneChecklist []DoneChecklistItem
}

type DoneChecklistItem struct {
    Label    string `json:"label"`
    Required bool   `json:"required"`
}
```

---

### Task 5.2 — Auto-checkout in Prepare()

**File:** `server/internal/daemon/execenv/execenv.go`  
**Function:** `Prepare()`

After the directory tree is created and context files are written, if `params.Task.Project != nil && params.Task.Project.RepoURL != ""`:

```go
if p := params.Task.Project; p != nil && p.RepoURL != "" {
    branch := p.RepoBranch
    if branch == "" {
        branch = "main"
    }
    if err := autoCheckoutRepo(params, env, p.RepoURL, branch, logger); err != nil {
        // Log warning but don't fail — agent can still run without repo
        logger.Warn("execenv: auto-checkout failed, agent will run without repo",
            "repo", p.RepoURL, "error", err)
    }
}
```

**New function `autoCheckoutRepo()`** — calls the existing bare-clone cache + worktree logic in `repocache/` directly (same path as `multica repo checkout`, but invoked internally). Agent wakes up with `workdir/repo-name/` already checked out.

---

### Task 5.3 — Inject brief + DoD into runtime_config.go

**File:** `server/internal/daemon/execenv/runtime_config.go`  
**Function:** `buildMetaSkillContent()`

**Add after "Project" section (from Day 1):**

```go
// Project brief
if ctx.Project != nil && ctx.Project.Brief != "" {
    b.WriteString("## Project Brief\n\n")
    b.WriteString(ctx.Project.Brief)
    b.WriteString("\n\n")
}

// Definition of Done
if ctx.Project != nil && len(ctx.Project.DoneChecklist) > 0 {
    b.WriteString("## Definition of Done\n\n")
    b.WriteString("Before marking this issue done or moving to `in_review`, verify each item below and address it in your final comment:\n\n")
    for _, item := range ctx.Project.DoneChecklist {
        required := ""
        if item.Required {
            required = " *(required)*"
        }
        fmt.Fprintf(&b, "- [ ] %s%s\n", item.Label, required)
    }
    b.WriteString("\n")
}
```

---

### Task 5.4 — Update daemon task dispatch to fetch project

**File:** `server/internal/daemon/daemon.go`

In the task claim/dispatch path, after fetching the issue:

```go
var projectCtx *execenv.ProjectContextForEnv
if issue.ProjectID.Valid {
    proj, err := d.db.GetProject(ctx, issue.ProjectID.UUID)
    if err == nil {
        projectCtx = &execenv.ProjectContextForEnv{
            ID:          proj.ID.String(),
            Title:       proj.Title,
            Description: proj.Description.String,
            RepoURL:     proj.RepoUrl.String,
            RepoBranch:  proj.RepoBranch,
            Brief:       proj.Brief.String,
        }
        // Unmarshal done_checklist from JSON
        if len(proj.DoneChecklist) > 0 {
            _ = json.Unmarshal(proj.DoneChecklist, &projectCtx.DoneChecklist)
        }
    }
    // Non-fatal — if project fetch fails, proceed without project context
}
```

---

## Day 6 — Testing & Deploy

### Task 6.1 — Unit tests

- `server/internal/daemon/execenv/execenv_test.go` — test that `Prepare()` auto-checkouts when `Project.RepoURL` is set, and skips gracefully when empty
- `server/internal/daemon/execenv/runtime_config_test.go` (new) — test that brief, DoD, project context, acceptance criteria appear in generated CLAUDE.md when set, absent when nil

### Task 6.2 — Integration test

- Create a project with `repo_url` + `brief` + `done_checklist` via API
- Create an issue in that project
- Assign to an agent
- Verify daemon logs show auto-checkout attempt
- Verify generated CLAUDE.md contains project brief and DoD

### Task 6.3 — Deploy sequence

```bash
# 1. Run migration on staging first
ssh stewade@192.168.1.165 "cd ~/multica-staging && docker compose ... exec backend ./migrate up"

# 2. Verify staging end-to-end

# 3. Merge to staging branch, verify auto-deploy
git checkout staging && git merge main && git push origin staging

# 4. Merge to main → auto-deploys to production
git checkout main && git merge staging && git push origin main

# 5. Production migration runs automatically via entrypoint.sh
```

---

## Key Files Changed — Full List

| File | Change |
|---|---|
| `server/migrations/059_project_agent_context.up.sql` | New migration |
| `server/migrations/059_project_agent_context.down.sql` | Rollback |
| `server/pkg/db/queries/project.sql` | Updated queries |
| `server/pkg/db/generated/` | Regenerated (make sqlc) |
| `server/internal/handler/project.go` | New fields in create/update |
| `server/internal/daemon/execenv/execenv.go` | ProjectContextForEnv, auto-checkout, DoneChecklistItem |
| `server/internal/daemon/execenv/runtime_config.go` | Inject project, brief, DoD, acceptance criteria |
| `server/internal/daemon/daemon.go` | Fetch project on task dispatch |
| `packages/core/types/project.ts` | New fields + DoneChecklistItem type |
| `packages/views/projects/components/project-detail.tsx` | Repo field, brief editor, DoD builder |

---

## Definition of Done for Sprint 1

- [ ] Agent CLAUDE.md contains project title + description when issue is in a project
- [ ] Agent CLAUDE.md contains acceptance criteria when set on the issue
- [ ] Agent CLAUDE.md contains project brief when set
- [ ] Agent CLAUDE.md contains DoD checklist when set
- [ ] Agent starts with repo already checked out when project has `repo_url`
- [ ] Project settings UI has repo, brief, and DoD fields
- [ ] All new DB columns are nullable — no migration failures on existing data
- [ ] Tests pass: `make check`
- [ ] Deployed to staging and verified end-to-end
- [ ] Deployed to production
