# Argus session-cache `REDIS_DB` mismatch — Postmortem

**Author:** Gaurav (with Claude)
**Date:** 2026-04-27
**Status:** Fix landed (`adcb482` on `feat/local-registry-mirror`)
**Scope:** Argus auth-stack login flow on mk09; same misconfiguration was present in
  the manifests for all robots, not specific to mk09.

---

## 1. Symptom

Operator UI on mk09: `POST /api/auth/login` with **valid** credentials returns
`HTTP 500 {"status":500,"error":"Failed to fetch user info"}`.

Browser-visible URL: `http://100.124.202.97:30080/login`.

Reproduces from anywhere — same cluster, host loopback, Tailscale peer:

```
curl -s -X POST http://127.0.0.1:30080/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"app_id":"691bcf923433f53b6a11874d","username":"gaurav","password":"gaurav123123"}'
```

Two characteristics that distinguish this failure from a credential or
DB-availability problem:
- **Invalid usernames** return a fast `401 Invalid credentials`.
- **Valid usernames** return a slow (~120-280ms) `500 Failed to fetch user info`.

The "valid → 500, invalid → 401" pattern was the strongest single hint: the
auth path completed successfully (the long timing is consistent with argon2id
verification), and the failure was downstream of credential check.

## 2. The misleading first hypothesis

A Slack message attributed the failure to commit `638eb4a`, which repointed
`gitops/apps/phantomos-mk09.yaml` from `main` → `feat/local-registry-mirror`,
and proposed that the repoint reconciled the cluster to a different per-service
config — specifically a `REDIS_DB` value mismatch between `argus-auth` and
`argus-user`/`argus-gateway`.

The mechanism was right. The cause-and-effect was wrong:
`git diff main...feat/local-registry-mirror -- manifests/base/argus/` shows
the auth/user/gateway env blocks are byte-identical between branches. The
repoint can't have introduced a config that's the same on both sides of the
diff — the misconfig had been there all along.

What the repoint *did* introduce was a separate failure mode: ArgoCD on
`feat/local-registry-mirror` (before commit `cc3f012`) stripped runtime
`claimRef.uid` from `mongodb-pv` and `redis-pv`, dropping the bound PVCs to
`status.phase: Lost`. MongoDB lost its data mount; argus-user couldn't read
`users`; the gateway returned the same `500 "Failed to fetch user info"`.
That issue produced **the same error string** as the underlying
`REDIS_DB` mismatch, so the two bugs masked each other. By the time we
investigated, the PVC issue had already been resolved by the
`ignoreDifferences` guard in `cc3f012` and a run of
`scripts/rebind-stuck-pvc.sh`. The Redis bug remained.

## 3. Architecture (only the parts relevant to this bug)

```
                       ┌──────────────────┐
                       │  Operator UI     │
                       │  (browser SPA)   │
                       └────────┬─────────┘
                                │
                          POST /api/auth/login
                                │
                       ┌────────▼─────────┐
                       │  nginx           │  (NodePort :30080)
                       │  argus/nginx     │
                       └────────┬─────────┘
                                │
                                │   /api/* → argus-gateway:9100
                                │
                       ┌────────▼─────────┐
                       │  argus-gateway   │  (Fastify; Node)
                       │                  │  reads Redis (read-only)
                       │  POST /login:    │
                       │   1. call argus-auth/login
                       │   2. call argus-user/user/<id>
                       │   3. compose response
                       └────┬────────┬────┘
                            │        │
                ┌───────────┘        └──────────┐
                │                               │
       ┌────────▼─────────┐           ┌─────────▼────────┐
       │  argus-auth      │           │  argus-user      │
       │  (Sanic; Python) │           │  (Sanic; Python) │
       │                  │           │                  │
       │  - verify creds  │           │  - validate      │
       │    (argon2id)    │           │    session via   │
       │  - write session │           │    Redis lookup  │
       │    to Redis      │           │  - return user   │
       │  - mirror to     │           └────┬─────────────┘
       │    Mongo         │                │
       └────┬─────────────┘                │
            │                              │
            │  Both services share         │
            │  ONE Redis namespace:        │
            │      key: session:<uuid>     │
            │      val: {user_id, app_id}  │
            │      TTL: 8h                 │
            ▼                              ▼
       ┌──────────────────────────────────────┐
       │            Redis (DB ?)              │
       │        argus/redis-0                 │
       └──────────────────────────────────────┘
```

The argus-gateway source spells out the contract
(`dist/services/session.js`):

> *"Sessions are created/deleted by argus.auth. Gateway only reads from
> the shared Redis for validation."*

