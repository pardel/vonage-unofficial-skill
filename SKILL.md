---
name: vonage-unofficial
description: >
  Set up SMS and voice conversations with the agent via Vonage APIs. Handles
  both text messages (Messages API) and phone calls (Voice API) through a
  single webhook server bridged to OpenClaw's chat completions endpoint. Use
  when the user wants to text or call the agent, set up a Vonage number,
  configure webhooks, or troubleshoot SMS/voice issues.
---

# Vonage Unofficial

Combined SMS + Voice conversational interface using Vonage Messages API and Voice API.

## Architecture

```
SMS  → Vonage → Express webhook server (POST /webhooks/inbound)
                 ├── Text → OpenClaw chat API → response
                 └── Response → Vonage Messages API → SMS reply

Call → Vonage → Express webhook server
                 ├── /webhooks/answer  → greeting + listen for speech
                 ├── /webhooks/speech  → transcript → OpenClaw → TTS reply → listen again
                 └── /webhooks/event   → call lifecycle tracking
```

SMS uses JWT auth (application ID + private key). Voice uses NCCO actions; Vonage handles STT and TTS. Both channels bridge to OpenClaw's `/v1/chat/completions` HTTP endpoint.

## Setup Steps

### 1. Vonage Account & Application

1. Create a [Vonage account](https://dashboard.vonage.com)
2. Create a Vonage Application — enable both **Messages** and **Voice** capabilities
3. Rent a Voice/SMS-enabled number and link it to the application
4. In Dashboard → Settings → **set Default SMS Setting to "Messages API"**

### 2. OpenClaw Gateway

Enable the chat completions endpoint:

```json
{ "gateway": { "http": { "endpoints": { "chatCompletions": { "enabled": true } } } } }
```

### 3. Deploy the Server

Run the setup script:

```bash
scripts/setup.sh ~/code/vonage
```

Then configure `~/code/vonage/.env`:

```
VONAGE_APP_ID=<your application id>
VONAGE_PRIVATE_KEY_PATH=./private.key
VONAGE_NUMBER=<your vonage number, no + prefix>
PUBLIC_URL=http://<your-public-ip>:3000
PORT=3000
OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789
OPENCLAW_GATEWAY_TOKEN=<your gateway token>
```

Place your Vonage private key at `~/code/vonage/private.key`.

### 4. Configure Vonage Webhooks

In the Vonage Dashboard → Application:

**Messages capability:**
- **Inbound URL:** `<PUBLIC_URL>/webhooks/inbound`
- **Status URL:** `<PUBLIC_URL>/webhooks/status`

**Voice capability:**
- **Answer URL:** `<PUBLIC_URL>/webhooks/answer` (POST)
- **Event URL:** `<PUBLIC_URL>/webhooks/event` (POST)

### 5. Firewall

```bash
sudo ufw allow 3000/tcp
```

### 6. Start

```bash
cd ~/code/vonage && node server.js
```

Health check: `curl http://localhost:3000/health`

## Sending a Proactive SMS

The server includes a `/send` endpoint for outbound messages:

```bash
curl -X POST http://localhost:3000/send \
  -H 'Content-Type: application/json' \
  -d '{"to": "<recipient_number>", "text": "Hey from OpenClaw!"}'
```

## Conversation State

- **SMS**: Keyed by phone number, 2-hour inactivity TTL
- **Voice**: Keyed by `conversation_uuid`, 1-hour inactivity TTL
- Both are in-memory; a cleanup interval runs every 10 minutes

## Tuning Speech Recognition

Edit `listenAction()` in `server.js`:

- `endOnSilence` (default 2s): Seconds of silence before ending capture. Lower = faster but may cut off pauses.
- `startTimeout` (default 20s): How long to wait for speech to begin before timing out.
- `maxDuration` (default 60s): Maximum seconds of speech per turn.
- `language`: BCP-47 code, default `en-GB`. Change to match caller's language.

## Troubleshooting

### SMS
- **No inbound messages**: Check that "Default SMS Setting" is set to "Messages API" (not SMS API) in Dashboard → Settings
- **Number not receiving**: Ensure the number is linked to the application with Messages capability
- **Auth errors on send**: Verify private key matches the application
- **Webhook not reached**: Check firewall and that the inbound URL is correct

### Voice
- **No webhook hits**: Check firewall, verify Vonage webhook URLs match your public IP and port
- **Call connects but no greeting**: Vonage may use GET for answer URL — the server handles both
- **Speech not recognised**: Check logs for timeout reasons; adjust `endOnSilence`/`startTimeout`
- **OpenClaw errors**: Verify gateway token and that `chatCompletions` endpoint is enabled
- **Port 80 needed**: Use a reverse proxy, or `sudo setcap cap_net_bind_service=+ep $(which node)`

## Logs

Server logs to stdout and `vonage.log`:

| Tag | Meaning |
|-----|---------|
| `INBOUND` | Received SMS |
| `INBOUND-RAW` | Full Vonage SMS payload |
| `CLAW-REQ` | Request to OpenClaw |
| `CLAW-REPLY` | Response from OpenClaw (with latency) |
| `SMS-SEND` | Sending SMS reply |
| `SMS-OK` | SMS sent successfully |
| `SMS-ERR` | SMS send failure |
| `STATUS` | SMS delivery receipt |
| `ANSWER` | Inbound call received |
| `SPEECH-IN` | Raw speech event from Vonage |
| `SPEECH-RESULT` | Transcript candidate with confidence |
| `TRANSCRIPT` | Final chosen transcript |
| `EVENT` | Call lifecycle event |

## References

- [references/vonage-messages-api.md](references/vonage-messages-api.md) — Messages API reference
- [references/vonage-ncco.md](references/vonage-ncco.md) — NCCO action reference
