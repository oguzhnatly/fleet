# Solo Empire Pattern

**One brain, many hands.** The most common pattern for solo builders.

```
┌──────────────────────────────┐
│     Coordinator (Opus)       │
│  Strategic decisions, plans  │
├──────────────┬───────────────┤
│    Coder     │   Reviewer    │
│  (Codex)     │   (Codex)     │
│  Write code  │  Review PRs   │
└──────────────┴───────────────┘
```

## How It Works

1. **Coordinator** receives tasks (via heartbeat, cron, or direct message)
2. Coordinator delegates implementation to **Coder**
3. Coder pushes code and reports back
4. Coordinator sends to **Reviewer** for validation
5. After review passes, Coordinator merges/deploys

## When to Use

- You're a solo founder or indie hacker
- You have 1-5 products to manage
- You want autonomous overnight work
- Budget for 2-3 AI subscriptions

## Setup

```bash
cp config.json ~/.fleet/config.json
# Edit with your ports, tokens, and repos
fleet init
fleet health
```
