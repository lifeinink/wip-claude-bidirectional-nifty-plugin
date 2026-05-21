# ntfy.sh Message Schema Reference

Source: https://docs.ntfy.sh/publish/

## Endpoint

```
POST https://ntfy.sh/{topic}
Content-Type: text/plain  (or application/json for JSON body)
```

Or self-hosted: `POST https://your-ntfy-server/{topic}`

---

## HTTP Headers

| Header | Alias | Type | Description |
|--------|-------|------|-------------|
| `Title` | `t` | string | Notification title shown in bold |
| `Message` | `m` | string | Message body (also readable from POST body) |
| `Priority` | `prio`, `p` | 1-5 or name | Notification urgency (see below) |
| `Tags` | `tag`, `ta` | string | Comma-separated tags or emoji shortcodes |
| `Delay` | `X-Delay` | string | Schedule delivery (see Delay formats below) |
| `Markdown` | `md` | `yes` | Render message body as CommonMark markdown |
| `Actions` | `action` | string | Action buttons (up to 3, see below) |
| `Attach` | `a` | URL | Attach a file or image by URL |
| `Filename` | `file`, `f` | string | Filename shown for the attachment |
| `Icon` | | URL | Custom notification icon URL |
| `Email` | `mail`, `e` | email | Forward notification to email address |
| `Cache` | | `no` | Do not cache notification on server |
| `Firebase` | | `no` | Do not send via Firebase (Android) |
| `UnifiedPush` | `up` | `1` | Enable UnifiedPush protocol mode |
| `Authorization` | | `Bearer <token>` | Authentication for protected topics |
| `X-Poll-ID` | | string | Used in long-polling responses |

---

## Priority Levels

| Value | Name | Behavior |
|-------|------|----------|
| `1` | `min` | No sound, no popup — truly silent |
| `2` | `low` | Low importance, small notification |
| `3` | `default` | Normal notification (default) |
| `4` | `high` | Bypasses do-not-disturb on some devices |
| `5` | `urgent` / `max` | Breaks through do-not-disturb, loud sound |

---

## Delay / Scheduled Delivery Formats

ntfy.sh **delivers server-side** — the client does not need to remain connected.

| Format | Example | Notes |
|--------|---------|-------|
| Relative duration | `30min`, `2h`, `1d` | From current server time |
| Natural language | `tomorrow`, `10am` | Parsed by ntfy server |
| Unix timestamp | `1740000000` | Seconds since epoch (UTC) |
| RFC 2822 | `Wed, 02 Jun 2021 09:00:00 GMT` | Full RFC date |

**NZ timezone note:** The `nfty:send --at` flag accepts NZ local time (e.g. `2026-06-01 09:00`)
and converts to a Unix timestamp automatically via Python `zoneinfo.ZoneInfo('Pacific/Auckland')`.
The conversion handles NZDT (UTC+13, Oct–Apr) and NZST (UTC+12, May–Sep) automatically.

---

## Action Buttons

Up to 3 action buttons. Set via `Actions` header, one per line or pipe-delimited.

### view — Open a URL
```
view, <Label>, <URL>[, clear=true]
```
Example: `view, Open dashboard, https://grafana.example.com/d/abc123`

### broadcast — Android broadcast intent
```
broadcast, <Label>[, intent=<intent>][, extras.<key>=<value>]
```
Sends an Android broadcast intent to the ntfy app or other receivers.
- Default intent: `io.heckel.ntfy.APP_REVIEW_ACTION`
- Custom intent: `extras.cmd=reboot` etc.
- Useful for app-to-app communication on Android (e.g. trigger another app's action)

Example: `broadcast, Snooze, extras.snooze_duration=10min`

### http — HTTP callback
```
http, <Label>, <URL>[, method=POST][, headers.X-Key=value][, body=<body>][, clear=true]
```
Makes an HTTP request when the button is tapped.
- Default method: POST
- Useful for webhooks, approve/reject flows, Claude Code reply hooks

Example: `http, Approve, https://myserver.com/approve, method=PUT, headers.X-Token=abc`

### Multiple actions
```
Actions: view, View, https://example.com; broadcast, Snooze
```
or set multiple `Actions` headers.

---

## JSON Body Alternative

```json
{
  "topic": "mytopic",
  "message": "Hello from ntfy",
  "title": "Alert",
  "priority": 4,
  "tags": ["warning", "computer"],
  "delay": "30min",
  "attach": "https://example.com/image.png",
  "markdown": true,
  "actions": [
    {"action": "view", "label": "Open", "url": "https://example.com"},
    {"action": "broadcast", "label": "Dismiss", "intent": "io.heckel.ntfy.DISMISS"}
  ]
}
```

---

## Common Emoji Tags

ntfy maps tags to emoji in the notification. Useful shortcodes:

| Tag | Emoji | Tag | Emoji |
|-----|-------|-----|-------|
| `warning` | ⚠️ | `white_check_mark` | ✅ |
| `rotating_light` | 🚨 | `tada` | 🎉 |
| `loudspeaker` | 📢 | `robot` | 🤖 |
| `computer` | 💻 | `clock` | 🕐 |
| `fire` | 🔥 | `construction` | 🚧 |
| `broken_heart` | 💔 | `green_heart` | 💚 |

Full emoji reference: https://docs.ntfy.sh/emojis/

---

## Authentication

Topics can be protected with access control (requires self-hosted or ntfy.sh account):

```
Authorization: Bearer tk_<token>
```

Or basic auth: `Authorization: Basic <base64(user:pass)>`

Free ntfy.sh accounts get reserved topics. See: https://ntfy.sh/account

---

## Subscribe / Long-poll (for receiving messages)

```
GET https://ntfy.sh/{topic}/json          # Stream (SSE/JSON)
GET https://ntfy.sh/{topic}/json?poll=1   # Single poll (non-blocking)
GET https://ntfy.sh/{topic}/json?since=<id|unix|all>
GET https://ntfy.sh/{topic}/sse           # Server-Sent Events
```

---

## Full Documentation

https://docs.ntfy.sh/publish/
