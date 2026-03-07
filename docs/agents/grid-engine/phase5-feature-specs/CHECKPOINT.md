# Checkpoint: phase5-feature-specs

Area: grid-engine
Branch: phase5-feature-specs
Last Updated: 2026-03-07 01:00

## Phase: 1 — Infrastructure + Spec Authoring

## Artifacts

| Document | Status | Author |
|----------|--------|--------|
| BRIEF.md | done | product-manager |
| ARCHITECTURE.md | done | architect |
| USER_STORIES.md | n/a | scrum-master (small phase — tasks created directly) |
| E2E_TEST_PLAN.md | done | qa-engineer |

## Tasks

| ID | Story | Task | Owner | Status | Review | Commit |
|----|-------|------|-------|--------|--------|--------|
| T1 | US01 | Gems + Capybara config | backend-dev-1 | pending | — | — |
| T2 | US01 | Database strategy — DatabaseCleaner + WebMock adjustment | backend-dev-1 | pending | — | — |
| T3 | US01 | Vite build integration — vite_assets.rb, SPA middleware, Rails test env | backend-dev-1 | pending | — | — |
| T4 | US01 | Shared feature helpers — exchange stubs, bot helpers, cable helpers, navigation helpers | backend-dev-1 | pending | — | — |
| T5 | US02 | Vite config — set assetsDir and React Query test mode (VITE_TEST_MODE) | frontend-dev-1 | pending | — | — |
| T6 | US02 | React data-testid attributes — all components listed in ARCHITECTURE.md 12.3 | frontend-dev-1 | pending | — | — |
| T7 | US03 | Dashboard feature spec — 3 scenarios | backend-dev-1 | pending | — | — |
| T8 | US03 | Create Bot Wizard feature spec — 4 scenarios | backend-dev-1 | pending | — | — |
| T9 | US03 | Bot Detail feature spec — 6 scenarios | backend-dev-1 | pending | — | — |
| T10 | US04 | Full regression — verify all 504 + new feature specs pass | backend-dev-1 | pending | — | — |
| T11 | QA | Write test cases for Phase 5 feature specs | qa-engineer | done | — | — |

## Dependencies

```
T1 → T2 → T3 → T4 → T7, T8, T9 → T10
T5 → T6 → T7, T8, T9
T11 (independent, can run in parallel with T1–T6)
```

## File Ownership

| Owner | Files |
|-------|-------|
| backend-dev-1 | `Gemfile`, `config/environments/test.rb`, `spec/support/capybara.rb`, `spec/support/database_cleaner.rb`, `spec/support/webmock.rb`, `spec/support/features/*.rb`, `spec/features/*.rb` |
| frontend-dev-1 | `frontends/app/vite.config.ts`, `frontends/app/src/**` |

## Blockers

- (none)
