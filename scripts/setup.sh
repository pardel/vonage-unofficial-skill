#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/setup.sh <target-directory>
# Creates a Vonage SMS + Voice webhook server project.

TARGET="${1:?Usage: setup.sh <target-directory>}"

if [ -d "$TARGET/node_modules" ]; then
  echo "[skip] $TARGET already has node_modules — run 'node server.js' to start"
  exit 0
fi

mkdir -p "$TARGET"

# ── package.json ─────────────────────────────────────────────────────────
cat > "$TARGET/package.json" << 'PACKAGE_EOF'
{
  "name": "vonage-unofficial",
  "version": "1.0.0",
  "description": "Vonage SMS + Voice webhook server for OpenClaw",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "express": "^4.18.0" }
}
PACKAGE_EOF

# ── .env configuration ───────────────────────────────────────────────────
if [ ! -f "$TARGET/.env" ]; then
  echo ""
  echo "── Configuration ──────────────────────────────────────────────────"
  echo "Enter your credentials below. Press Enter to accept defaults shown in [brackets]."
  echo ""

  read -rp "Vonage Application ID: " VONAGE_APP_ID
  while [ -z "$VONAGE_APP_ID" ]; do
    read -rp "  (required) Vonage Application ID: " VONAGE_APP_ID
  done

  read -rp "Vonage number (no + prefix): " VONAGE_NUMBER
  while [ -z "$VONAGE_NUMBER" ]; do
    read -rp "  (required) Vonage number: " VONAGE_NUMBER
  done

  echo "Vonage private key — paste the full key below, then press Enter on an empty line:"
  PRIVATE_KEY=""
  while IFS= read -r line; do
    [ -z "$line" ] && [ -n "$PRIVATE_KEY" ] && break
    PRIVATE_KEY="${PRIVATE_KEY}${line}"$'\n'
  done
  if [ -z "$PRIVATE_KEY" ]; then
    echo "  (required) No private key provided — you must paste it or place it manually at $TARGET/private.key"
  else
    printf '%s' "$PRIVATE_KEY" > "$TARGET/private.key"
    chmod 600 "$TARGET/private.key"
    echo "[created] $TARGET/private.key"
  fi

  DETECTED_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
  if [ -n "$DETECTED_IP" ]; then
    read -rp "Server public IP or domain [$DETECTED_IP]: " SERVER_HOST
    SERVER_HOST="${SERVER_HOST:-$DETECTED_IP}"
  else
    read -rp "Server public IP or domain: " SERVER_HOST
    while [ -z "$SERVER_HOST" ]; do
      read -rp "  (required) Server public IP or domain: " SERVER_HOST
    done
  fi
  PUBLIC_URL="http://${SERVER_HOST}:62529"
  PORT=62529

  # Auto-detect OpenClaw gateway
  DETECTED_GATEWAY_URL=""
  DETECTED_GATEWAY_TOKEN=""
  if command -v openclaw &>/dev/null; then
    DETECTED_GATEWAY_TOKEN=$(openclaw config get gateway.auth.token 2>/dev/null || echo "")
    DETECTED_GATEWAY_URL="http://127.0.0.1:18789"
  fi

  if [ -n "$DETECTED_GATEWAY_URL" ]; then
    read -rp "OpenClaw gateway URL [$DETECTED_GATEWAY_URL]: " OPENCLAW_GATEWAY_URL
    OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-$DETECTED_GATEWAY_URL}"
  else
    read -rp "OpenClaw gateway URL [http://127.0.0.1:18789]: " OPENCLAW_GATEWAY_URL
    OPENCLAW_GATEWAY_URL="${OPENCLAW_GATEWAY_URL:-http://127.0.0.1:18789}"
  fi

  if [ -n "$DETECTED_GATEWAY_TOKEN" ]; then
    read -rp "OpenClaw gateway token [detected]: " OPENCLAW_GATEWAY_TOKEN
    OPENCLAW_GATEWAY_TOKEN="${OPENCLAW_GATEWAY_TOKEN:-$DETECTED_GATEWAY_TOKEN}"
  else
    read -rp "OpenClaw gateway token: " OPENCLAW_GATEWAY_TOKEN
    while [ -z "$OPENCLAW_GATEWAY_TOKEN" ]; do
      read -rp "  (required) OpenClaw gateway token: " OPENCLAW_GATEWAY_TOKEN
    done
  fi

  cat > "$TARGET/.env" <<EOF
