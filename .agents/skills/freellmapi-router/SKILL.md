name: freellmapi-router
description: >-
  Route tasks between free LLM providers (freellmapi) and frontier models (Claude Opus)
  with selective, per-session routing that does not affect existing Claude traffic.
user-invocable: false
metadata:
  internal: true

# Freellmapi Selective Router

## Problem Statement

The dotfiles branch `fm/firstmate-haiku-router` routes ALL Claude Code traffic through freellmapi
by setting `ANTHROPIC_BASE_URL` to the freellmapi gateway. This is not desired - we need
**selective routing** where only simple tasks use the free aggregator, while complex tasks
still use Claude Opus directly.

## Solution: Selective Routing

Instead of globally switching `ANTHROPIC_BASE_URL`, we implement routing decisions at
the dispatch level:

1. **Task complexity classification** → routing decision
2. **Per-task routing** → no global config change
3. **Session opt-in** → `FRELLMAPI_ROUTING=enabled` environment variable

## Usage

### Enable Selective Routing (Per Session)

```bash
export FRELLMAPI_ROUTING=enabled
export FRELLMAPI_URL=http://localhost:3001
```

### Per-Command Override

```bash
freellmapi-router recommend --effort low --cost-optimize
freellmapi-router recommend --effort medium --tokens 5000 --json
```

### Read Config from Dotfiles Branch (Read-Only)

```bash
freellmapi-router read-config --dotfiles /path/to/dotfiles --branch fm/some-branch
```

## Routing Logic

| Effort      | FRELLMAPI_ROUTING | Route        | Model | Cost    |
|-------------|-------------------|--------------|-------|---------|
| low         | enabled           | freellmapi   | haiku | $0      |
| low         | disabled/missing  | claude       | opus  | tracked |
| medium      | enabled           | freellmapi   | auto  | $0      |
| medium      | disabled/missing  | claude       | opus  | tracked |
| high+       | any               | claude       | opus  | tracked |

## Integration with Firstmate Dispatch

Use in crew-dispatch.json rules:

```json
{
  "rules": [
    {
      "when": "Trivial mechanical edit or simple query",
      "use": {
        "harness": "freellmapi",
        "model": "haiku",
        "effort": "low"
      },
      "why": "Zero-cost routing for simple tasks (requires FRELLMAPI_ROUTING=enabled)"
    },
    {
      "when": "Multi-file feature or complex reasoning required",
      "use": {
        "harness": "claude",
        "model": "opus",
        "effort": "high"
      },
      "why": "Frontier model for complex work"
    }
  ],
  "default": [
    { "harness": "claude", "model": "opus", "effort": "medium" }
  ]
}
```

## Cost Tracking

Enable cost logging with `FRELLMAPI_COST_LOG=enabled`. Creates: `data/freellmapi-router/costs.log`

Format:
```
timestamp,effort,route,tokens,in_tokens,out_tokens,cost_usd,notes
```

## Files

- `.agents/skills/freellmapi-router/bin/freellmapi-router` - Main router script
- `.agents/skills/freellmapi-router/lib/freellmapi-dispatch.mjs` - JavaScript integration library
- `data/freellmapi-router/config.json` - Routing configuration
- `data/freellmapi-router/costs.log` - Cost tracking (created on demand)

## Implementation Status

- [x] Configuration discovery from dotfiles (read-only git show)
- [x] Task complexity classifier
- [x] Routing decision engine
- [x] TOON format output for easy parsing
- [x] JSON format output for dispatch pipeline integration
- [x] Selective routing without global config change
- [x] Per-session opt-in via FRELLMAPI_ROUTING=enabled
- [ ] Live testing with actual freellmapi instance
- [ ] Integration with Firstmate dispatch pipeline