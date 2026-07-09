# Slice 17 — StoreKit monetization

| Field | Value |
|-------|-------|
| **ID** | 17 |
| **Title** | StoreKit monetization |
| **Status** | Draft — **blocked on user decision** |
| **Crux** | StoreKit 2 purchases gate cleaning features per the chosen monetization model, verified against a `.storekit` test configuration. |

## ⚠️ Halt-and-ask gate (before any work)

PRD §11 leaves the **monetization model open** (subscription vs one-time vs freemium). The coordinator MUST halt at slice start and get the user's decision on: model, price points, and which features are gated (all cleaning? unrelated-content only?). **No agent may assume a model.** Record the decision in the PRD and an ADR before PM finalizes ACs.

## PRD / spec references

- PRD §1, §9 — Monetization expected; StoreKit 2, on-device verification
- PRD §11 — Open decision: monetization model

## Goal

Purchases and entitlement gating, ready for TestFlight.

## Deliverables

- `.storekit` configuration file with the decided products
- StoreKit 2 purchase + transaction verification; entitlement store
- Paywall screen; feature gating on entitlements
- `StoreKitTests` (using `StoreKitTest` framework), `PaywallUITests`

## Depends on

- Slice 13 (settings/features to gate); user decision above

**Parallelizable:** Yes — with Slices 15, 16 once unblocked.

## Out-of-scope

- TestFlight upload / App Store review (ship milestones, not slice gates)
- RevenueCat integration

## Acceptance criteria (finalize after decision)

- [ ] 1. Unit test: purchase in the `.storekit` test environment produces a verified transaction and sets the entitlement.
- [ ] 2. Unit test: gated feature calls are refused without entitlement and allowed with it.
- [ ] 3. UI test: paywall lists products from the test configuration; stub purchase completes and dismisses.
- [ ] 4. Unit test: entitlement revocation (refund in test environment) re-gates features.
- [ ] 5. Full suite green via `scripts/verify.sh`.

## Verification mapping

| AC# | Test file | Test method | Notes |
|-----|-----------|-------------|-------|
| 1 | `PodWash/PodWashTests/StoreKitTests.swift` | `testPurchaseSetsEntitlement` | TBD |
| 2 | `PodWash/PodWashTests/StoreKitTests.swift` | `testFeatureGating` | TBD |
| 3 | `PodWash/PodWashUITests/PaywallUITests.swift` | `testPaywallPurchaseFlow` | TBD |
| 4 | `PodWash/PodWashTests/StoreKitTests.swift` | `testRevocationRegates` | TBD |
| 5 | — | — | Command-level |

## Verification commands

```bash
scripts/verify.sh -only-testing:PodWashTests/StoreKitTests -only-testing:PodWashUITests/PaywallUITests
scripts/verify.sh    # Done gate
```

## Verification record (QA fills at Verify)

```
VERIFY RESULT: (pending)
```

## Done gate

- [ ] Monetization decision recorded in PRD §11 + ADR (user-approved)
- [ ] Every AC mapped to a test; all rows filled
- [ ] **Full suite green:** unfiltered `scripts/verify.sh` exit 0, failed 0, skipped 0
- [ ] Verification record pasted above
- [ ] Auto-commit on green: `slice-17: <short description>`

## Role artifacts

| Role | Gate | Artifact path |
|------|------|---------------|
| Architect | Required | entitlement-store design note |
| UX | Required | `docs/slices/slice-17-ux.md` (paywall) |
