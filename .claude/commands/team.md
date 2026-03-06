Create an agent team called "GridBot" to build/improve GridBot. Use delegate mode — you (the lead) should only coordinate, never write code.

### Documentation Structure

All agent-generated documents live in `docs/agents/` organized by **area** (product domain):

```
docs/agents/
├── TECH_DECISIONS.md        # shared — ADRs (Architecture Decision Records)
│
├── patterns/                # reusable how-to knowledge
│   ├── adding-broker-support.md
│   ├── adding-new-route.md
│   └── ...
│
├── {area}/                  # product domain (dynamic, created as needed)
│   ├── AREA.md              # living architecture doc — accumulated knowledge
│   └── {work-item}/         # verb-noun slug (e.g., add-calendar, fix-loading)
│       ├── BRIEF.md         # always created — goals, scope, acceptance criteria
│       ├── REQUIREMENTS.md  # optional — for complex requirements
│       ├── UX-DESIGN.md     # optional — when UI changes are involved
│       ├── ARCHITECTURE.md  # optional — when technical design decisions needed
│       ├── API_SPEC.md      # optional — when new/changed API endpoints
│       ├── DATA_MODELS.md   # optional — when new/changed models/migrations
│       ├── USER_STORIES.md  # optional — for medium+ work items
│       ├── E2E_TEST_PLAN.md # optional — when E2E testing is warranted
│       ├── PROGRESS.md      # optional — for medium+ work items
│       ├── TEST_RESULTS.md  # created by manual-tester when testing happens
│       ├── CHECKPOINT.md    # persistent task/phase state — survives team restarts
│       ├── designs/         # Figma screenshots / design mockups — visual source of truth for frontend-dev
│       ├── screenshots/     # manual-tester evidence (gitignored, cleaned by documentator)
│       └── tests/           # test cases per user story
│           ├── US01-{story}.md
│           └── ...
```

### Area & Naming Rules

**Areas** are product domains — not tech layers, not pages. They map to both backend and frontend:
- Examples: `dashboard`, `trades`, `reports`, `journal`, `replay`, `imports`, `insights`, `spaces`, `auth`, `settings`, `billing`
- Areas are **dynamic** — the architect creates a new area when nothing existing fits
- Each area has a living `AREA.md` that accumulates architectural knowledge

**Work items** use `{verb}-{subject}` naming:
- Features: `add-calendar`, `add-bulk-tagging`
- Improvements: `improve-filters`, `update-pnl-chart`
- Fixes: `fix-widget-loading`, `fix-filter-reset`
- Removals: `remove-legacy-exports`
- Refactors: `refactor-import-pipeline`

**Deciding where something goes:**
1. Product-manager determines the area based on gathered requirements (Phase 1) — checks existing areas in `docs/agents/`
2. Architect validates the PM's area choice when starting Phase 3 — reads the area's AREA.md
3. If architect disagrees with PM's area → ask the **human owner** to resolve
4. If nothing fits → architect creates a new area with AREA.md
5. If work touches multiple areas → primary area owns the work item, documentator adds cross-references to other AREA.md files

### AREA.md Template

```markdown
# {Area Name}

## Key Files
### Backend
- app/controllers/api/v1/...
- app/models/...
- app/services/...

### Frontend
- frontends/app/src/views/...
- frontends/app/src/components/...

## Architectural Constraints
- [Things the next developer MUST know]
- [Patterns to follow in this area]
- [Dependencies or gotchas]

## Cross-references
- [Links to work items in other areas that affect this one]

## History
- [Date]: [Brief description] (see {work-item}/)
```

### Document Requirements

Only `BRIEF.md` is always required. All other documents are optional — agents decide what's needed based on the scope of work:

- **BRIEF.md** — Always. Goals, scope, acceptance criteria. Even for bug fixes (repro steps + root cause + fix approach).
- **REQUIREMENTS.md** — When there are complex functional/non-functional requirements to enumerate
- **UX-DESIGN.md** — When UI changes are involved
- **ARCHITECTURE.md** — When technical design decisions are needed (new patterns, significant changes)
- **API_SPEC.md** — When new or changed API endpoints exist
- **DATA_MODELS.md** — When new or changed models/migrations/types exist
- **USER_STORIES.md** — For medium+ work items that benefit from structured breakdown
- **E2E_TEST_PLAN.md** — When E2E testing is warranted
- **PROGRESS.md** — For medium+ work items with multiple phases
- **CHECKPOINT.md** — Always created by scrum-master. Persists task and phase state to disk so teams can resume after restart.