VONAGE_APP_ID=$VONAGE_APP_ID
VONAGE_PRIVATE_KEY_PATH=./private.key
VONAGE_NUMBER=$VONAGE_NUMBER
PUBLIC_URL=$PUBLIC_URL
PORT=$PORT
OPENCLAW_GATEWAY_URL=$OPENCLAW_GATEWAY_URL
OPENCLAW_GATEWAY_TOKEN=$OPENCLAW_GATEWAY_TOKEN
EOF
  echo ""
  echo "[created] $TARGET/.env"
else
  echo "[skip] $TARGET/.env already exists"
fi

# ── .gitignore ───────────────────────────────────────────────────────────
cat > "$TARGET/.gitignore" << 'GIT_EOF'
node_modules/
.env
private.key
vonage.log
GIT_EOF

# ── server.js ────────────────────────────────────────────────────────────
cat > "$TARGET/server.js" << 'SERVER_EOF'
const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// ── Load .env ───────────────────────────────────────────────────────────
const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([^#=]+?)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}

const PORT = parseInt(process.env.PORT || '62529', 10);
const PUBLIC_URL = process.env.PUBLIC_URL || `http://127.0.0.1:${PORT}`;
const VONAGE_APP_ID = process.env.VONAGE_APP_ID;
const VONAGE_PRIVATE_KEY = fs.readFileSync(
  path.resolve(__dirname, process.env.VONAGE_PRIVATE_KEY_PATH || './private.key'),
  'utf8'
);
const VONAGE_NUMBER = process.env.VONAGE_NUMBER;
const OPENCLAW_URL = process.env.OPENCLAW_GATEWAY_URL || 'http://127.0.0.1:18789';
const OPENCLAW_TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN;

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ── Logging ─────────────────────────────────────────────────────────────
const LOG_FILE = path.join(__dirname, 'vonage.log');

function log(tag, ...args) {
  const ts = new Date().toISOString();
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  const line = `[${ts}] [${tag}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
}

app.use((req, res, next) => {
  log('HTTP', `${req.method} ${req.url}`);
  next();
});

// ── JWT generation (for Messages API auth) ──────────────────────────────
function generateJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const payload = {
    application_id: VONAGE_APP_ID,
    iat: now,
    jti: crypto.randomUUID(),
    exp: now + 900,
  };
  const enc = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const unsigned = `${enc(header)}.${enc(payload)}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(unsigned), VONAGE_PRIVATE_KEY);
  return `${unsigned}.${signature.toString('base64url')}`;
}

// ── Conversation state (in-memory) ─────────────────────────────────────
const smsConversations = new Map();    // keyed by phone number
const voiceConversations = new Map();  // keyed by conversation_uuid

setInterval(() => {
  const smsCutoff = Date.now() - 7200_000;   // 2 hours
  const voiceCutoff = Date.now() - 3600_000; // 1 hour
  for (const [num, conv] of smsConversations) {
    if (conv.updatedAt < smsCutoff) smsConversations.delete(num);
  }
  for (const [id, conv] of voiceConversations) {
    if (conv.updatedAt < voiceCutoff) voiceConversations.delete(id);
  }
}, 600_000);

// ── OpenClaw integration ────────────────────────────────────────────────
const SMS_SYSTEM_PROMPT =
  'You are responding via SMS. Keep responses concise — SMS has a 140 character limit per segment, so aim for short, clear replies. No markdown. Be conversational but brief.';

const VOICE_SYSTEM_PROMPT =
  'You are speaking on a phone call. Rules: 1) Maximum 2 sentences per reply. 2) No markdown, no bullet points, no special characters. 3) Use plain spoken English only. 4) If the caller says goodbye, respond with one short sentence.';

async function askClaw(conversationMap, id, userText, systemPrompt) {
  let conv = conversationMap.get(id);
  if (!conv) {
    conv = {
      messages: [{ role: 'system', content: systemPrompt }],
      updatedAt: Date.now(),
    };
    conversationMap.set(id, conv);
  }

  conv.messages.push({ role: 'user', content: userText });
  conv.updatedAt = Date.now();

  log('CLAW-REQ', `id=${id} text="${userText}" messages=${conv.messages.length}`);

  const startMs = Date.now();
  const res = await fetch(`${OPENCLAW_URL}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${OPENCLAW_TOKEN}`,
    },
    body: JSON.stringify({ model: 'openclaw', messages: conv.messages }),
  });

  const elapsed = Date.now() - startMs;

  if (!res.ok) {
    const body = await res.text();
    log('CLAW-ERR', `status=${res.status} elapsed=${elapsed}ms body=${body}`);
    return "Sorry, having trouble right now. Try again shortly.";
  }

  const data = await res.json();
  const reply = data.choices?.[0]?.message?.content || "Sorry, something went wrong.";
  conv.messages.push({ role: 'assistant', content: reply });
  log('CLAW-REPLY', `id=${id} elapsed=${elapsed}ms reply="${reply}"`);
  return reply;
}