argus-user enforces the same read-only contract
(`app/common/session_validator.py`):

> *"Session tokens are stored in Redis by argus.auth service with keys like:
> `session:{session_token}` -> JSON string with user_id and app_id"*

The implementations match: argus-auth uses `setex` and `delete`,
argus-user only ever calls `redis_conn.get(f"session:{token}")`,
argus-gateway only ever calls `redis.get` and `redis.ttl`. Every key is
under the `session:` prefix. No service uses Redis for any other purpose.

## 4. Root cause

Each service reads a `REDIS_DB` env to choose which logical Redis database
(`SELECT n`) to use:

| service          | manifest                                                  | `REDIS_DB` |
|------------------|-----------------------------------------------------------|:----------:|
| argus-auth       | `manifests/base/argus/argus-auth.yaml:45-46`              | `"0"`      |
| argus-user       | `manifests/base/argus/argus-user.yaml:45-46` (was)        | `"1"`      |
| argus-gateway    | `manifests/base/argus/argus-gateway.yaml:47-48` (was)     | `"3"`      |

argus-auth wrote `session:<token>` to DB 0. argus-user looked for it in
DB 1, which was always empty. argus-gateway looked in DB 3, also empty.

When the gateway proxied a login:
1. `argus-gateway` → `argus-auth/login` returned 200 + a fresh session token.
2. `argus-gateway` → `argus-user/user/<id>` with that token in `X-Session-Token`.
3. argus-user looked up `session:<token>` in *its* Redis (DB 1), got
   nothing, returned `401 Unauthorized`.
4. argus-gateway received 401 from a service it expected to succeed and
   returned `500 "Failed to fetch user info"` to the client.

The differing `REDIS_DB` values were a pure misconfiguration. The original
intent was probably "give each service its own DB for cache isolation" —
sound when each service has its own private cache, wrong when they share
session state.

## 5. Live evidence

```
# In-cluster, bypass the gateway: argus-auth works correctly.
$ k -n argus exec deploy/argus-gateway -- wget -qO- \
    --post-data='{"app_id":"691bcf923433f53b6a11874d","username":"gaurav","password":"gaurav123123"}' \
    --header='Content-Type: application/json' \
    http://argus-auth:9000/login
{"status":200,"message":"Login successful","data":{"session_token":"<TOK>","user_id":"b95249da26418f403252017f",...}}

# The session lives in Redis DB 0.
$ k -n argus exec redis-0 -- redis-cli -n 0 GET "session:<TOK>"
{"user_id":"b95249da26418f403252017f","app_id":"691bcf923433f53b6a11874d"}
$ k -n argus exec redis-0 -- redis-cli -n 0 TTL "session:<TOK>"
28774

# DBs 1 and 3 are empty (where argus-user and argus-gateway look).
$ k -n argus exec redis-0 -- redis-cli -n 1 KEYS '*'
(empty)
$ k -n argus exec redis-0 -- redis-cli -n 3 KEYS '*'
(empty)

# argus-user returns 401 even with a freshly issued, valid token.
$ k -n argus exec deploy/argus-gateway -- wget -qSO- \
    --header='X-Session-Token: <TOK>' \
    http://argus-user:9001/user/b95249da26418f403252017f
HTTP/1.1 401 Unauthorized

# Through the gateway (matching what the browser sees):
$ curl -s -X POST http://127.0.0.1:30080/api/auth/login -H 'Content-Type: application/json' \
    -d '{"app_id":"691bcf923433f53b6a11874d","username":"gaurav","password":"gaurav123123"}'
{"status":500,"error":"Failed to fetch user info"}
```

## 6. Fix

Commit `adcb482` on `feat/local-registry-mirror`: align both consumers
with the writer.

```diff
- # manifests/base/argus/argus-user.yaml
- - name: REDIS_DB
-   value: "1"
+ - name: REDIS_DB
+   # Must match argus-auth's REDIS_DB. argus-auth writes
+   # `session:<token>` keys here; argus-user only reads them
+   # (see app/common/session_validator.py). A mismatch makes
+   # every session lookup miss and surfaces as the gateway's
+   # 500 "Failed to fetch user info" on login.
+   value: "0"
```

```diff
- # manifests/base/argus/argus-gateway.yaml
- - name: REDIS_DB
-   value: "3"
+ - name: REDIS_DB
+   # Must match argus-auth's REDIS_DB — gateway is a read-only
+   # consumer of the shared session cache (dist/services/session.js
+   # comment: "Sessions are created/deleted by argus.auth.
+   # Gateway only reads from the shared Redis for validation.").
+   value: "0"
```

