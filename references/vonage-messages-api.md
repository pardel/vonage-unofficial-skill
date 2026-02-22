# Vonage Messages API Quick Reference

## Authentication

Uses JWT signed with the application's private key (RS256).

JWT payload:

```json
{ "application_id": "<app-id>", "iat": <unix-ts>, "jti": "<uuid>", "exp": <unix-ts+900> }
```

Header: `Authorization: Bearer <jwt>`

## Send SMS

`POST https://api.nexmo.com/v1/messages`

```json
{
  "message_type": "text",
  "text": "Hello!",
  "to": "447812345678",
  "from": "447441444555",
  "channel": "sms"
}
```

Response: `{ "message_uuid": "..." }`

## Inbound Webhook Payload

Vonage POSTs to your inbound URL:

```json
{
  "to": "447441444555",
  "from": "447812345678",
  "channel": "sms",
  "message_uuid": "...",
  "timestamp": "2026-01-01T00:00:00Z",
  "message_type": "text",
  "text": "Hello!",
  "usage": { "price": "0.0059", "currency": "EUR" },
  "sms": { "num_messages": "1", "count_total": "1" }
}
```

## Status Webhook Payload

```json
{
  "message_uuid": "...",
  "status": "delivered",
  "timestamp": "2026-01-01T00:00:01Z"
}
```

Statuses: `submitted` → `delivered` | `rejected` | `undeliverable`

## Important Settings

- **Default SMS Setting** must be "Messages API" (not "SMS API") in Vonage Dashboard → Settings
- Number must be linked to an application with Messages capability enabled

## Docs

- Messages API: <https://developer.vonage.com/en/messages/overview>
- SMS channel: <https://developer.vonage.com/en/messages/concepts/sms>
