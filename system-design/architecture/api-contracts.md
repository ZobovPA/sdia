# API-контракты

## Внешний API

### `POST /api/payments`

Назначение: старт платежной саги.

`requestId` - внешний идемпотентный ключ create-операции.

Пример запроса:

```json
{
  "requestId": "8f61fd47-4ec1-4cd2-a3af-5f7b3b70d122",
  "userId": "user-42",
  "walletId": "wallet-42",
  "amount": {
    "currency": "RUB",
    "value": 125000
  },
  "recipient": {
    "provider": "external-bank",
    "account": "40702810000000000001"
  },
  "merchantInfo": {
    "merchantId": "merchant-77",
    "merchantOrderId": "order-100500"
  }
}
```

Пример ответа:

```json
{
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "status": "RESERVED",
  "nextStatusSource": "ASYNC"
}
```

Контракт идемпотентности для `POST /api/payments`:

- первый запрос с новым `requestId` создаёт новый платёж и возвращает `202 Accepted` с новым `paymentId`
- повторный запрос с тем же `requestId` и тем же нормализованным бизнес-payload не создаёт второй платёж и возвращает тот же `paymentId`
- повторный запрос с тем же `requestId`, но с другим бизнес-payload, возвращает `409 Conflict`

Пример повторного запроса с тем же `requestId`:

```json
{
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "status": "RESERVED",
  "nextStatusSource": "ASYNC",
  "idempotentReplay": true
}
```

Пример конфликта при повторном `requestId` с другим payload:

```json
{
  "errorCode": "IDEMPOTENCY_CONFLICT",
  "message": "requestId already used with different payment parameters"
}
```

`Orchestrator / API` не хранит собственную таблицу идемпотентности. Он каждый раз передаёт `requestId` и нормализованный payload в `Wallet Service`, а mapping `requestId -> paymentId` хранится в `Wallet DB`.

### `GET /api/payments/{paymentId}`

Назначение: получить актуальный статус платежа из read-модели.

### `GET /api/users/{userId}/payments`

Назначение: получить историю платежей пользователя из read-модели.

## Внутренний командный контракт Wallet Service

Ниже перечислены внутренние команды границы `Wallet Service`. В основном runtime-сценарии:

- `reserveFunds` приходит синхронно по REST от `Orchestrator`, а `Wallet Service` создаёт `paymentId` при первом вызове или возвращает уже существующий `paymentId` по `requestId`
- `commitFunds` и `releaseFunds` инициируются асинхронно terminal events `PaymentCompleted` и `PaymentFailed`, которые обрабатывает внутренний consumer `Wallet Service`

HTTP endpoints для `commitFunds` и `releaseFunds` остаются как технический fallback для recovery / re-drive, но не используются как основной способ межсервисной координации в саге.

### `POST /internal/wallet/payments/reserve`

Назначение: локальная команда резервирования денег и запуска саги.

```json
{
  "requestId": "8f61fd47-4ec1-4cd2-a3af-5f7b3b70d122",
  "userId": "user-42",
  "walletId": "wallet-42",
  "amount": {
    "currency": "RUB",
    "value": 125000
  },
  "recipient": {
    "providerId": "external-bank",
    "account": "40702810000000000001"
  },
  "merchantInfo": {
    "merchantId": "merchant-77",
    "merchantOrderId": "order-100500"
  }
}
```

Пример ответа:

```json
{
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "status": "RESERVED",
  "idempotentReplay": false
}
```

`Wallet Service` не вызывает провайдера напрямую, но сохраняет эти данные в payload события `PaymentInitiated`, чтобы их получил `Transaction Service`. Для внешней идемпотентности сервис хранит mapping `requestId -> paymentId` и отпечаток нормализованного payload.

### `POST /internal/wallet/payments/{paymentId}/commit`

Назначение: финализировать резерв в окончательное списание.

Основной trigger: событие `PaymentCompleted` из Kafka, которое обрабатывает внутренний command handler `Wallet Service`.

HTTP endpoint: технический fallback для recovery / ручного re-drive.

### `POST /internal/wallet/payments/{paymentId}/release`

Назначение: снять резерв и вернуть деньги в available balance.

Основной trigger: событие `PaymentFailed` из Kafka, которое обрабатывает внутренний command handler `Wallet Service`.

HTTP endpoint: технический fallback для recovery / ручного re-drive.

## Внутренний API Transaction Service

### `POST /internal/provider-results`

Назначение: внутренний endpoint, который вызывает `Callback Service` после валидации callback-а.

```json
{
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "providerTxnId": "prov-90001",
  "providerStatus": "SUCCESS",
  "callbackId": "019575e8-a9f6-7d55-8ff7-0f40e0e71380",
  "providerEventId": "evt-8832",
  "dedupeKey": "external-bank:prov-90001:SUCCESS:evt-8832",
  "signatureValid": true,
  "receivedAt": "2026-03-13T12:15:01Z"
}
```

### `GET /internal/transactions/{paymentId}`

Назначение: получить технический статус платежа внутри write-контура.

## API Callback Service

### `POST /api/provider/callbacks/{providerCode}`

Назначение: внешний callback endpoint провайдера.

Обязанности callback-service:

- проверить подпись и обязательные поля
- извлечь `paymentId` из поля `merchantReference` / `externalId`, которое провайдер возвращает в callback
- нормализовать статус
- сформировать `dedupeKey` для защиты от повторных callback-ов
- передать результат во внутренний API `Transaction Service`

Пример нормализованного результата:

```json
{
  "providerCode": "external-bank",
  "merchantReference": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "providerTxnId": "prov-90001",
  "providerStatus": "SUCCESS",
  "providerEventId": "evt-8832",
  "signature": "base64-signature"
}
```

`Transaction Service` передаёт `paymentId` провайдеру как внешний reference при создании внешней транзакции. Поэтому `Callback Service` не хранит собственную таблицу маппинга и не ищет `paymentId` в отдельном хранилище.

`dedupeKey` строится из нормализованных полей callback-а. Если у провайдера есть `providerEventId`, он входит в ключ напрямую. Если нет, в ключ включается хеш нормализованного payload.

## Границы ответственности

- внешний клиент не вызывает напрямую `Wallet Service` или `Transaction Service`
- `Callback Service` не меняет write-модель кошелька
- `Transaction Service` остаётся источником истины по результату внешнего платежа
- чтения идут только через `Payment Query Service`
