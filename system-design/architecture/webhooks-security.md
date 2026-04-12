# Security: Webhooks and Callback Protection

## Цель

Этот документ описывает защиту входящих webhook / callback от подмены, replay и повторной обработки.

## Базовый поток

1. Внешний провайдер вызывает `POST /api/provider/callbacks/{providerCode}`.
2. `Gateway` проверяет подпись HMAC, timestamp и anti-replay.
3. Только после этого payload попадает в `Callback Service`.
4. `Callback Service` нормализует payload и передаёт его в `Transaction Service`.
5. `Transaction Service` делает идемпотентную фиксацию результата и не публикует terminal event повторно.

## Подпись webhook

### Что подписывается

Подписывается строка:

`X-Timestamp + "\n" + X-Event-Id + "\n" + raw body`

Почему именно так:

- `raw body` защищает содержимое callback-а от подмены
- `timestamp` ограничивает окно жизни запроса
- `eventId` или nonce нужен для anti-replay

### Какие заголовки ожидаем

- `X-Signature`: hex/base64 HMAC
- `X-Timestamp`: время формирования callback-а у провайдера
- `X-Event-Id`: уникальный идентификатор события у провайдера
- `X-Provider-Code`: кто именно отправил callback

### Алгоритм

Используется `HMAC-SHA256`.

На `Gateway`:

1. находится текущий и предыдущий signing secret провайдера
2. пересчитывается `expectedSignature`
3. выполняется constant-time compare
4. при успехе запрос допускается дальше

Поддержка двух секретов нужна для безопасной ротации.

## Anti-replay

### Окно времени

- допустимое окно: `5 минут`
- если `now - X-Timestamp > 5m`, callback отклоняется

### Replay store

Для защиты от повторной доставки используется `Redis`.

Ключ:

`webhook-replay:{providerCode}:{eventId}`

TTL:

- `5-10 минут`, чуть больше окна времени

Поведение:

- если ключ уже существует, `Gateway` возвращает `409` или `202 duplicate-received`
- если ключа нет, он ставится атомарно через `SET NX EX`

## Идемпотентность в Transaction Service

Даже если replay-store временно недоступен или callback дошёл повторно другим путём, `Transaction Service` всё равно остаётся последней защитой.

Используются:

- `provider_callbacks.callback_id`
- `provider_callbacks.dedupe_key`
- проверка terminal state в `payments`

`dedupeKey` строится как:

`providerCode:providerTxnId:providerStatus:eventId`

Если callback уже был обработан:

- статус не меняется повторно
- второй `PaymentCompleted` / `PaymentFailed` не пишется в outbox

## Ошибки и реакции

| Сценарий | Где ловим | Ответ | Что делаем дальше |
|---|---|---|---|
| bad signature | `Gateway` | `401 Unauthorized` | лог + метрика + алерт при всплеске |
| stale timestamp | `Gateway` | `401 Unauthorized` | лог + метрика |
| duplicate eventId | `Gateway` replay-store | `202 Accepted` или `409 Duplicate` | не передаём дальше |
| valid callback, но duplicate dedupeKey | `Transaction Service` | `200 OK` внутрь | не публикуем terminal event повторно |
| invalid payload schema | `Gateway` / `Callback Service` | `400 Bad Request` | payload в `callbacks.invalid.dlq` |
| paymentId not found | `Transaction Service` | `202 Accepted` + manual reconcile | аудит и backoffice-разбор |

## Почему проверка подписи на Gateway

- шум и мусор отсекаются до доменного сервиса
- легче централизовать rate limits и replay protection
- можно переиспользовать плагины / policies для нескольких провайдеров

## Почему идемпотентность всё равно в Transaction Service

`Gateway` отвечает только за периметр. Источник истины по результату внешнего платежа остаётся в write-модели `Transaction Service`, поэтому именно он должен гарантировать, что callback не изменит статус повторно.
