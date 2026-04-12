# Security: AuthN/AuthZ and Service Trust

## Цель

Этот документ описывает, как платёжная система аутентифицирует пользователей и сервисы, как проверяются токены и как user context проходит через `Gateway`, `Orchestrator`, `Wallet`, `Transaction` и `Payment Query Service`.

## Выбранная модель

### UI-клиенты: OIDC Authorization Code Flow + PKCE

Для пользовательских web/mobile-каналов используется `OIDC Authorization Code Flow` с `PKCE`.

Поток:

1. Клиент перенаправляется на `IdP`.
2. Пользователь проходит login + MFA.
3. `IdP` возвращает `authorization code`.
4. `Gateway` или `BFF` обменивает `code` на `access token`, `id token`, `refresh token`.
5. Внешние API вызываются через `Gateway`, который валидирует JWT и извлекает user claims.

### Где хранятся токены

- для browser-based UI выбирается server-side session на стороне `Gateway / BFF`, а браузеру выдаётся только `HttpOnly`, `Secure`, `SameSite=Lax` cookie
- для native mobile допускается хранение `refresh token` в secure OS storage, а `access token` живёт коротко и отправляется в `Gateway` как bearer token

Причина такого выбора:

- браузер не получает доступ к `refresh token` из JavaScript
- `Gateway` становится единой точкой валидации JWT и обновления сессии
- mobile остаётся совместимым с нативными SDK и системным secure storage

### M2M: OAuth2 Client Credentials

Для интеграций мерчантов и внутренних машинных вызовов используются service accounts и `OAuth2 Client Credentials`.

Типовые сценарии:

- партнёр вызывает публичный API для запроса статуса или создания платежа
- `Callback Service` вызывает `Transaction Service` от service principal
- `Transaction Service` вызывает `Wallet Service` от service principal

## Где валидируется JWT

Обязательная проверка выполняется на `Gateway`:

- проверка подписи по `JWKS`
- проверка `iss`, `aud`, `exp`, `nbf`
- проверка scopes/roles по маршруту

Дополнительно внутри сервисов используется defense-in-depth:

- `Orchestrator` проверяет presence и минимальный набор claims в user context
- `Wallet`, `Transaction`, `Query` проверяют service principal / internal scopes для чувствительных внутренних вызовов
- сервисы не доверяют только заголовкам от внешнего клиента; внутренний контекст должен быть подписан `Gateway` или подтверждён service token

## Token propagation и внутренний контекст

Есть два режима:

### User-initiated flow

Когда пользователь вызывает `POST /api/payments` или чтение статуса:

- `Gateway` валидирует JWT
- в downstream передаются нормализованные claims: `sub`, `customerId`, `sessionId`, `scopes`, `roles`, `correlationId`
- для внутренних вызовов `Orchestrator -> Wallet` user context пробрасывается вместе с внутренним service token

### Service-to-service flow

Для внутренних сервисных вызовов используется отдельный service token, полученный по `client_credentials`.

Это важно для разделения:

- кто инициировал действие как пользователь
- какой именно сервис имеет право выполнить внутреннюю команду

## Роли и scopes

| Endpoint / контур | Principal | Required scopes / roles | Зачем |
|---|---|---|---|
| `POST /api/payments` | user | `payments:create` | старт платёжной саги |
| `GET /api/payments/{paymentId}` | user | `payments:read` | чтение статуса |
| `GET /api/users/{userId}/payments` | user | `payments:read:self` или backoffice role | история платежей |
| `POST /api/provider/callbacks/{providerCode}` | external provider | HMAC signature + timestamp + replay protection | приём webhook |
| `POST /internal/provider-results` | `Callback Service` | `transaction:write` | обновление provider result |
| `POST /internal/wallet/payments/reserve` | `Orchestrator` | `wallet:reserve` | резервирование средств |
| `POST /internal/wallet/payments/{paymentId}/commit` | `Transaction Service` / re-drive tool | `wallet:commit` | финализация списания |
| `POST /internal/wallet/payments/{paymentId}/release` | `Transaction Service` / re-drive tool | `wallet:release` | компенсация |
| `GET /internal/transactions/{paymentId}` | internal service | `transaction:read` | технический статус |

## Service-to-service security model

### Базовая модель доверия

Внутренние вызовы используют сочетание:

- `mTLS` на уровне service mesh / ingress между сервисами
- service tokens по `OAuth2 Client Credentials`
- user context propagation только для user-initiated сценариев

### Почему не один механизм

- `mTLS` подтверждает, что запрос пришёл от доверенного workload-а
- service token даёт прикладной контекст авторизации
- propagation user claims нужен только там, где сервис должен принимать решение в рамках пользователя, а не только сервиса

## Таблица доверия между сервисами

| Caller | Callee | Auth method | Что проверяется | Principal type | Required scopes |
|---|---|---|---|---|---|
| Client | Gateway | OIDC JWT / session cookie | JWT/session, user scopes | user | `payments:create`, `payments:read` |
| Orchestrator | Wallet | mTLS + service token + propagated user context | service principal + allowed user scopes | service + user | `wallet:reserve` |
| Transaction | Wallet | mTLS + service token | только service authorization | service | `wallet:commit`, `wallet:release` |
| Callback Service | Transaction | mTLS + service token | service principal и allowed callback scope | service | `transaction:write` |
| Orchestrator | Query | mTLS + service token + user context | user scope + internal principal | service + user | `payments:read`, `query:read` |
| Gateway | Callback Service | trusted ingress policy after HMAC validation | webhook route policy | external callback path | HMAC + anti-replay, без OAuth scope |

## 12-factor конфигурация

### Что должно быть только в окружении

- `OIDC_ISSUER_URI`
- `OIDC_CLIENT_ID`
- `OIDC_CLIENT_SECRET`
- `OAUTH_TOKEN_URL`
- `SERVICE_AUDIENCE`
- `PROVIDER_API_BASE_URL`
- `PROVIDER_API_KEY`
- `WEBHOOK_SECRET_CURRENT`
- `WEBHOOK_SECRET_PREVIOUS`
- `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`
- `VAULT_ADDR`, `VAULT_ROLE`
- `FEATURE_FLAGS_ENDPOINT`

### Что нельзя хардкодить

- client secrets
- webhook signing secrets
- provider API keys
- DB credentials
- rollout environment URLs
- production-specific issuer/audience values

### Как конфиги двигаются между env

- сами значения приходят из `Vault` или `K8s Secrets`
- manifest-ы и Helm values хранят только ссылки на секреты и не содержат реальные значения
- список required env vars versioned в Git и одинаков между `dev`, `stage`, `prod`, меняются только значения

## Вывод

Безопасность здесь строится по слоям:

- пользователь проходит `OIDC`
- `Gateway` валидирует JWT и режет доступ по scopes
- сервисы дополнительно проверяют service principal
- внутренние вызовы закрыты `mTLS` и service tokens
- конфигурация и секреты вынесены из кода и приходят из внешнего secret store
