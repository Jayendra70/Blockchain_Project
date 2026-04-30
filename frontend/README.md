# Frontend Dashboard

This frontend is the interactive control surface for the eclipse-attack simulation.

## Responsibilities

- Connect to the local Anvil RPC node.
- Read deployment data from `src/config.json`.
- Compare the vulnerable oracle and the advanced oracle side by side.
- Trigger commit, reveal, timeout, slashing, and reset actions.
- Render a live activity feed from contract events.

## Commands

```bash
npm install
npm run dev
npm run build
npm run lint
```

## Notes

- The dashboard expects a local RPC endpoint at `http://127.0.0.1:8545` unless `src/config.json` is regenerated with a different value.
- `src/config.json` and the ABI JSON files are refreshed by `../scripts/deploy_frontend.sh`.
