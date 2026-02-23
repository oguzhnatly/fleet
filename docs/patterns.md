# Fleet Patterns

Architecture patterns for organizing your AI agent fleet.

## Solo Empire

The simplest and most common pattern. One coordinator makes all decisions, 1-5 employees execute.

**Best for:** Indie hackers, solo founders, personal automation.

```
         Coordinator
        /     |     \
    Coder  Reviewer  Deployer
```

**Key insight:** Use the strongest model (Opus) for strategic decisions, cheapest model (Codex) for execution. This maximizes quality while controlling cost.

## Development Team

Team leads coordinate specialized developers. The orchestrator only talks to leads, never directly to individual developers.

**Best for:** Complex products, multiple services, large codebases.

```
              Orchestrator
            /      |       \
      FE Lead   BE Lead   QA Lead
       / \        |         |
    Dev1  Dev2   Dev1    Tester
```

**Key insight:** Model hierarchy matters. Leads should be Sonnet-class (good at architecture and review), developers should be Codex-class (fast at implementation).

## Research Lab

Specialized agents for knowledge work: scraping, analysis, writing, and verification.

**Best for:** Content operations, market research, competitive intelligence.

```
            Director
          /    |    \     \
    Scraper  Analyst Writer  Fact-Check
```

**Key insight:** Verification agents (fact-checkers) are essential. Without them, the system generates confident but potentially incorrect content.

## Task Force

Temporary teams assembled for specific projects, then disbanded. The coordinator spawns agents as needed rather than maintaining a standing fleet.

**Best for:** Variable workloads, cost optimization, projects with distinct phases.

```
    Coordinator
         |
    [spawns on demand]
    /     |      \
  Agent  Agent  Agent
  (dies) (dies) (dies)
```

**Key insight:** This is the most cost-effective pattern. You only pay for agents when they're working. Requires good task decomposition by the coordinator.

## Choosing a Pattern

| Factor | Solo Empire | Dev Team | Research Lab | Task Force |
|--------|------------|----------|--------------|------------|
| Complexity | Low | High | Medium | Medium |
| Cost | Low | High | Medium | Variable |
| Always-on agents | 2-5 | 5-15 | 3-6 | 0-1 |
| Best model mix | Opus+Codex | Opus+Sonnet+Codex | Opus+Sonnet+Codex | Opus+Codex |
| Setup time | 5 min | 30 min | 15 min | 10 min |

## Scaling

Every pattern can be scaled by:

1. **Adding more agents** — More employees under existing leads
2. **Adding more tiers** — Sub-leads or specialized coordinators
3. **Adding cross-cutting agents** — Monitoring, compliance, documentation
4. **Hybrid patterns** — Solo empire for products, research lab for content
