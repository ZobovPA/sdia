# Сообщения брокера

В архитектуре используется `Kafka`. Все доменные события платежного процесса публикуются в единый топик `payments.events`. Канонический key для partitioning - `paymentId`.

## `PaymentInitiated`

Источник: `Wallet Service`

Потребители:

- `Transaction Service`
- `Payment Query Service`

```json
{
  "eventId": "019575e7-1ec6-7af2-8c68-2eb9d78ebf10",
  "eventType": "PaymentInitiated",
  "occurredAt": "2026-03-13T12:00:00Z",
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "requestId": "8f61fd47-4ec1-4cd2-a3af-5f7b3b70d122",
  "userId": "user-42",
  "walletId": "wallet-42",
  "merchantId": "merchant-77",
  "merchantOrderId": "order-100500",
  "providerId": "external-bank",
  "recipientAccount": "40702810000000000001",
  "amount": {
    "currency": "RUB",
    "value": 125000
  },
  "status": "RESERVED",
  "createdAt": "2026-03-13T12:00:00Z"
}
```

Событие несёт полный стартовый слепок платежа для запуска саги и первичного построения read-модели.

## `PaymentExpired`

Источник: `Wallet Service`

Потребители:

- `Payment Query Service`

```json
{
  "eventId": "019575e8-5a11-7b7d-bc11-56a1d0de91ef",
  "eventType": "PaymentExpired",
  "occurredAt": "2026-03-13T12:10:00Z",
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "requestId": "8f61fd47-4ec1-4cd2-a3af-5f7b3b70d122",
  "userId": "user-42",
  "walletId": "wallet-42",
  "merchantId": "merchant-77",
  "merchantOrderId": "order-100500",
  "providerId": "external-bank",
  "recipientAccount": "40702810000000000001",
  "amount": {
    "currency": "RUB",
    "value": 125000
  },
  "status": "EXPIRED",
  "failureReason": "HOLD_EXPIRED_BEFORE_DISPATCH",
  "createdAt": "2026-03-13T12:00:00Z",
  "finishedAt": "2026-03-13T12:10:00Z"
}
```

Событие публикуется только в защитном сценарии, когда резерв уже создан, но `PaymentInitiated` не вышел из `wallet_outbox` до истечения `hold_expires_at`.

## `PaymentCompleted`

Источник: `Transaction Service`

Потребители:

- `Wallet Service`
- `Payment Query Service`
- `Notifications Service`

```json
{
  "eventId": "019575e8-0c31-7ff4-ae1c-a6817af0a2f8",
  "eventType": "PaymentCompleted",
  "occurredAt": "2026-03-13T12:01:15Z",
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "requestId": "8f61fd47-4ec1-4cd2-a3af-5f7b3b70d122",
  "userId": "user-42",
  "walletId": "wallet-42",
  "merchantId": "merchant-77",
  "merchantOrderId": "order-100500",
  "amount": {
    "currency": "RUB",
    "value": 125000
  },
  "providerId": "external-bank",
  "providerTxnId": "prov-90001",
  "status": "COMPLETED",
  "providerStatus": "SUCCESS",
  "createdAt": "2026-03-13T12:00:00Z",
  "finishedAt": "2026-03-13T12:01:15Z"
}
```

Терминальное событие дублирует бизнес-поля платежа, чтобы `Payment Query Service` мог заново построить проекцию только по журналу событий.

## `PaymentFailed`

Источник: `Transaction Service`

Потребители:

- `Wallet Service`
- `Payment Query Service`
- `Notifications Service`

```json
{
  "eventId": "019575e8-7f42-7a63-b730-27c7c4d8b5c0",
  "eventType": "PaymentFailed",
  "occurredAt": "2026-03-13T12:02:00Z",
  "paymentId": "019575e6-5f08-7d34-84c2-d18a55e2d150",
  "requestId": "8f61fd47-4ec1-4cd2-a3af-5f7b3b70d122",
  "userId": "user-42",
  "walletId": "wallet-42",
  "merchantId": "merchant-77",
  "merchantOrderId": "order-100500",
  "amount": {
    "currency": "RUB",
    "value": 125000
  },
  "providerId": "external-bank",
  "providerTxnId": "prov-90001",
  "status": "FAILED",
  "providerStatus": "TIMEOUT",
  "failureReason": "PROVIDER_TIMEOUT",
  "createdAt": "2026-03-13T12:00:00Z",
  "finishedAt": "2026-03-13T12:02:00Z"
}
```

## Соглашения по событиям

- `paymentId` - основной correlation key
- `eventId` - уникальный id события для deduplication
- `requestId` - внешний idempotency key клиента
- `providerId` и `recipientAccount` приходят уже в `PaymentInitiated`, чтобы `Transaction Service` мог вызвать внешнего провайдера без чтения чужой БД
- `providerTxnId` появляется только после инициирования внешней транзакции
- `merchantOrderId` проходит через все business events и может использоваться в read-модели и сверке с мерчантом
- `PaymentCompleted`, `PaymentFailed` и `PaymentExpired` содержат тот же базовый набор бизнес-полей, что и `PaymentInitiated`, чтобы поддерживать replay и восстановление read-модели
- терминальные события после внешнего провайдера публикуются `Transaction Service`; `PaymentExpired` является отдельным защитным событием `Wallet Service` для истёкшего hold до старта внешней части саги

## Идемпотентность подписчиков

- `Wallet Service` dedupe по `paymentId` и текущему terminal state записи в `wallet_transactions`
- `Payment Query Service` dedupe по `eventId`
- `Transaction Service` dedupe входящих `PaymentInitiated` по `paymentId`