// ═══════════════════════════════════════════════════════════════════════
// SMS (Messages API)
// ═══════════════════════════════════════════════════════════════════════

async function sendSms(to, text) {
  log('SMS-SEND', `to=${to} text="${text}"`);

  const jwt = generateJwt();
  const res = await fetch('https://api.nexmo.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify({
      message_type: 'text',
      text,
      to,
      from: VONAGE_NUMBER,
      channel: 'sms',
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    log('SMS-ERR', `to=${to} status=${res.status} body=${body}`);
    return false;
  }

  const data = await res.json();
  log('SMS-OK', `to=${to} messageId=${data.message_uuid}`);
  return true;
}

async function handleInbound(params) {
  const from = params.from || params.msisdn;
  const text = params.text;

  if (!from || !text) {
    log('INBOUND-SKIP', 'Missing from or text');
    return;
  }

  log('INBOUND', `from=${from} text="${text}"`);

  try {
    const reply = await askClaw(smsConversations, from, text, SMS_SYSTEM_PROMPT);
    await sendSms(from, reply);
  } catch (err) {
    log('ERROR', `from=${from} ${err.message}`);
    await sendSms(from, "Sorry, something went wrong.").catch(() => {});
  }
}

app.post('/webhooks/inbound', async (req, res) => {
  log('INBOUND-RAW', req.body);
  res.status(200).end();
  await handleInbound(req.body);
});

app.get('/webhooks/inbound', async (req, res) => {
  log('INBOUND-RAW', req.query);
  res.status(200).end();
  await handleInbound(req.query);
});

app.post('/webhooks/status', (req, res) => {
  log('STATUS', `messageId=${req.body.message_uuid} status=${req.body.status}`);
  res.status(200).end();
});

app.post('/send', async (req, res) => {
  const { to, text } = req.body;
  if (!to || !text) return res.status(400).json({ error: 'to and text required' });
  const ok = await sendSms(to, text);
  res.json({ ok });
});

// ═══════════════════════════════════════════════════════════════════════
// Voice (Voice API + NCCO)
// ═══════════════════════════════════════════════════════════════════════

function listenAction() {
  return {
    action: 'input',
    type: ['speech'],
    speech: {
      language: 'en-GB',
      endOnSilence: 2,
      startTimeout: 20,
      maxDuration: 60,
    },
    eventUrl: [`${PUBLIC_URL}/webhooks/speech`],
  };
}

