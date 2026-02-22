# Vonage Unofficial Skill

SMS and voice conversations with your agent via Vonage APIs. A single Express server handles both text messages (Messages API) and phone calls (Voice API), bridged to OpenClaw's chat completions endpoint.

```
SMS  → Vonage → Express webhook server → OpenClaw gateway → Agent
Call → Vonage → Express webhook server → OpenClaw gateway → Agent
```

## Setup

See [SKILL.md](SKILL.md) for full setup instructions, configuration, tuning, and troubleshooting.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Detailed setup, configuration, and troubleshooting guide |
| `scripts/setup.sh` | Scaffolds the webhook server project |
| `references/vonage-messages-api.md` | Vonage Messages API reference |
| `references/vonage-ncco.md` | Vonage NCCO action reference |