The inline comments are deliberate: the constraint is invisible from
the manifest alone, and the next person to "tidy up" the env block by
giving each service a "fresh" DB number would re-introduce the bug.
The comment forces the question to surface in code review.

### Risk assessment

Zero collision risk on the shared DB. Source audit (sections 3 and 5)
showed every Redis call across all three services touches keys under the
single `session:` prefix; argus-user and argus-gateway never write. There
are no per-service cache namespaces being merged.

### Rollout

ArgoCD reconciled the change in ~4 min (default polling). Both
Deployments rolled out cleanly with the existing `RollingUpdate` strategy
— brief overlap during which old + new pods coexist is harmless because
no Redis writes happen on the old pods (they were only reading from
empty DBs).

## 7. Verification

End-to-end browser-equivalent probe after rollout:

```
$ curl -s -X POST http://127.0.0.1:30080/api/auth/login \
    -H 'Content-Type: application/json' \
    -d '{"app_id":"691bcf923433f53b6a11874d","username":"gaurav","password":"gaurav123123"}'
{"status":200,"message":"Login successful","data":{
  "session_token":"f7433492-3617-44b0-8d13-a7869a431083",
  "expires_at":"2026-04-28T03:34:37.394266",
  "user":{"name":{...},"email":"...:...","phone":{...}, "user_id":"b95249da26418f403252017f"},
  "accesses":[{"user_id":"...","app_id":"691bcf92...","access":["admin"]}],
  "app":{"app_name":"Operator UI",...}
}}
```

PII fields (`name`, `email`, `phone`) are still ciphertext on the wire
(`base64:base64` AES-256-CBC blobs as defined in the seed). Decryption
happens in the operator-ui SPA — out of scope for this fix.

## 8. Lessons / things to remember

1. **Two bugs can produce the same error string.** "Failed to fetch user
   info" was emitted by the gateway both when (a) MongoDB's PVC was
   `Lost` (data path broken) and (b) argus-user's Redis lookup missed
   (control path broken). Diagnose by following the data flow in source,
   not by pattern-matching the error string.

2. **`git diff` falsifies "the repoint changed it" claims fast.** If the
   diff between two refs shows the relevant file is unchanged, the
   variable in question can't be the *new* cause introduced by the
   repoint. It can still be a *pre-existing* cause that's only now
   visible. Falsifying the trigger is not the same as falsifying the
   mechanism — I conflated those, was wrong, and the Slack reporter
   was right on the mechanism.

3. **Read the consumer source for read-only contracts.** Both argus-user
   and argus-gateway carry explicit "shared Redis, read-only" comments
   in source. Those comments declared the architectural invariant the
   manifest violated — the mismatch was discoverable from a 2-minute
   `grep` once we suspected Redis.

4. **Different `REDIS_DB` values per service is a code-smell when the
   services share a key namespace.** Numeric DB selection is a fragile
   isolation mechanism: there's nothing stopping someone from changing
   one service's value in a "harmless" cleanup. If isolation matters,
   prefer key-prefix per service in a single DB. If sharing is the
   point (this case), the manifests should make that visible — hence
   the comments in §6.

5. **`mongo:7`'s init scripts only run on an empty `/data/db`.** The
   PVC re-bind dance preserves the hostPath dataset, so seed-data.js
   does not re-execute on subsequent pod starts. The 30-vs-9 user
   discrepancy that surfaced during this investigation was not a
   seeding bug — it was the original 9-user seed plus 21 organic
   account registrations (Jan-Apr 2026) preserved on the
   `Retain`-policy hostPath PV. Documented here so future
   investigators don't go hunting the same red herring.

## 9. Related material

- `gitops/apps/phantomos-mk09.yaml:27-40` — `ignoreDifferences` rules
  that fixed the *PVC* drift bug from §2 (commit `cc3f012`).
- `scripts/rebind-stuck-pvc.sh` — recovery tool for a PVC stuck in
  `status.phase: Lost`. Header docstring documents the failure mode in
  detail.
- `manifests/base/argus/argus-auth.yaml:39` — `SESSION_DIRECTORY_COLLECTION`
  (the durable session record in MongoDB; the Redis cache is the fast
  path consulted by argus-user/argus-gateway).
- argus source paths (in-container, foundationbot/argus.* images):
  - argus-auth: `/app/app/data.py`, `/app/app/common/session_validator.py`
  - argus-user: `/app/app/orm/redis_client.py`, `/app/app/common/session_validator.py`
  - argus-gateway: `/app/dist/orm/redis-client.js`, `/app/dist/services/session.js`
