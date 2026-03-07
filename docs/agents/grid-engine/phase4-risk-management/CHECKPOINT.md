# Checkpoint: phase4-risk-management

Area: grid-engine
Branch: phase4-risk-management
Last Updated: 2026-03-07 00:00

## Phase: 1 — Task breakdown complete, implementation pending

## Artifacts

| Document | Status | Author |
|----------|--------|--------|
| BRIEF.md | done | product-manager |
| ARCHITECTURE.md | done | architect |
| USER_STORIES.md | skipped (tasks created directly) | scrum-master |
| CHECKPOINT.md | done | scrum-master |

## Tasks

| ID | Task | Owner | Status | Review | Commit |
|----|------|-------|--------|--------|--------|
| T2 | [P4-T01] Rate limiter: force: param + >80% monitoring | backend-dev-2 | pending | — | — |
| T3 | [P4-T02] RestClient: emergency: param | backend-dev-2 | pending | — | — |
| T4 | [P4-T03] Grid::RiskManager | backend-dev-2 | pending | — | — |
| T5 | [P4-T04] Bot model validations (SL/TP) | backend-dev-1 | pending | — | — |
| T6 | [P4-T05] BotsController: risk params + JSON | backend-dev-1 | pending | — | — |
| T7 | [P4-T06] OrderFillWorker: risk check hook | backend-dev-2 | pending | — | — |
| T8 | [P4-T07] BalanceSnapshotWorker: risk + DCP health | backend-dev-2 | pending | — | — |
| T9 | [P4-T08] Grid::TrailingManager | backend-dev-1 | pending | — | — |
| T10 | [P4-T09] OrderFillWorker: trailing hook | backend-dev-1 | pending | — | — |
| T11 | [P4-T10] Grid::Initializer: register DCP | backend-dev-1 | pending | — | — |
| T12 | [P4-T11] WebSocket listener: DCP + ticker | backend-dev-2 | pending | — | — |
| T13 | [P4-T12] Frontend: types + wizard risk fields | frontend-dev-1 | pending | — | — |
| T14 | [P4-T13] Frontend: RiskSettingsCard | frontend-dev-2 | pending | — | — |
| T15 | [P4-T14] Production: systemd + Procfile.dev | backend-dev-2 | pending | — | — |
| T16 | [P4-QA] RSpec test cases | qa-engineer | pending | — | — |

## Dependency Graph

```
T2 (RateLimiter force:) → T3 (RestClient emergency:) → T4 (RiskManager)
                                                              ↓
T5 (Bot validations) → T6 (BotsController)         T7 (OFW risk hook)
                            ↓                       T8 (BSW risk+DCP)
                       T13 (FE wizard) → T14       T12 (WS listener)

T9 (TrailingManager) → T10 (OFW trailing hook) ↘
T11 (Initializer DCP) ─────────────────────────→ [all BE done]

T15 (systemd) — independent

T16 (QA) — blocked by T2, T4, T5, T9
```

## Parallel tracks at kickoff

- **backend-dev-2**: T2 → T3 → T4 → T7 → T8 → T12
- **backend-dev-1**: T5 → T6, T9 → T10, T11, T15 (independent)
- **frontend-dev-1**: T13 (after T6)
- **frontend-dev-2**: T14 (after T13)
- **qa-engineer**: T16 (after T2, T4, T5, T9)

## Blockers

- (none)
