# Vonage NCCO Quick Reference

NCCO (Nexmo Call Control Objects) are JSON arrays that control call flow.

## Key Actions

### talk
Speaks text to the caller using TTS.
```json
{ "action": "talk", "text": "Hello", "language": "en-GB", "style": 2 }
```
- `language`: BCP-47 code (e.g. `en-GB`, `en-US`)
- `style`: Voice style variant (0-based index)
- `bargeIn`: If `true`, caller can interrupt with speech

### input
Collects speech (or DTMF) input from the caller.
```json
{
  "action": "input",
  "type": ["speech"],
  "speech": {
    "language": "en-GB",
    "endOnSilence": 2,
    "startTimeout": 20,
    "maxDuration": 60
  },
  "eventUrl": ["https://example.com/webhooks/speech"]
}
```
- `endOnSilence`: Seconds of silence before ending capture
- `startTimeout`: Seconds to wait for speech to begin
- `maxDuration`: Max seconds of speech to capture
- `eventUrl`: Where Vonage POSTs the speech result

### Speech Result Payload
```json
{
  "conversation_uuid": "CON-xxx",
  "speech": {
    "results": [{ "text": "hello world", "confidence": "0.95" }],
    "timeout_reason": "end_on_silence_timeout"
  }
}
```
- `timeout_reason`: `end_on_silence_timeout` | `start_timeout` | `max_duration`

## Conversation Loop Pattern

1. `talk` (speak response) → `input` (listen) → speech webhook → repeat
2. To end call: return `talk` only (no subsequent `input`)

## Docs
- NCCO reference: https://developer.vonage.com/en/voice/voice-api/ncco-reference
- Speech recognition: https://developer.vonage.com/en/voice/voice-api/guides/asr