The product-manager, architect, and scrum-master should assess the scope and decide which docs are needed. Don't create docs for the sake of process — create them when they add value.

### Team Structure

Spawn teammates using their agent definitions from `.claude/agents/`. The team lead should **assess the scope first** and spawn only the agents needed for this work item. Code reviewer and testing should always be involved regardless of scope.

**Full roster (spawn as needed):**

1. **product-manager** (agent type: `product-manager`)
   - First to start. Owns the entire requirements phase: Stakeholder interview, area/slug determination.
   - Writes BRIEF.md (always) and REQUIREMENTS.md (if needed) to `docs/agents/{area}/{work-item}/`
   - Once done, messages **team lead** (with area, work-item slug). If ux-expert is already spawned, also messages ux-expert with the requirements summary.

2. **ux-expert** (agent type: `ux-expert`)
   - Starts in Phase 1 (parallel with product-manager) to research existing UI patterns in `frontends/app/src/`
   - After Brief is ready, produces UX-DESIGN.md if UI changes are involved
   - Messages **team lead** when done (triggers Phase 2 HUMAN OWNER CHECKPOINT)

3. **architect** (agent type: `architect`)
   - Waits for product-manager and ux-expert to finish
   - **First action**: Read the area's AREA.md and scan existing work items in that area
   - Studies existing codebase, consults with **performance-engineer** on perf-sensitive design
   - Consults with **db-expert** if feature requires complex database work
   - Decides which optional docs are needed (ARCHITECTURE.md, API_SPEC.md, DATA_MODELS.md)
   - Writes docs to `docs/agents/{area}/{work-item}/`
   - Updates shared `docs/agents/TECH_DECISIONS.md` for ADRs
   - Messages scrum-master when architecture is complete

4. **db-expert** (agent type: `db-expert`)
   - OPTIONAL — only spawned when the architect determines the work needs database expertise
   - Consulted for: new table design, complex migrations, indexing, Citus distribution, query optimization
   - Does NOT write production code — provides expert advice

5. **performance-engineer** (agent type: `performance-engineer`)
   - Phase 3 only: Consulted by architect for performance review of the design
   - Shut down after Phase 3 — not involved in build or testing phases

6. **scrum-master** (agent type: `scrum-master`)
   - Waits for architect to finish
   - Breaks work into user stories and tasks (USER_STORIES.md if warranted)
   - Creates tasks in the shared team task list, assigns to devs + QA + tester
   - Prevents file conflicts, sets task dependencies

7. **frontend-dev-1** (agent type: `frontend-dev`)
   - Waits for scrum-master to create and assign tasks
   - Implements React features in `frontends/app/src/`
   - Makes atomic git commits per task: `frontend: <description>`
   - Coordinates with frontend-dev-2 to avoid file conflicts

8. **frontend-dev-2** (agent type: `frontend-dev`)
   - Same as frontend-dev-1, works on different files/components

9. **backend-dev-1** (agent type: `backend-dev`)
   - Waits for scrum-master to create and assign tasks
   - Implements Rails features in `app/`
   - Owns core/shared modules
   - Makes atomic git commits per task: `backend: <description>`

10. **backend-dev-2** (agent type: `backend-dev`)
    - Same as backend-dev-1, handles new isolated modules

11. **code-reviewer** (agent type: `code-reviewer`)
    - **Always involved** — reviews each completed developer task individually
    - Approves or requests changes before code moves to testing
    - Phase 6: Full-diff review of entire feature branch before PR

