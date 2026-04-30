# Development Team Pattern

**Team leads managing specialized developers.** For complex products or multiple teams.

```
┌─────────────────────────────────────────────┐
│            Orchestrator (strategic)               │
│     Strategic planning, cross-team sync      │
├───────────────┬──────────────┬──────────────┤
│  FE Lead      │  BE Lead     │  QA Lead     │
│  (review)     │  (review)    │  (review)    │
│  Architecture │  API design  │  Test plans  │
├───────┬───────┼──────────────┼──────────────┤
│ Dev 1 │ Dev 2 │    Dev 1     │   Tester     │
│(coding)│(coding)│   (coding)    │  (coding)     │
└───────┴───────┴──────────────┴──────────────┘
```

## How It Works

1. **Orchestrator** breaks projects into team-level tasks
2. **Team Leads** (review) decompose tasks and coordinate their teams
3. **Developers** (coding) implement features
4. **QA** validates across the full stack
5. Leads report status back to Orchestrator

## When to Use

- You're building a complex product with multiple services
- You need different expertise levels (architecture vs implementation)
- You want automated code review at the team level
- Budget for 5-10 AI subscriptions

## Key Concept: Model Hierarchy

Use stronger models for decisions, cheaper models for execution:
- **Orchestrator**: strategic model (strategic, expensive but precise)
- **Team Leads**: review model (architectural decisions, reviews)
- **Developers**: coding model (fast implementation, high throughput)
