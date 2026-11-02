# Sending labels from your server

*Peel Good Inc.* can get labels from a server you run. Every connection goes out from the Mac: nothing connects in, and the Mac needs no open port. Add your server in Settings → Remote.

You can offer a jobs URL, an event stream, or both. The app checks a jobs URL every 30 seconds and at every connect or wake, so a job can't get lost while the Mac is off. A stream only delivers jobs sooner. With a stream alone, the app can miss labels sent while the Mac is off, unless your server replays them from `Last-Event-ID`.

Your rules choose the printer and label size. A job can only say what to print and how many copies.

## A job

```json
{
  "id": "order-1459",
  "url": "https://example.com/labels/1459.pdf",
  "name": "order 1459.pdf",
  "sha256": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "copies": 2
}
```

| Field | | |
|---|---|---|
| `id` | required | Up to 256 bytes. The app prints each `id` once, so keep it stable. |
| `url` | `url` or `content_base64` | Where to download the file. It must be on the same host as your jobs URL, or on a host listed under Download hosts, over https. Addresses on the Mac's own network are refused on listed hosts. |
| `content_base64` | `url` or `content_base64` | The file itself, up to 1 MB. |
| `name` | optional | The file name your rules see. Defaults to the last part of the URL. |
| `sha256` | optional | The file's SHA-256 in hex. A mismatch fails the job. |
| `copies` | optional | 1 to 100. Otherwise your rules decide. A job asking for more than the limits allow waits in Settings for someone to decide. |

Files must be PDF, PNG or JPEG, up to 25 MB and 20 pages. The app checks the file's contents, not its name. It refuses SVG and raw ZPL.

## Jobs URL

```
GET <jobs URL>
If-None-Match: "<ETag from the last reply>"
Authorization: Bearer <token>        (when you set a token)

200 {"jobs": [ ...jobs... ]}
304 nothing new
429 or 503 with Retry-After: the app waits that long
```

The app treats the first answer as a backlog: it leaves those jobs alone and offers Print Them in Settings. If a job stays in the list after it prints, nothing happens, so you can remove jobs whenever you like.

The URL can also serve a PDF, PNG or JPEG directly, with no list at all. Each new file prints once. Its ETag, or else its contents, identifies it.

## Stream

```
GET <stream URL>
Accept: text/event-stream
Last-Event-ID: <the last id received>        (when reconnecting)

: connected

event: label
id: 42
data: {"id": "order-1459", "url": "https://example.com/labels/1459.pdf"}

: keepalive
```

- Send a comment line as soon as the client connects. Until the first bytes arrive, the app can't tell the stream is open.
- Send a comment line at least every 30 seconds. After 90 seconds of silence, the app reconnects.
- `data` holds one job. The app ignores other event types.
- `retry:` is honoured between 1 second and 5 minutes. Otherwise the app waits 1 second, doubling up to 5 minutes.
- A 401, 403 or 404 shows in Settings, and the app tries again in 15 minutes.

## Hearing what printed

Turn on "Tell the server what printed", and the app reports each job:

```
POST <jobs URL>/<id, percent-encoded>/ack
Content-Type: application/json

{"status": "sent", "labels": 2, "at": "2026-11-02T09:30:00Z"}
```

`status` is `sent`, `cancelled` or `failed`. `sent` means the printer took the job: a CUPS printer doesn't report paper running out. Reports never include printer names or file paths. Any 2xx, 404 or 410 ends it, and the app retries the rest on its next check. It retries the report, never the print.

## What the app won't do

- **Print twice on its own.** If it stops mid-print or a send fails, the label waits in Settings for someone to choose. So design for at most one automatic print of each `id`.
- **Print without a rule.** New labels ask first, until you add a rule with "From a remote source".
- **Keep up with a runaway source.** Past 30 labels in 10 minutes, labels wait in Settings. They aren't dropped.
- **Run on more than one Mac safely.** Two Macs on one source both print.
