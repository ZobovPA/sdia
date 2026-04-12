# Runbook

## Callback signature failures

Симптомы:

- рост `401` на callback endpoint
- всплеск `callbacks.invalid.dlq`
- alert по invalid signature count

Что проверить:

1. текущий и previous webhook secret в `Vault`
2. не сломан ли canonical string на `Gateway`
3. не ушёл ли provider на новый secret раньше окна совместимости

Что делать:

- включить режим accept current + previous
- при необходимости временно заморозить revoke старого секрета
- сверить raw payload sample и расчёт HMAC

## IdP down / token validation issues

Симптомы:

- рост `401/503` на `Gateway`
- ошибки refresh token exchange
- проблемы получения `JWKS`

Что проверить:

1. доступность `IdP`
2. cache `JWKS` на `Gateway`
3. не истёк ли client secret / redirect URI config

Что делать:

- использовать cached `JWKS` до истечения TTL
- переключить `IdP` на standby, если есть
- при необходимости остановить rollout gateway changes

## Provider timeout burst

Симптомы:

- рост provider timeout rate
- рост `provider.retry` queue
- breaker открывается чаще нормы

Что делать:

1. проверить `Provider Health Dashboard`
2. убедиться, что retry queue не переполняется
3. проверить, не растёт ли число `TIMEOUT`
4. при длительной деградации уведомить business/support

## Outbox lag / stuck hold risk

Симптомы:

- рост `wallet_outbox` lag
- рост числа `RESERVED` записей рядом с `hold_expires_at`

Что делать:

1. проверить `Wallet Outbox Publisher`
2. проверить DB, polling lag и publication errors
3. убедиться, что `Hold Expiry Monitor` работает
4. проверить рост `PaymentExpired`

## Token validation issues во внутренних вызовах

Симптомы:

- `403` между сервисами
- callback accepted на edge, но rejected в `Transaction Service`

Что проверить:

1. service account scopes
2. audience внутреннего токена
3. mTLS identity / SAN
4. clock skew

Что делать:

- сверить issuer/audience config
- проверить rollout security-policy
- вернуть previous config через GitOps rollback
