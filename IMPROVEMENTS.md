# Improvements

## Completed In This Pass

- Standardized the advanced oracle quorum to `3 of 5`.
- Added validation for invalid constructor inputs in `AdvancedSecureOracle`.
- Added `getActiveNodeCount()` and `getRoundState()` so the frontend can consume protocol state more cleanly.
- Added a `PhaseTransition` event for better protocol visibility.
- Hardened the deployment script and added useful root package scripts.
- Removed unrelated Counter scaffold files from the Foundry starter template.

## High-Priority Follow-Ups

- Add a recovery path for challenged nodes that successfully appeal.
- Move token logic to OpenZeppelin contracts if security hardening becomes a goal.
- Add contract-level events for commit-timeout and reveal-timeout outcomes.
- Add smoke tests for the deployment script and generated frontend config.

## Validation Checklist

- Run `forge test` after Foundry is installed.
- Run `npm run frontend:build` from the repo root.
- Start `anvil`, run `npm run deploy:local`, then `npm run frontend:dev`.