function sanitizeForTts(text) {
  return text
    .replace(/[*_`#~\[\](){}|<>\\]/g, '')
    .replace(/\n+/g, '. ')
    .replace(/\s+/g, ' ')
    .replace(/["\u201c\u201d]/g, '"')
    .replace(/['\u2018\u2019]/g, "'")
    .trim()
    .slice(0, 500);
}

function talkAction(text) {
  return { action: 'talk', text: sanitizeForTts(text), language: 'en-GB', style: 2 };
}

const GREETING = "Hello! What can I help you with?";

app.post('/webhooks/answer', (req, res) => {
  log('ANSWER', `from=${req.body.from} to=${req.body.to} conv=${req.body.conversation_uuid}`);
  res.json([talkAction(GREETING), listenAction()]);
});

app.get('/webhooks/answer', (req, res) => {
  log('ANSWER', `from=${req.query.from} to=${req.query.to} conv=${req.query.conversation_uuid}`);
  res.json([talkAction(GREETING), listenAction()]);
});

app.post('/webhooks/speech', async (req, res) => {
  const body = req.body;
  const convId = body.conversation_uuid;
  const speechResults = body.speech?.results;
  const timeoutReason = body.speech?.timeout_reason;

  log('SPEECH-IN', `conv=${convId} timeout=${timeoutReason || 'none'} results=${speechResults?.length || 0}`);

  if (speechResults?.length) {
    speechResults.forEach((r, i) => {
      log('SPEECH-RESULT', `#${i} confidence=${r.confidence} text="${r.text}"`);
    });
  }

  if (!speechResults || speechResults.length === 0 || timeoutReason === 'start_timeout') {
    return res.json([listenAction()]);
  }

  const transcript = speechResults[0]?.text || '';
  if (!transcript) {
    return res.json([talkAction("Sorry, I didn't catch that. Could you say it again?"), listenAction()]);
  }

  log('TRANSCRIPT', `conv=${convId} "${transcript}"`);

  const goodbyePhrases = ['goodbye', 'bye', 'see you', 'hang up', 'end call', "that's all"];
  const isGoodbye = goodbyePhrases.some((p) => transcript.toLowerCase().includes(p));

  try {
    const reply = await askClaw(voiceConversations, convId, transcript, VOICE_SYSTEM_PROMPT);

    if (isGoodbye) {
      log('GOODBYE', `conv=${convId}`);
      voiceConversations.delete(convId);
      return res.json([talkAction(reply)]);
    }

    log('RESPONSE-OUT', `conv=${convId}`);
    return res.json([talkAction(reply), listenAction()]);
  } catch (err) {
    log('ERROR', `conv=${convId} ${err.message}`);
    return res.json([talkAction("Sorry, something went wrong. Let me try again."), listenAction()]);
  }
});

app.post('/webhooks/event', (req, res) => {
  const { status, conversation_uuid, direction, from, to } = req.body || {};
  log('EVENT', `status=${status} conv=${conversation_uuid} dir=${direction} from=${from} to=${to}`);
  if (['completed', 'failed', 'rejected', 'busy', 'cancelled'].includes(status)) {
    voiceConversations.delete(conversation_uuid);
  }
  res.status(200).end();
});

// ═══════════════════════════════════════════════════════════════════════
// Health + Start
// ═══════════════════════════════════════════════════════════════════════

app.get('/health', (req, res) => {
  res.json({ status: 'ok', smsConversations: smsConversations.size, voiceConversations: voiceConversations.size });
});

app.listen(PORT, '0.0.0.0', () => {
  log('START', `Listening on port ${PORT}`);
  log('START', `Public URL: ${PUBLIC_URL}`);
  log('START', `Vonage number: ${VONAGE_NUMBER}`);
  log('START', `Vonage app: ${VONAGE_APP_ID}`);
  log('START', `OpenClaw: ${OPENCLAW_URL}`);
  log('START', `SMS webhooks: /webhooks/inbound, /webhooks/status`);
  log('START', `Voice webhooks: ${PUBLIC_URL}/webhooks/answer, ${PUBLIC_URL}/webhooks/event`);
});
SERVER_EOF

# ── Install dependencies ─────────────────────────────────────────────────
cd "$TARGET" && npm install

PUBLIC_URL="${PUBLIC_URL:-http://127.0.0.1:62529}"

echo ""
echo "Vonage SMS + Voice server created at $TARGET"
echo ""
if [ ! -f "$TARGET/private.key" ]; then
  echo "  Place your Vonage private key at $TARGET/private.key"
  echo ""
fi
echo "Double-check that your Vonage application webhooks are configured with:"
echo "  Voice — Answer URL:     $PUBLIC_URL/webhooks/answer"
echo "  Voice — Event URL:      $PUBLIC_URL/webhooks/event"
echo "  Messages — Inbound URL: $PUBLIC_URL/webhooks/inbound"
echo "  Messages — Status URL:  $PUBLIC_URL/webhooks/status"
echo ""
echo "Start the server: cd $TARGET && node server.js"
