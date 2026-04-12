# Gateway Security Configuration

## Включённые политики

- OIDC plugin / JWT validation
- JWKS cache
- rate limiting per route / client / IP
- request-id and correlation-id injection
- webhook HMAC validation policy
- replay protection via Redis lookup
- mTLS для partner callbacks и внутренних administrative routes

## Protected routes

- `/api/payments` -> user JWT + `payments:create`
- `/api/payments/*` -> user JWT + `payments:read`
- `/api/provider/callbacks/*` -> webhook signature + timestamp + replay check

## JWT validation

- issuer allow-list
- audience check
- clock skew <= 60s
- expired token rejection

## Webhook validation

- raw body preserved for HMAC
- headers required: `X-Signature`, `X-Timestamp`, `X-Event-Id`
- replay-store key in Redis with TTL 10m