12. **tech-lead** (agent type: `tech-lead`)
    - Phase 4: Creates feature branch `{work-item}`
    - Phase 5: Runs compile gate (rubocop + rspec + eslint), starts app, monitors
    - Phase 5: Uses dev server for compile checks — faster than `npm run build`
    - Phase 6: **Starts servers** (backend:4000, frontend:3000, redis) before manual testing — this is tech-lead's responsibility
    - Phase 6: Seeds test data via `bin/rails runner` if manual-tester needs specific data
    - Phase 6: After manual testing passes, **MUST explicitly decide** on feature specs (yes + spawn backend-dev, or no + state reason). Silent omission is a process bug.
    - Phase 7: **Triggers documentator** — mandatory, never skip. Docs must be committed BEFORE PR creation.
    - Phase 8: Ask user if he wants to create PR from feature branch to master. If `gh pr create` fails (auth issues, etc.), do NOT troubleshoot — human owner will create the PR manually.

13. **qa-engineer** (agent type: `qa-engineer`)
    - Can start in parallel with developers (doesn't need running app)
    - Reads all docs, writes E2E test specs organized by user story
    - Outputs to `docs/agents/{area}/{work-item}/`: E2E_TEST_PLAN.md + tests/

14. **manual-tester** (agent type: `manual-tester`)
    - Waits for ALL dev tasks to be code-reviewed AND qa-engineer's test cases to be ready
    - Waits for **tech-lead** to confirm servers are running before starting
    - Uses **playwright-cli** skill with --headed flag to test story by story
    - **Must test through real browser** — never falls back to code review
    - Takes screenshots, files bug tasks with reproduction steps
    - Writes TEST_RESULTS.md
    - Knows to adjust date filters (default is last 30 days, test data may be older)

15. **documentator** (agent type: `documentator`)
    - Phase 7 — runs BEFORE PR creation so docs are included in the PR
    - Cleans up work item docs (removes transient PROGRESS.md, TEST_RESULTS.md, etc.)
    - Updates the area's AREA.md with new knowledge from this work item
    - Extracts reusable patterns to `docs/agents/patterns/` if applicable
    - Adds cross-references to other areas' AREA.md if work touched them

### Execution Flow

```
Phase 1 (Requirements + Research):  product-manager + ux-expert (parallel)
Phase 2 (UX Design):               ux-expert (if UI involved) → HUMAN OWNER CHECKPOINT
Phase 3 (Architecture):            architect + performance-engineer + db-expert (optional) → HUMAN OWNER CHECKPOINT
Phase 4 (Planning + Git):          scrum-master + tech-lead (feature branch)
Phase 5 (Build + Review):          devs + code-reviewer + qa-engineer + tech-lead
Phase 6 (Integration + Test + E2E): tech-lead starts servers → seeds data → manual-tester tests → ⚠️ MANDATORY feature specs
Phase 7 (Documentation):           ⚠️ MANDATORY — documentator cleans up + updates AREA.md + extracts patterns
Phase 8 (Ship):                    tech-lead creates PR after HUMAN OWNER CONFIRMATION (docs are already clean and included)
```

### Phase 5 Flow (Build + Review)

```
Developers complete tasks → atomic commits
       |
       v
Code-reviewer reviews each task individually
       |
       v
QA-engineer writes test cases organized by user story (parallel with devs)
```

### Phase 6 Flow (Integration + Test + E2E)

```
Tech-lead: starts servers (backend:4000, frontend:3000, redis)
       |
       v
Tech-lead: integration verification (compile gate, full stack restart)
       |
       v
Tech-lead: seeds test data if needed (bin/rails runner)
       |
       v
Tech-lead waits for:
  1. Code-reviewer: "ALL task reviews complete"
  2. QA-engineer: "test cases ready"
       |
       v
Tech-lead: messages team lead — "servers running, reviews done, test cases ready"
       |
       v
Team lead: spawns manual-tester with "all clear to test" message
       |
       v
Manual-tester tests using QA test cases (story by story, --headed browser)
       |
       +-- fail → bug task → developer fixes → code-reviewer reviews → manual-tester retests
       +-- pass ↓
       |
       v
⚠️ DECISION REQUIRED: Team lead decides if feature specs are needed
       |
       +-- YES (user-facing changes) → tech-lead triggers backend-dev to write feature specs
       |     +-- no backend-dev on team? → team lead spawns one on the fly
       |     +-- Backend-dev writes Capybara specs using debug_pause + playwright-cli
       |     +-- flaky after 3-5 attempts → skip with TODO, move on
       |     +-- pass → Phase 7 (Documentation)
       |
       +-- NO (perf task, refactor, config, cosmetic) → team lead states reason, proceeds to Phase 7 (Documentation)
       |
       +-- ⚠️ Silent omission is a process bug — team lead MUST explicitly announce the decision
```

### Git Strategy

- **Feature branch**: `{work-item}` created at Phase 4 by tech-lead (e.g., `add-order-line-tool` or `fix-widget-loading`)
- **Atomic commits**: Each completed task = one commit with descriptive message
- **Commit format**: `<scope>: <description>` (e.g., `backend: add trade replay service`, `frontend: add replay layout component`)
- **No Co-Authored-By**: Do not add Co-Authored-By lines to git commits
- **PR**: Created at Phase 8 by tech-lead after human owner confirmation

### Progress Tracking

For medium+ work items, the scrum-master creates PROGRESS.md at `docs/agents/{area}/{work-item}/PROGRESS.md`. For small work items, skip it — the shared TaskList is sufficient.

**PROGRESS.md template:**

```markdown
# Progress: {work-item}

## Current Phase
Phase 1 — Requirements + Research

## Phase Status

| Phase | Status | Agent(s) |
|-------|--------|----------|
| Phase 1: Requirements + Research | In Progress | product-manager, ux-expert |
| Phase 2: UX Design | Pending | ux-expert |
| Phase 3: Architecture | Pending | architect |
| Phase 4: Planning + Git | Pending | scrum-master, tech-lead |
| Phase 5: Build + Review | Pending | devs, code-reviewer, qa-engineer |
| Phase 6: Integration + Test | Pending | tech-lead, manual-tester |
| Phase 7: Documentation | Pending | documentator |
| Phase 8: Ship | Pending | tech-lead |

## Artifacts

| Document | Status | Author |
|----------|--------|--------|
| BRIEF.md | Pending | product-manager |
| UX-DESIGN.md | — | ux-expert |
| ARCHITECTURE.md | — | architect |
| E2E_TEST_PLAN.md | — | qa-engineer |
| TEST_RESULTS.md | — | manual-tester |

## Development Tasks
<!-- scrum-master populates after Phase 4 -->

## Code Reviews
<!-- code-reviewer updates -->

## Testing
<!-- manual-tester updates -->

## Bugs
<!-- manual-tester / tech-lead add bugs here -->

## Timeline
<!-- all agents append entries: [timestamp] agent: action -->
```

Use `—` in Status for optional artifacts that weren't created. Update Status to `In Progress`, `Done`, or `Skipped` as work progresses. Every agent appends to the Timeline section when completing a milestone.

### Key Rules

- **Dynamic areas**: Architect creates new areas as needed — no fixed list
- **AREA.md first**: Architect ALWAYS reads the area's AREA.md before designing
- **Only BRIEF.md is mandatory**: All other docs created only when they add value
- **Feature branches**: `{work-item}` (e.g., `add-replay-tools` or `fix-loading`)
- **Branch awareness**: All agents MUST verify they're on the feature branch before committing (`git branch --show-current`). QA engineer and devs are especially prone to committing on the wrong branch.
- **Explicit branch in spawn messages**: When spawning agents, always include the exact feature branch name in the initial message so they know where to commit.
- **Atomic commits**: One commit per completed task, format: `<scope>: <description>`
- **No Co-Authored-By**: Never add Co-Authored-By lines to commits
- **Task tracking**: Developers MUST mark tasks as `done` via TaskUpdate and message the team lead with the status update
- **Checkpoint ownership**: Only the **team lead** updates `docs/agents/{area}/{work-item}/CHECKPOINT.md`. The scrum-master creates it; the team lead maintains it based on status messages from agents. Individual agents do NOT edit CHECKPOINT.md — this prevents concurrent edit conflicts.
- **Code review gate**: All dev tasks must be code-reviewed before manual testing begins
- **Tests always involved**: Code reviewer and testing agents are never skipped, regardless of scope
- **Browser testing is mandatory**: Manual-tester must test through a real browser with playwright-cli — code review is NOT an acceptable substitute. Browser testing catches bugs that code review cannot (CSS issues, container IDs, layout collapse, etc.)
- **Quality gates**: Require human owner approval after UX design (Phase 2) and architecture (Phase 3)
- **Communication**: Teammates message each other directly — don't relay through the lead
- **No shortcuts**: Developers must read specs before coding, tester must read test cases before testing
- **Right-size the team**: Team lead assesses scope and spawns only needed agents. Don't spawn 15 agents for a bug fix.
- **Feature specs require explicit decision**: After manual testing passes, the team lead MUST decide whether feature specs are needed and announce the decision. Feature specs are expected for any work that adds or changes user-facing behavior (UI features, new indicators, new pages, changed workflows). They can be skipped WITH STATED REASON for: performance tasks, backend-only refactors, config changes, or purely cosmetic fixes. The team lead must say "Feature specs: yes, spawning backend-dev" or "Feature specs: skipped — [reason]". Silent omission is a bug in the process.
- **On-demand backend-dev for feature specs**: For FE-only tasks where no backend-dev was spawned, the tech-lead will request the team lead to spawn a backend-dev specifically for writing feature specs in Phase 6. Spawn it, let it write + get reviewed, then shut it down.
- **Phase 7 (Documentation) is MANDATORY**: The documentator must always run BEFORE PR creation (Phase 8). Never skip it — it maintains AREA.md knowledge and extracts reusable patterns. Docs commits must be in the PR, not after it. The team lead must verify this happens.
- **Shut down idle agents**: Shut down agents immediately after their phase completes. Don't let them sit idle consuming context. Respawn when needed for later phases. Exception: tech-lead stays active phases 4-8.
- **Dev server for compile checks**: Use the running dev server (port 3000) for fast incremental compile checks instead of full `npm run build`. Only run full build as the final gate before PR (Phase 7).
- **Server management**: Tech-lead is responsible for starting servers (backend:4000, frontend:3000, redis) before manual testing. Manual-tester should NOT have to start servers.
- **Test data awareness**: GridBot defaults to last 30 days. Test data may be older (e.g., OPTIONS trades from 2020-2021). Manual-tester should adjust date filters. Tech-lead should query for specific trade data via `bin/rails runner` when needed.
- **HANDOFF.md**: Any agent can optionally append notes to `docs/agents/{area}/{work-item}/HANDOFF.md` for the documentator — gotchas discovered, patterns worth extracting, things that should be in AREA.md. Only write when you have something genuinely valuable. Documentator reads it, extracts value, deletes the file.

### Model Preferences

- product-manager, ux-expert, scrum-master, qa-engineer, documentator: use **Sonnet**
- architect, frontend-dev-1, frontend-dev-2, backend-dev-1, backend-dev-2, tech-lead: use **Opus**
- code-reviewer: use **Opus**
- performance-engineer: use **Opus**
- manual-tester: use **Sonnet**
- db-expert: use **Sonnet**

### Agent Execution

**⚠️ EVERY agent spawn MUST include `mode: "bypassPermissions"`** — without it, agents will prompt for file write permissions and block. No exceptions. If you forget this parameter, the agent cannot work autonomously. This is the #1 cause of agents getting stuck.

**Architect approval flow**: The architect writes docs directly (ARCHITECTURE.md, API_SPEC.md, etc.) and then messages you that architecture is ready for review. Handle it as follows:
1. Read the architect's docs to understand the technical design
2. Ask the **human owner** for approval (this is the Phase 3 HUMAN OWNER CHECKPOINT)
3. If approved → message the architect that it's approved, then proceed to Wave 2
4. If rejected → message the architect with feedback to revise

**Startup sequence:**
1. **Spawn product-manager immediately** with `$ARGUMENTS`. The PM owns the entire requirements phase — stakeholder interview, BRIEF.md. Do NOT gather requirements yourself.
2. Optionally spawn **ux-expert** in parallel if UI changes are likely (let it start researching existing patterns while PM interviews).
3. **Wait for PM to finish** — PM will message you with the area, work-item slug, and confirm BRIEF.md is written.
4. Once PM is done, use the PM's output to:
   - Confirm the area and work-item slug
   - **Check for existing CHECKPOINT.md** at `docs/agents/{area}/{work-item}/CHECKPOINT.md`:
     - **If found**: Read it. Determine current phase and which tasks are done/in-progress/pending. Resume from that point — skip completed phases and only spawn agents needed for remaining work. Tell spawned agents to read CHECKPOINT.md before starting.
     - **If not found**: Fresh start — proceed normally.
   - Assess scope and decide which agents to spawn (code-reviewer and testing always included)
5. **If ux-expert was spawned**, wait for it to complete UX-DESIGN.md. Present the UX design to the human owner for approval (Phase 2 HUMAN OWNER CHECKPOINT). Only proceed to Wave 1 after approval (or if ux-expert was not spawned, skip this step).
6. Spawn agents in waves (not all at once) — each wave waits for the previous one to finish:
   - **Wave 1**: architect (+ performance-engineer, db-expert if needed) → wait for architecture
   - **Wave 2**: scrum-master + tech-lead → wait for task breakdown + feature branch
   - **Wave 3**: devs + code-reviewer + qa-engineer → build phase
   - **Wave 4**: manual-tester → after tech-lead confirms: servers running + all reviews done + test cases ready
   - **Wave 5**: documentator → after testing passes
   - Pass `{work-item}` to the tech-lead so it creates the correct branch name.
   - Shut down agents after their phase completes — don't keep idle agents running.

### Retest Mode

If `$ARGUMENTS` starts with `--retest`, enter retest mode instead of the full workflow:

1. **Parse arguments**: Extract the area and work-item slug (e.g., `--retest dashboard/add-calendar`)
2. **Skip Phases 1-4 entirely** — do NOT spawn product-manager, ux-expert, architect, scrum-master, frontend-dev-2, backend-dev-2, qa-engineer, or documentator
3. **Read existing context**:
   - Test cases from `docs/agents/{area}/{work-item}/tests/`
   - Feature docs from `docs/agents/{area}/{work-item}/`
   - CHECKPOINT.md if it exists
4. **Stay on the current branch** — do NOT check out any feature branch. Retest verifies the feature works in the current codebase.
5. **Spawn these agents in parallel** (all with `mode: "bypassPermissions"`):

| Name | Agent Type | Retest Role | When |
|------|-----------|-------------|------|
| tech-lead | `tech-lead` | Starts servers, compile gate, verifies app runs, seeds test data | Immediately |
| manual-tester | `manual-tester` | Tests ALL scenarios from existing test cases | Immediately |
| code-reviewer | `code-reviewer` | Reviews any fixes made during retest | Only if fixes needed (Phase R5) |
| frontend-dev-1 | `frontend-dev` | Fixes UI bugs | Only if fixes needed (Phase R5) |
| backend-dev-1 | `backend-dev` | Fixes API/DB bugs | Only if fixes needed (Phase R5) |

**Retest phases:**

```
Phase R1: Spawn tech-lead + manual-tester in parallel
          Tech-lead starts servers (backend:4000, frontend:3000, redis)
          Tech-lead runs compile gate on CURRENT branch (no branch checkout)
              |
              v
Phase R2: Manual-tester tests ALL scenarios from existing test cases
          Developers stand by (no code changes yet)
              |
              v
          All tests pass? → Done (retest confirms feature works on current codebase)
          Bugs found? → Phase R3
              |
              v
Phase R3: Team lead reports bugs to HUMAN OWNER and asks:
          "These bugs were found. Should we fix them?"
              |
              +-- NO → Done (retest complete, bugs documented)
              +-- YES ↓
              |
              v
Phase R4: Team lead creates a NEW branch from current branch:
          `retest-{work-item}` (or human owner provides a name)
              |
              v
Phase R5 (loop): developer fixes → code-reviewer reviews
                 → manual-tester retests → repeat until all bugs fixed
              |
              v
Phase R6: Proceed to Phase 7 (documentator) + Phase 8 (PR) — normal ship flow
```

**Retest rules:**
- **Stay on current branch** — retest verifies the feature works in the current codebase (e.g., master), NOT on the old feature branch
- No new docs are created — retest uses existing BRIEF.md, test cases, etc.
- **No code changes unless human owner approves** — retest is verification first
- If fixes are needed, create a NEW branch from the current branch (don't check out old feature branches)
- Update CHECKPOINT.md at the end with retest results
- If no fixes needed, skip Phase 7 (documentator) and Phase 8 (PR) — retest is verification only
- If fixes were made, Phase 7 + Phase 8 run as normal to ship the fix

The work to do: $ARGUMENTS
