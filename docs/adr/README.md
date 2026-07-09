# Architecture Decision Records

Durable technical decisions for PodWash. One markdown file per decision, numbered
`NNN-short-title.md`. ADRs are written by the Architect role **before**
implementation on slices that add modules or change shared APIs, and are referenced
from the relevant slice file's Role artifacts table.

| Rule | Detail |
|------|--------|
| **Format** | Context → Decision → Consequences (keep it short; a page is plenty) |
| **Status** | `Accepted`, `Superseded by NNN`, or `Deferred` in the header |
| **Change** | Never rewrite an accepted ADR's decision — write a new ADR that supersedes it |
| **Scope** | Cross-slice technical decisions only; slice-local layout goes inline in the slice file |

## Index

| # | Title | Status |
|---|-------|--------|
| [000](000-foundations.md) | Foundations: playback, verification, transcript schema, iOS floor | Accepted |
