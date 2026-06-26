# coordination_server

A standalone, pure-Dart HTTP service that brokers policy-rejected
smart-account calls between the autonomous reference agent and the
OpenZeppelin smart-account demo app (mobile and web).

The agent posts smart-account calls that its on-chain policy rejected; the demo
app polls them, lets the user approve or reject each one, and reports the
outcome back. The server is the message channel only: it stores requests and
their resolution, never any signing material.

The package has no Flutter dependency and runs with `dart run`.

## Requirements

- Dart SDK `^3.9.0`

## Install and run

```sh
cd coordination_server
dart pub get

# A bearer token is mandatory. The server refuses to start without one.
COORDINATION_TOKEN=dev-token-change-me dart run bin/server.dart
```

For local development you can use the token `dev-token-change-me`. Use a
strong, secret value in any shared or deployed environment.

### Configuration

| Setting | Env var              | CLI flag          | Default   |
|---------|----------------------|-------------------|-----------|
| Port    | `PORT`               | `--port <n>`      | `8787`    |
| Token   | `COORDINATION_TOKEN` | `--token <s>`     | required  |
| Store   | `COORDINATION_STORE` | `--store <path>`  | in-memory |

CLI flags take precedence over environment variables. The server binds
`0.0.0.0` so it is reachable from emulators, devices, and browsers on the LAN.

With `--store` set, the request set is loaded on start (if the file exists) and
written atomically after every mutation, so requests survive a restart. Without
it, state is in-memory only.

```sh
# Persisted, custom port, token via flag:
dart run bin/server.dart --token dev-token-change-me --port 8787 --store ./requests.json
```

The server logs one line per request to stdout and shuts down cleanly on
`SIGINT`/`SIGTERM`.

## Authentication

Every `/requests*` route requires `Authorization: Bearer <token>`. `/health`
and CORS preflight (`OPTIONS`) are exempt. A missing or invalid token returns
`401`. CORS is enabled for all origins so the Flutter web build can poll the
service from a browser.

## Request model

The canonical request object (all fields always present; nullable fields are
`null` until set):

```json
{
  "id":           "string  (uuid v4, server-assigned)",
  "smartAccount": "string  (C-address of the smart account)",
  "target":       "string  (C-address the agent tried to call)",
  "targetFn":     "string  (e.g. \"transfer\")",
  "args":         ["string (base64-encoded XdrSCVal entries, opaque to the server)"],
  "amount":       "string  (display-only; empty string when not supplied)",
  "reason":       3016,
  "status":       "pending | approved | rejected",
  "createdAt":    1782485036185,
  "resolvedAt":   null,
  "resultHash":   null,
  "note":         null
}
```

`args` are stored and returned verbatim so the inbox can rebuild the original
call exactly. The server never inspects them.

## Endpoints

| Method | Path                       | Auth | Description                                  |
|--------|----------------------------|------|----------------------------------------------|
| GET    | `/health`                  | no   | Liveness check.                              |
| POST   | `/requests`                | yes  | Agent posts a rejected call.                 |
| GET    | `/requests`                | yes  | List all requests, newest first.             |
| GET    | `/requests?status=<s>`     | yes  | List filtered by `pending`/`approved`/`rejected`. |
| GET    | `/requests/{id}`           | yes  | Fetch one request (poll its status).         |
| POST   | `/requests/{id}/approve`   | yes  | Approve a pending request.                    |
| POST   | `/requests/{id}/reject`    | yes  | Reject a pending request.                     |

### Status codes

- `200` success, `201` created.
- `400` malformed or invalid body / unknown status filter.
- `401` missing or invalid bearer token.
- `404` unknown request id.
- `409` request is already resolved (a second approve/reject).
- `500` unexpected server error.

All error responses are JSON of the shape `{ "error": "..." }`.

### POST /requests

Body (server-assigned fields are ignored if sent):

```json
{
  "smartAccount": "C...",
  "target":       "C...",
  "targetFn":     "transfer",
  "args":         ["AAAA", "BBBB"],
  "amount":       "10.5",
  "reason":       3016
}
```

Required: `smartAccount`, `target`, `targetFn` (non-empty strings), `args`
(list of strings), `reason` (integer). `amount` is an optional string and
defaults to `""`. Returns `201` with the full created object (`status` is
`pending`).

### POST /requests/{id}/approve

Body: `{ "resultHash": "<tx-or-result-hash>" }` (non-empty string, required).
Sets `status` to `approved`, fills `resolvedAt` and `resultHash`. Returns `200`
with the updated object; `404` if unknown; `409` if already resolved.

### POST /requests/{id}/reject

Body: `{ "note": "<optional reason>" }` (the body may be empty). Sets `status`
to `rejected`, fills `resolvedAt`, and stores `note` when provided. Returns
`200`; `404`; `409` if already resolved.

## curl examples

Assuming the server runs on `http://localhost:8787` with token
`dev-token-change-me`:

```sh
# Health (no auth)
curl http://localhost:8787/health

# Create a request (agent)
curl -X POST http://localhost:8787/requests \
  -H "Authorization: Bearer dev-token-change-me" \
  -H "Content-Type: application/json" \
  -d '{
        "smartAccount": "CSMART...",
        "target": "CTARGET...",
        "targetFn": "transfer",
        "args": ["AAAA", "BBBB"],
        "amount": "10.5",
        "reason": 3016
      }'

# List pending requests (app inbox)
curl "http://localhost:8787/requests?status=pending" \
  -H "Authorization: Bearer dev-token-change-me"

# Poll a single request (agent)
curl http://localhost:8787/requests/<id> \
  -H "Authorization: Bearer dev-token-change-me"

# Approve (app, after the user confirms and submits the tx)
curl -X POST http://localhost:8787/requests/<id>/approve \
  -H "Authorization: Bearer dev-token-change-me" \
  -H "Content-Type: application/json" \
  -d '{"resultHash": "<tx-hash>"}'

# Reject (app)
curl -X POST http://localhost:8787/requests/<id>/reject \
  -H "Authorization: Bearer dev-token-change-me" \
  -H "Content-Type: application/json" \
  -d '{"note": "looks malicious"}'
```

## Project layout

```
coordination_server/
  bin/server.dart                entry point: config, store load, serve
  lib/coordination_server.dart   barrel export
  lib/src/config.dart            CLI/env configuration
  lib/src/models.dart            request model, input validation, typed errors
  lib/src/request_store.dart     in-memory store + atomic JSON persistence
  lib/src/middleware.dart        CORS, bearer auth, error mapping, logging
  lib/src/router.dart            routes + handler assembly
  test/                          store, HTTP, and config tests
```

## Tests and analysis

```sh
dart analyze   # zero issues expected
dart test      # store, HTTP, and config suites
```
