# Архитектура платёжной вертикали банка

## Состав артефактов

- `diagrams/c4-context.puml` - контекст системы
- `diagrams/context-map.puml` - карта bounded context-ов
- `api-contracts.md` - внешние и внутренние API
- `message-contracts.md` - сообщения брокера и соглашения по событиям
- `diagrams/c4-container.puml` - контейнерная диаграмма
- `diagrams/wallet-components.puml` - компоненты `Wallet Service`
- `diagrams/transaction-components.puml` - компоненты `Transaction Service`
- `diagrams/query-components.puml` - компоненты `Payment Query Service`
- `diagrams/sequence-success.puml` - успешный сценарий
- `diagrams/sequence-failure-timeout.puml` - сценарий ошибки и компенсации
- `diagrams/sequence-callback-flow.puml` - поток callback-а провайдера
- `diagrams/sequence-provider-resilience.puml` - таймауты, ретраи, circuit breaker и fallback при сбое провайдера
- `diagrams/sequence-dlq-reprocessing.puml` - повторные ошибки consumer-а и перевод сообщения в DLQ
- `diagrams/sequence-cache-read.puml` - чтение статуса и истории через cache hit/miss
- `diagrams/sequence-observability-flow.puml` - прохождение trace-id, метрик и логов по платёжному потоку
- `diagrams/erd.puml` - схема write/read моделей и outbox-таблиц

## Архитектурный контекст

Документ фиксирует целевую архитектуру платёжной вертикали банка. Задача решения - отделить жизненный цикл платежа, кошельки, антифрод, уведомления и интеграции с `Core Banking (Legacy)` на уровне независимых bounded context-ов, снизить связность между подсистемами и перейти от прямых точечных интеграций к событийной модели.

При проектировании учитываются следующие ограничения:

- высокий объём онлайн-платежей из mobile/web-каналов
- необходимость быстрого ответа пользователю в критическом платёжном пути
- осторожная интеграция с `Core Banking (Legacy)`, который нельзя радикально менять
- требование к трассируемости, идемпотентности и управляемой деградации
- готовность к горизонтальному масштабированию без центрального генератора идентификаторов

## Общий подход

Платёжная вертикаль строится как набор bounded context-ов с явными контрактами и собственными моделями данных. Всё, что влияет на движение денег и результат пользовательского запроса, выполняется синхронно и с жёсткими таймаутами. Всё, что связано с уведомлениями, аналитикой, распространением статусов и интеграциями с нестабильными потребителями, выносится в асинхронный слой через шину событий.

Центральной точкой оркестрации является `Payments Context`: он не хранит баланс и не ведёт бухгалтерский учёт, а управляет жизненным циклом платежа, меняет его статусы и публикует доменные события. `Wallet Context` отвечает за операционный баланс и `hold`-операции. `Anti-Fraud` принимает онлайн-решение до движения денег. `Customer Context` остаётся владельцем KYC и договоров, `Merchant Registry Context` - владельцем конфигурации мерчантов, а `Analytics / DWH Context` - владельцем аналитических витрин и исторических датасетов. `Core Integration / ACL` изолирует legacy core. `Callbacks` и `Notifications` получают события о статусах платежей и не блокируют основной сценарий.

Ниже в документе отдельно разобран один конкретный сценарий внутри этой вертикали: внешний платёж пользователя с кошелька. В нём верхнеуровневый `Payments Context` раскрывается через связку `Orchestrator / API`, `Wallet Service`, `Transaction Service`, `Callback Service` и `Payment Query Service`, на которой дальше показываются `Saga`, `Transactional Outbox`, `CQRS` и обработка callback-ов провайдера.

## Доменная декомпозиция

| Bounded Context | Ответственность | Ключевые сущности | Как интегрируется |
|---|---|---|---|
| `Customer` | клиент, договоры, KYC, продуктовые привязки | `CustomerId`, `ContractId`, `KycStatus` | публикует клиентские события и предоставляет API чтения |
| `Merchant Registry` | договоры мерчантов, callback endpoints, ключи подписи, retry policy | `MerchantId`, `MerchantContractId`, `CallbackEndpoint`, `SigningKeyRef` | предоставляет конфигурацию для `Payments` и `Callbacks` |
| `Wallet` | кошельки, доступный баланс, `hold`, списание, операционные движения | `WalletId`, `HoldId`, `WalletMovementId` | принимает синхронные команды от `Payments`, публикует события изменений баланса |
| `Payments` | создание платежа, маршрутизация, резервы, статусы, оркестрация | `PaymentId`, `PaymentAttemptId`, `PaymentStatus`, `IdempotencyKey` | центральный координатор, владелец доменных событий платежа |
| `Anti-Fraud / Scoring` | онлайн-оценка риска и причины решения | `RiskAssessmentId`, `Decision`, `RiskScore` | получает синхронные запросы на решение; обучение и исторические сигналы вынесены в `Analytics / DWH` |
| `Provider Integration` | адаптеры карточного процессинга, СБП и других платёжных рельс | `ProviderRoute`, `ProviderTransactionId` | скрывает протоколы внешних провайдеров за нормализованным контрактом |
| `Callbacks` | гарантированная доставка статусов внешним мерчантам и внутренним потребителям | `CallbackDeliveryId`, `DeliveryStatus` | читает доменные события и управляет повторными попытками и ограничением скорости доставки |
| `Notifications` | SMS/push/email, шаблоны, настройки, доставка | `NotificationId`, `TemplateId` | подписывается на доменные события и события фрода |
| `Analytics / DWH` | витрины, audit stream, отчётность, датасеты для моделей | `PaymentFact`, `WalletFact`, `RiskFact`, `DeliveryFact` | потребляет доменные события из `Kafka` и владеет аналитическими витринами |
| `Core Banking (Legacy)` | бухгалтерский учёт, GL, регуляторная отчётность | legacy identifiers | не вызывается напрямую из домена, только через ACL |
| `Core Integration / ACL` | трансляция между доменной моделью и legacy core | `AccountingIntent`, `PostingResult`, `LegacyMapping` | анти-коррупционный слой между современной вертикалью и legacy |

### Роли контекстов в платёжном сценарии

- `Customer` даёт `Payments`, `Wallet` и `Anti-Fraud` данные о клиенте, договорах и KYC.
- `Merchant Registry` хранит merchant keys, endpoints и retry policy; его используют `Payments` и `Callbacks`.
- `Payments` задаёт основной поток обработки для `Wallet`, `Anti-Fraud`, `Provider Integration`, `Callbacks`, `Notifications` и аналитических потребителей.
- `Wallet` не знает о деталях провайдеров и core, а отвечает только за доступный баланс и `hold`-семантику.
- `Anti-Fraud` участвует в runtime-контуре только через синхронный вызов `AssessRisk` из `Payments`.
- `Analytics / DWH` потребляет события `Payments`, `Wallet`, `Callbacks` и `Anti-Fraud`, строит витрины и хранит исторические сигналы для отчётности и обучения моделей.
- `Core Banking` изолирован через `Core Integration / ACL`; `Payments` не зависит от legacy-модели напрямую.

## Context Map

Контекстная карта верхнего уровня зафиксирована в текстовом виде ниже, а диаграмма [`context-map.puml`](./diagrams/context-map.puml) в текущем репозитории детализирует runtime-срез сценария внешнего платежа: `API / Orchestration`, `Wallet`, `Transaction`, `Callback`, `Query` и внешний провайдер. Это осознанное сужение: диаграмма показывает именно тот контур, который затем раскрывается на container, component, sequence и ERD-уровне.

Ключевые отношения верхнего уровня:

- `Customer -> Payments`: `Customer/Supplier`, `Published Language` с клиентскими данными и KYC-статусом
- `Merchant Registry -> Payments` и `Merchant Registry -> Callbacks`: `Customer/Supplier`, конфигурация мерчанта, endpoints, ключи подписи и retry policy
- `Payments -> Wallet`: `Customer/Supplier`, синхронные команды `PlaceHold`, `CommitHold`, `ReleaseHold`
- `Payments -> Anti-Fraud`: `Customer/Supplier`, синхронный вызов `AssessRisk -> Decision`
- `Payments -> Callbacks`, `Payments -> Notifications`, `Payments -> Analytics / DWH`: `Published Language`, событие `PaymentStatusChanged`
- `Payments -> Core Integration / ACL`: `Customer/Supplier`, доменный контракт `AccountingIntent`
- `Core Integration / ACL -> Core Banking`: `Conformist`, адаптация к legacy API/протоколам
- `Wallet -> Analytics / DWH` и `Anti-Fraud -> Analytics / DWH`: доменные события для витрин, аудита и обучения моделей

`Anti-Fraud` в runtime-контуре не подписывается напрямую на события `Payments` и `Wallet`. Это сделано специально, чтобы не создавать цикл зависимостей `Payments ⇄ Anti-Fraud`.

- входные данные для онлайн-решения приходят в синхронном вызове из `Payments`, дополнительно используются данные `Customer`
- исторические сигналы и audit stream уходят в `Analytics / DWH`, где используются для витрин и обучения моделей вне критического пути
- потребители решения риска: `Payments`, `Notifications` и, при необходимости, `Case Management`

## Представление системы в C4

### C1: системный контекст

На диаграмме [`c4-context.puml`](./diagrams/c4-context.puml) платёжная платформа показана как единая система в окружении:

- клиент банка и mobile/web-каналы
- карточный процессинг
- СБП
- мерчанты и партнёры
- провайдеры уведомлений
- `Core Banking (Legacy)`

### C2: контейнеры платформы

На уровне целевой платформы container landscape включает:

- `Kong API Gateway`
- `BFF / Mobile API`
- `Customer Service`
- `Merchant Registry Service`
- `Payments Service`
- `Wallet Service`
- `Anti-Fraud Service`
- `Core Integration / ACL`
- `Notifications Service`
- `Callbacks Service`
- `Analytics / DWH`
- `Kafka`
- `RabbitMQ`
- `Customer DB`
- `Merchant Registry DB`
- `Payments DB`
- `Wallet DB`
- `Analytics Storage`

В текущем комплекте диаграмм [`c4-container.puml`](./diagrams/c4-container.puml) детализирует упрощённый сценарий внешнего платежа: `API Gateway`, `Orchestrator / API`, `Wallet Service`, `Transaction Service`, `Callback Service`, `Payment Query Service`, `Notifications Service`, `Kafka`, `RabbitMQ`, `Redis` и стек наблюдаемости. Остальные контексты верхнего уровня остаются на уровне доменной декомпозиции и системного контекста.

Принципы декомпозиции на контейнеры:

- внешний трафик идёт через gateway
- синхронный внутренний RPC используется только там, где решение влияет на деньги и пользовательский ответ
- распространение статусов и побочные процессы идут через события
- доставка, повторы, ограничение скорости и фоновые задания живут отдельно от журнала доменных событий

## Сквозной сценарий выполнения платежа на уровне вертикали

1. Клиент создаёт платёж через mobile/web-канал.
2. Запрос проходит через `Kong API Gateway` в `BFF`, затем в `Payments`.
3. `Payments` валидирует идемпотентность и запрашивает решение у `Anti-Fraud`.
4. При решении `ALLOW` сервис `Payments` синхронно вызывает `Wallet` для `PlaceHold`.
5. После успешного `hold` платёж передаётся в `Provider Integration`.
6. При подтверждении исполнения `Payments` инициирует `CommitHold` и переводит платёж в бизнес-статус `CAPTURED` или `SETTLED`.
7. `Payments` публикует `PaymentStatusChanged` в `Kafka`.
8. `Notifications`, `Callbacks` и `Analytics / DWH` потребляют событие независимо друг от друга.
9. Для бухгалтерского отражения `Payments` публикует `AccountingRequested`; `Core Integration / ACL` обрабатывает это асинхронно и возвращает `AccountingPosted` или `AccountingFailed`.

В результате синхронными остаются только денежный путь и точки принятия решения. Интеграции с отчётностью, доставкой callbacks и аналитикой работают независимо и допускают отложенную согласованность.

## Коммуникационный контракт

| Взаимодействие | Режим | Технология | Почему так | Консистентность |
|---|---|---|---|---|
| Клиент -> Gateway -> BFF/Payments | синхронно | `HTTPS/REST` | внешний API должен быть простым для каналов, совместимым с auth/WAF/rate-limit и удобным для идемпотентных запросов | пользователь получает немедленный результат приёма платежа |
| `Payments -> Customer` | синхронно | `gRPC/REST` | перед созданием и обработкой платежа нужны KYC, договор и клиентские атрибуты из единого источника | консистентная проверка входных данных на момент операции |
| `Callbacks -> Merchant Registry` | синхронно | `gRPC/REST` | перед доставкой webhook нужны endpoint, ключ подписи и retry policy из реестра мерчантов | консистентная конфигурация доставки |
| `Payments -> Wallet` | синхронно | `gRPC` | `hold` и `commit` являются блокирующим денежным шагом, поэтому здесь нужны низкая латентность и строгий контракт ошибок | строгая консистентность по доступному балансу |
| `Payments -> Anti-Fraud` | синхронно | `gRPC` | решение `ALLOW / DENY / CHALLENGE` нужно до движения денег | строгая консистентность для решения по операции |
| `Payments -> Provider Integration` | синхронно + асинхронный статус | `gRPC/REST` внутри, HTTP/webhook наружу | внутри платформы нужен единый контракт, а различия провайдеров должны быть скрыты адаптером | часть статусов может приходить позже |
| `Payments -> Core Integration / ACL` | асинхронно | `Kafka` событие + при необходимости `RabbitMQ` job | legacy core медленный и хрупкий, его нельзя тянуть в пользовательский путь | `POSTING_PENDING` допустим как временный статус |
| `Payments -> Notifications` | асинхронно | `Kafka` event | уведомление не должно блокировать платёж и должно переживать повторы | допустима отложенная согласованность |
| `Payments -> Callbacks` | асинхронно | `Kafka` event + `RabbitMQ` задачи доставки | событие нужно раздать нескольким потребителям, а доставку во внешние точки интеграции надо контролировать отдельно | допустима отложенная согласованность |
| `Payments -> Analytics / DWH` | асинхронно | `Kafka` | аналитике нужен повторный проигрыш событий, потоковая обработка и долгоживущий журнал | допустима отложенная согласованность |
| `Wallet -> Analytics / DWH` | асинхронно | `Kafka` | изменения баланса и `hold`-события нужны для витрин, аудита и построения исторических датасетов | допустима отложенная согласованность |

### Почему REST снаружи и gRPC внутри

Внешний API остаётся `REST/HTTPS`, потому что он совместим с типичной внешней инфраструктурой банка: OIDC, JWT, mTLS, аудит, API management, ограничение скорости и удобная отладка каналов и партнёров. Внутренние вызовы между доменными сервисами, где важны небольшая задержка и строгое контрактное поведение, переводятся на `gRPC`.

### Где допустима отложенная согласованность

- уведомления клиенту
- webhooks мерчантам
- аналитика и DWH
- бухгалтерское отражение через legacy core, если бизнес допускает промежуточный статус `POSTING_PENDING`
- сигналы для обучения антифрода, если они собираются через `Analytics / DWH`

### Где eventual consistency недопустима

- решение `ALLOW / DENY / CHALLENGE` по конкретному платежу
- операции `PlaceHold`, `CommitHold`, `ReleaseHold`
- идемпотентная фиксация факта создания платежа

## Событийная модель

Доменные события являются основным способом передачи статусов и бизнес-фактов между контекстами. Ниже приведён пример базового события платформы:

```json
{
  "event_id": "01956c35-c4d4-7b73-b1f1-5f9fd4b0dd61",
  "event_type": "PaymentStatusChanged",
  "occurred_at": "2026-03-07T10:45:21Z",
  "payment_id": "01956c35-c4c0-7b16-94fd-196b6b9a6f6e",
  "payment_attempt_id": "01956c35-c4c7-7987-8e48-fc7d38aa90d5",
  "correlation_id": "01956c35-c49b-7f1d-8d66-12f6d921a0bf",
  "causation_id": "01956c35-c4a7-7fd6-8f9b-78abbb6f10aa",
  "status": "CAPTURED",
  "merchant_id": "merchant-42",
  "amount": {
    "currency": "RUB",
    "value": 125000
  }
}
```

Потребители события:

- `Notifications` отправляет push/SMS/email
- `Callbacks` формирует webhook-доставку для мерчанта
- `Analytics / DWH` обновляет витрины, транзакционные ленты и наборы данных для аналитики

Для публикации событий предполагается паттерн `transactional outbox`, чтобы не терять сообщение между транзакцией в БД и отправкой в брокер.

В детальном сценарии ниже эта модель конкретизируется через события `PaymentInitiated`, `PaymentCompleted` и `PaymentFailed`.

## Зоны ответственности Kafka и RabbitMQ

На уровне всей вертикали возможно разделение ролей между двумя брокерами: `Kafka` работает как доменная шина и долговременный журнал событий, а `RabbitMQ` используется там, где важнее операционное исполнение задач, TTL, DLQ, backpressure и приоритеты.

| Поток / сценарий | Брокер | Тип | Почему выбран |
|---|---|---|---|
| `PaymentStatusChanged -> Notifications` | `Kafka` | event | событие статуса должно быть доступно нескольким подписчикам, сохраняться и переигрываться |
| `PaymentRequested -> Anti-Fraud` | нет + `Kafka` | синхронная команда + event | решение нужно получить синхронно по RPC, а audit trail и исторические сигналы удобно публиковать в журнал событий |
| Доменные события `Payments/Wallet/Fraud -> Analytics / DWH` | `Kafka` | event | высокий throughput, долговременное хранение, повторный проигрыш и построение витрин |
| `AccountingRequested -> Core ACL` | `Kafka`, опционально `RabbitMQ` | event + job | событие фиксирует доменный факт, job-очередь может ограничивать нагрузку на legacy |
| Доставка callback-ов мерчантам | `Kafka` + `RabbitMQ` | event + job | событие приходит из Kafka, а конкретные задачи доставки требуют повторов, TTL и ограничения скорости по мерчанту |
| Генерация отчётов и batch reconciliation | `RabbitMQ` | job | это фоновые задачи, а не доменные факты, здесь важны worker-пулы и управление нагрузкой |

### Почему не только Kafka

Kafka хорошо решает задачу журнала событий, но хуже подходит как рабочая очередь для операционной доставки с TTL, задержками, ручными повторами и ограничением скорости по потребителям. Поэтому `Callbacks` и batch-процессы выносятся в `RabbitMQ`, а доменная история остаётся в `Kafka`.

В упрощённом детальном сценарии одного `Kafka` достаточно, чтобы показать `Saga`, `Transactional Outbox`, `CQRS` и обработку callback-ов. Для фоновых задач, retry и DLQ поверх этого добавлен `RabbitMQ`, а `Kafka` остаётся доменной шиной и журналом событий.

## Внешний контур и API Gateway

На входе используется `Kong API Gateway`.

Задачи шлюза в данной архитектуре:

- OIDC/JWT-аутентификация пользовательских и партнёрских запросов
- локальная проверка JWT по закэшированным `JWKS`; `IdP` не находится в критическом пути каждого запроса
- `mTLS` для внешних интеграций и мерчантов
- rate limiting по клиенту, мерчанту, API key и IP
- защита от невалидных или шумных клиентов до входа в доменные сервисы
- маршрутизация в `BFF`, `Payments`, `Wallet` и публичный контур `Callbacks`
- генерация и проброс `X-Correlation-Id` / `X-Request-Id`
- централизованный access-log, метрики и трассировка

`Kong` выбран потому, что для банковского пограничного слоя важны зрелые плагины безопасности, производительность на базе `Nginx`, поддержка `OIDC`, `mTLS`, `ACL`, rate-limiting и хорошая встраиваемость в Kubernetes и стек наблюдаемости. Проверка JWT выполняется локально на gateway по периодически обновляемым `JWKS`, поэтому `IdP` не участвует в обработке каждого запроса. Альтернативы вроде `Spring Cloud Gateway` и `Traefik` возможны, но для высоконагруженного внешнего контура и богатой плагинной модели в этом кейсе `Kong` выглядит практичнее.

## Схема идентификаторов

### Канонические идентификаторы

Новая вертикаль использует `UUIDv7` как основной формат глобальных идентификаторов:

- `PaymentId`
- `PaymentAttemptId`
- `HoldId`
- `WalletMovementId`
- `EventId`
- `CallbackDeliveryId`
- `CorrelationId`
- `CausationId`

Отдельно хранится `IdempotencyKey` как бизнес-ключ клиента или мерчанта. Его нельзя подменять `UUIDv7`, потому что семантика идемпотентности определяется внешним запросом, а не только фактом существования сущности.

### Почему выбран UUIDv7

`UUIDv7` обеспечивает глобальную уникальность без централизованного генератора, остаётся стандартным форматом UUID и при этом сортируется по времени. Для write-heavy таблиц он лучше случайного `UUIDv4`, потому что вставки в индекс происходят более локально и ближе по поведению к `sequence`. По сравнению со `Snowflake`, `UUIDv7` проще операционно: не нужно управлять `worker_id` и жизненным циклом генератора, а формат удобнее для внешних API, логов и ключей сообщений.

### Использование по слоям

- в `Payments DB`: `payment_id` является первичным ключом и ключом агрегации платежа
- в `Wallet`: `payment_id` связывает hold и списание с бизнес-операцией
- в `Kafka`: ключом partition обычно является `payment_id`, чтобы сохранить порядок событий одного платежа
- в `RabbitMQ`: `payment_id` и `callback_delivery_id` участвуют в дедупликации выполнения задач
- в логах и трассировке: `correlation_id` создаётся на edge, `payment_id` появляется после `CreatePayment`
- в callback-ах мерчантам: платформа возвращает `payment_id` как канонический идентификатор и `merchant_ref` как внешний корреляционный ключ партнёра

### Переход от sequence к UUIDv7

Исторические numeric-идентификаторы не исчезают мгновенно. Для совместимости в новой вертикали сохраняются поля `legacy_payment_id`, `core_operation_id`, `provider_transaction_id`, `merchant_ref`. Внутренний доменный контракт и все новые события используют только `payment_id: UUIDv7`; legacy-id остаются атрибутами интеграции, а не главным ключом домена.

Практический путь миграции - стратегия двойных идентификаторов: новые платежи получают `UUIDv7` сразу, а старые записи остаются в legacy и отображаются через сопоставление в `ACL` или через отдельную read-модель. Полный backfill возможен, но это дорогая миграция с риском для совместимости и окон обслуживания. На переходе внешние API версии `v2` должны работать с `payment_id`, а старые `v1` могут продолжать использовать числовой идентификатор.

С точки зрения производительности `UUIDv7` тяжелее `bigint sequence` по размеру индекса, но даёт достаточно локальные вставки и снимает ограничение на централизованную генерацию. Для микросервисной платёжной вертикали такой компромисс выглядит приемлемым.

## Детальный сценарий обработки внешнего платежа

Ниже тот же контур раскрывается уже на уровне упрощённой микросервисной реализации, для которой в репозитории есть container, component, sequence, API, message contracts и ERD. Этот runtime-срез ограничен внешним платежом пользователя с кошелька и не пытается моделировать всю вертикаль на одном уровне детализации.

## Границы сервисов в детальном сценарии

| Сервис | Ответственность | Хранилище | Роль в процессе |
|---|---|---|---|
| `Orchestrator / API` | принимает внешние команды и читает статус из query-модели | без собственной бизнес-БД | входная точка для клиента |
| `Wallet Service` | проверка баланса, резерв, списание, компенсация | `Wallet DB` | владелец денежного состояния |
| `Transaction Service` | техническое состояние платежа, интеграция с провайдером, таймауты | `Transaction DB` | владелец статуса внешней транзакции |
| `Callback Service` | приём callback-ов провайдера, проверка подписи, адаптация внешнего контракта | без собственной write-модели платежа | изолирует внешний callback-интерфейс |
| `Payment Query Service` | денормализованные проекции для чтения и cache invalidation | `Query DB` + `Redis` | CQRS read-модель |
| `Notifications Service` | отправка SMS / push / email, retry и DLQ для внешних notification providers | operational queues | побочный асинхронный контур |
| `Messaging` | доставка доменных событий, retry jobs и DLQ | `Kafka` + `RabbitMQ` | асинхронный канал между write/read частями и operational processing |
| `External Provider` | внешний исполнитель платежа | внешняя система | возвращает финальный результат |

Ключевое правило: `Wallet Service` владеет деньгами, `Transaction Service` владеет техническим статусом внешнего платежа, а `Payment Query Service` владеет только read-проекцией. `Callback Service` не меняет бизнес-состояние кошелька и не становится источником истины.

## Выбранный стиль саги

Сага реализована как распределённая хореография с чётко определёнными владельцами локальных транзакций:

1. `Orchestrator` вызывает `Wallet Service` командой `reserveFunds`.
2. `Wallet Service` выполняет локальную транзакцию, резервирует деньги и пишет `PaymentInitiated` в outbox.
3. Outbox-процесс публикует событие в `Kafka`.
4. `Transaction Service` получает `PaymentInitiated`, создаёт у себя техническую запись платежа и отправляет запрос провайдеру.
5. После callback-а или таймаута `Transaction Service` переводит платёж в терминальный статус и пишет `PaymentCompleted` или `PaymentFailed` в outbox.
6. `Wallet Service` потребляет терминальное событие: при успехе делает `commit`, при ошибке или таймауте делает `release`.
7. `Payment Query Service` обновляет проекцию только из событий.

Отдельный централизованный координатор саги не используется. `paymentId` выступает корреляционным ключом, а сами сервисы знают только свой локальный шаг и следующую реакцию на событие.

### Почему выбрана хореография, а не оркестратор как координатор

- локальные транзакции и outbox лучше сочетаются с событийной моделью
- `Wallet Service` и `Transaction Service` остаются слабо связаны
- `Orchestrator` не хранит состояние распределённой транзакции и не становится точкой отказа; идемпотентный mapping `requestId -> paymentId` живёт в `Wallet Service`
- read-модель естественно обновляется теми же событиями, что двигают сагу

## Write-модели и read-модель

### Wallet Service

`Wallet Service` хранит:

- `wallets` - состояние баланса
- `wallet_transactions` - одна mutable-запись по каждому `paymentId`, отражающая жизненный цикл денежной операции в кошельке и mapping внешнего `requestId` на внутренний `paymentId`
- `wallet_outbox` - событие `PaymentInitiated`

Локальная транзакция:

1. проверить доступный баланс
2. по `requestId` найти существующую запись или при первом вызове создать новую запись `wallet_transactions` со статусом `RESERVED`
3. уменьшить `available_amount`, увеличить `reserved_amount`
4. вставить `PaymentInitiated` в `wallet_outbox`

На финальное событие `PaymentCompleted` или `PaymentFailed` сервис реагирует другой локальной транзакцией:

- `COMPLETED` -> уменьшает `reserved_amount`, фиксирует окончательное списание и помечает запись как `COMPLETED`
- `FAILED` / `TIMEOUT` -> уменьшает `reserved_amount`, возвращает деньги в `available_amount` и помечает запись как `CANCELLED`

`wallet_transactions` в этой схеме не является append-only журналом отдельных резервов и финализаций. Это одна write-запись платежа внутри `Wallet Service`, которая меняет статус от `RESERVED` к терминальному состоянию.

Важно: статус `wallet_transactions` не равен публичному статусу платежа в read-модели. `Wallet Service` фиксирует внутреннее бухгалтерское состояние денег (`RESERVED`, `COMPLETED`, `CANCELLED`), тогда как внешний жизненный цикл платежа (`COMPLETED`, `FAILED`, `TIMEOUT`) принадлежит `Transaction Service`.

Именно `Wallet Service` хранит идемпотентный mapping `requestId -> paymentId`. Поэтому `Orchestrator` может оставаться stateless: при каждом `POST /api/payments` он передаёт `requestId` и бизнес-payload в `Wallet Service`, а тот либо создаёт новый платёж, либо возвращает уже существующий `paymentId`.

### Transaction Service

`Transaction Service` хранит:

- `payments` - техническое состояние внешнего платежа, маршрут к провайдеру, реквизиты получателя и merchant metadata, нужные для terminal events
- `provider_callbacks` - таблицу дедупликации callback-ов
- `payment_outbox` - терминальные события `PaymentCompleted` и `PaymentFailed`

После `PaymentInitiated` сервис:

1. создаёт техническую запись `payments` со статусом `PROVIDER_PENDING`
   и сохраняет `providerId`, реквизиты получателя и `merchantOrderId`
2. отправляет запрос провайдеру и передаёт `paymentId` как внешний reference (`merchantReference` / `externalId`)
3. ждёт callback или срабатывания таймаута

После callback-а или таймаута:

1. переводит `payments` в `COMPLETED` / `FAILED` / `TIMEOUT`
2. пишет `PaymentCompleted` или `PaymentFailed` в `payment_outbox`
3. outbox-процесс публикует результат в `Kafka`

### Payment Query Service

`Payment Query Service` хранит только денормализованные read-проекции:

- список платежей пользователя
- текущий статус по `paymentId`
- агрегированные поля для UI: сумма, пользователь, итоговый статус, статус провайдера, timestamps, merchant info, `merchantOrderId`
- `query_processed_events` - служебную дедупликацию по `eventId`

Read-модель обновляется только событиями:

- `PaymentInitiated`
- `PaymentCompleted`
- `PaymentFailed`

Каждое событие в потоке платежей несёт минимально достаточный набор бизнес-полей для восстановления `payment_view` без чтения из write-БД. `PaymentInitiated` дополнительно несёт `providerId`, реквизиты получателя и `merchantOrderId`, чтобы `Transaction Service` мог вызвать провайдера без обращения к чужой write-модели. Терминальные события повторяют ключевые атрибуты платежа: `walletId`, `merchantId`, `merchantOrderId`, `amount`, `currency`, `requestId`, `userId`, а также технические поля провайдера и timestamps.

События публикуются в единый Kafka-топик `payments.events` с partition key = `paymentId`. Это даёт стабильный порядок событий в рамках одного платежа и упрощает replay read-модели.

`Payment Query Service` проецирует внешний статус платежа из домена `Transaction Service`. Поэтому после компенсации в `Wallet Service` локальная запись может иметь статус `CANCELLED`, а пользовательская read-модель при этом показывает `FAILED` с причиной ошибки провайдера. Это не конфликт, а отражение разных моделей ответственности.

Для read-модели выбран `Postgres`, потому что запросы в этом контуре операционные и предсказуемые:

- история платежей пользователя
- статус конкретного платежа
- фильтрация по статусу и времени

`Elastic` и `ClickHouse` здесь были бы избыточны: полнотекст и тяжёлая аналитика не являются основным требованием read-контура.

## Transactional Outbox

### Где используется

- в `Wallet Service` для `PaymentInitiated`
- в `Transaction Service` для `PaymentCompleted` и `PaymentFailed`

### Почему выбран polling, а не CDC

В этой схеме выбран `polling publisher`, потому что поток событий здесь предсказуемый: на один платёж приходится одно исходящее событие из `Wallet Service` и одно терминальное событие из `Transaction Service`. Для такого профиля нагрузки достаточно периодически читать outbox по индексу `status + created_at` и публиковать новые записи пачками.

Задержка в несколько сотен миллисекунд или единицы секунд между коммитом локальной транзакции и публикацией события для этого процесса допустима. Сага от этого не ломается: деньги уже зарезервированы локально, `Transaction Service` стартует почти сразу после публикации, а read-модель по условию задачи и так eventual consistent.

`CDC` через `Debezium` имеет смысл в другом режиме: при большом объёме событий, более жёстких требованиях к задержке публикации и готовности поддерживать отдельный контур репликации изменений (`Debezium` / `Kafka Connect`, коннекторы, WAL/binlog). Для текущей схемы это добавляет инфраструктуру, но не даёт существенного выигрыша по сравнению с polling publisher.

### Как достигается атомарность

Атомарность достигается тем, что каждая бизнес-операция и запись события в outbox делаются в пределах одной БД-транзакции:

- `Wallet Service`: резерв + запись `PaymentInitiated`
- `Transaction Service`: смена статуса платежа + запись `PaymentCompleted` или `PaymentFailed`

Если транзакция откатывается, то не фиксируется ни бизнес-состояние, ни outbox-запись. Если транзакция закоммичена, outbox publisher гарантированно дочитает запись и опубликует её в брокер.

## Идемпотентность

### Wallet Service

Защита от дублей строится на уровне БД:

- `wallet_transactions.payment_id` уникален для денежной операции
- `wallet_transactions.request_id` уникален для внешней команды пользователя
- `wallet_transactions.request_fingerprint` хранит отпечаток нормализованного payload для проверки, что повторный `requestId` пришёл с теми же параметрами
- обработка терминального события проверяет, не находится ли транзакция уже в терминальном состоянии

Источник истины для идемпотентности: `Postgres`, без отдельного `Redis`.

Повторная команда `reserveFunds` с тем же `requestId`:

- с тем же нормализованным payload не создаёт второй резерв и возвращает тот же `paymentId`
- с другим payload отклоняется как `409 Conflict`

Именно здесь замыкается идемпотентность внешнего `POST /api/payments`: `Orchestrator` не держит собственное состояние, а полагается на `Wallet Service`, который физически хранит mapping `requestId -> paymentId` и возвращает уже созданный платёж при retry.

### Transaction Service

Защита от дублей:

- `payments.payment_id` уникален, поэтому повторный `PaymentInitiated` не вызовет провайдера второй раз
- `provider_callbacks.callback_id` уникален как внутренний идентификатор callback-а
- `provider_callbacks.dedupe_key` уникален и защищает от повторной обработки одного и того же callback-а даже если внешний `provider_event_id` отсутствует
- если callback повторный, сервис не публикует второе терминальное событие

Источник истины для идемпотентности: `payments` и `provider_callbacks` в `Postgres`.

## Таймауты и компенсация

`Transaction Service` хранит `expires_at` для каждого платежа в статусе `PROVIDER_PENDING`.

Политика таймаута:

- стандартный таймаут ответа провайдера: `2 минуты`
- фоновый `Timeout Monitor` проверяет pending-платежи каждые `30 секунд`
- если callback не пришёл вовремя, сервис помечает платёж как `TIMEOUT`, пишет `PaymentFailed` в outbox и запускает компенсацию через событие

Компенсация выполняется в `Wallet Service` после получения `PaymentFailed`:

- резерв снимается
- доступный баланс восстанавливается
- статус записи в `wallet_transactions` переводится в `CANCELLED`

Если поздний callback от провайдера приходит после таймаута, `Transaction Service` считает его дубликатом или конфликтующим поздним сигналом, сохраняет для аудита, не переоткрывает завершённую сагу автоматически и передаёт случай в manual reconcile / backoffice-разбор.

## Callback Service

`Callback Service` - отдельный входной адаптер внешнего мира.

Он делает только три вещи:

1. принимает callback через gateway
2. валидирует подпись, извлекает `paymentId` из внешнего reference, который провайдер вернул в callback, и нормализует payload
3. формирует `dedupeKey` и передаёт результат в `Transaction Service` через внутренний REST endpoint `/internal/provider-results`

Отдельная lookup-БД для `Callback Service` не нужна: `Transaction Service` заранее передаёт внутренний `paymentId` провайдеру как внешний идентификатор операции, а callback возвращает этот же reference обратно.

`Callback Service` не:

- меняет баланс кошелька
- публикует финальное терминальное событие
- принимает бизнес-решение о завершении платежа

Это важно, потому что источником истины по исходу внешнего платежа остаётся `Transaction Service`.

## API и запросы в read-модель

Внешние чтения идут только в `Payment Query Service` через `Orchestrator`:

- `GET /api/payments/{paymentId}` -> текущий статус платежа
- `GET /api/users/{userId}/payments` -> история платежей пользователя

Write-команды идут в write-сервисы:

- `POST /api/payments` -> старт саги через `Wallet Service`
- `reserveFunds` приходит синхронно от `Orchestrator`
- внутренние команды `commitFunds` / `releaseFunds` семантически принадлежат `Wallet Service`, но в основном runtime flow запускаются consumer-ом по событиям `PaymentCompleted` и `PaymentFailed`, а не прямым REST-вызовом из другого сервиса

Такое разделение и образует `CQRS`: write-сервисы работают с собственными write-моделями, а чтения обслуживаются отдельной read-моделью.

## Последовательность выполнения платежа

### Успешный сценарий

1. Клиент вызывает `POST /api/payments`.
2. `Orchestrator` передаёт `requestId` и payload в `Wallet Service: reserveFunds`.
3. `Wallet Service` резервирует деньги и публикует `PaymentInitiated`.
4. `Transaction Service` получает событие, создаёт технический платёж и отправляет запрос провайдеру.
5. Провайдер шлёт callback в `Callback Service`.
6. `Callback Service` передаёт результат в `Transaction Service`.
7. `Transaction Service` пишет `PaymentCompleted` в outbox и публикует терминальное событие.
8. `Wallet Service` фиксирует списание.
9. `Payment Query Service` обновляет проекцию.

### Неуспешный сценарий

1. Резервирование проходит успешно.
2. `Transaction Service` отправляет запрос провайдеру.
3. Провайдер отвечает ошибкой или не отвечает до `expires_at`.
4. `Transaction Service` публикует `PaymentFailed`.
5. `Wallet Service` выполняет компенсацию: снимает резерв и возвращает деньги.
6. `Payment Query Service` обновляет статус в read-модели.

## Надёжность, масштабирование и наблюдаемость поверх Saga / Outbox / CQRS

Этот слой не меняет доменную модель платёжного процесса. Поверх уже существующей связки `Saga + Transactional Outbox + CQRS` добавляется эксплуатационная часть: таймауты, ретраи, circuit breaker, bulkhead, rate limiting, fallback, DLQ, cache и наблюдаемость. Денежный инвариант остаётся прежним: только `Wallet Service` меняет деньги, только `Transaction Service` принимает решение по внешнему результату платежа, а все побочные процессы управляются отдельно.

## Resilience-политики

### Политики по взаимодействиям

| Взаимодействие | Таймаут | Retries | Circuit Breaker | Bulkhead | Rate Limit | Fallback | Обоснование |
|---|---|---|---|---|---|---|---|
| `Orchestrator -> Wallet Service` (`reserveFunds`) | `500 ms` | `1` безопасный retry только на network timeout, потому что есть `requestId` | нет отдельного CB, fail-fast на уровне HTTP client | отдельный пул исходящих соединений к `Wallet` | внешний лимит ставится на `Gateway` | нет, если `Wallet` недоступен, create payment завершается ошибкой | денежный шаг должен быть быстрым и определённым |
| `Orchestrator -> Payment Query Service` | `200 ms` | `1` retry с jitter | да, короткий CB на чтениях | отдельный read-pool | лимиты на `Gateway` по пользователю и клиентскому приложению | возврат краткоживущего stale cache из `Redis`, если read DB временно недоступна | чтение должно деградировать мягко и не влиять на деньги |
| `Wallet Service -> Kafka` через outbox publisher | poll interval `200-500 ms` | retry публикации до `N` попыток с backoff | нет отдельного CB, но есть остановка publisher-а и алертинг | отдельный worker pool publisher-а | не требуется | запись остаётся в outbox до успешной публикации | outbox уже даёт атомарность, задача publisher-а - надёжно доставить событие |
| `Transaction Service -> External Provider` | connect `300 ms`, response `2 s` | `2` retry по timeout/`5xx` с exponential backoff и jitter | да, open при высокой доле ошибок или timeout burst; half-open пробует ограниченное число запросов | отдельный HTTP client pool и worker pool на провайдера | локальный limiter по провайдеру + gateway limit на внешний вход | запись остаётся в `PROVIDER_PENDING`, ставится job в `provider.retry`, пользователь видит платёж как processing | внешний провайдер - самый нестабильный участок системы |
| `Wallet / Payments -> Core Integration / ACL` | `1 s` | только для безопасных read/check запросов; без слепых retry для posting | да | отдельный пул и очередь в ACL | локальные лимиты на legacy | `POSTING_PENDING` и асинхронный догон через очередь | legacy не должен ломать пользовательский путь |
| `Notifications Service -> SMS/email/push providers` | `1 s` | до `5` попыток с exponential backoff | да, отдельный CB на каждого провайдера | worker pool per provider | лимиты по провайдеру и шаблону рассылки | deferred retry в очереди, затем `notifications.dlq` | уведомления важны, но не должны мешать платежу |
| `Callback Service -> Transaction Service` | `300 ms` | `2` retry на сетевые ошибки | короткий CB | отдельный internal REST pool | лимит на callback endpoint в gateway | invalid callback уходит в `callbacks.invalid.dlq` | защищаем внутренний write-контур от шторма callback-ов |

### Где именно применяются паттерны

- `Timeouts` ограничивают синхронные зависимости в критическом пути и не дают внешним системам держать ресурсы бесконечно.
- `Retries` применяются только к сетевым и временным ошибкам; на необратимые бизнес-ошибки повтор не запускается.
- `Circuit Breaker` стоит на вызовах провайдера, `PaymentQueryService`, `Core Integration / ACL` и внешних notification providers.
- `Bulkhead` разделяет пулы соединений и worker-ы: отдельно для `Wallet`, отдельно для `Query`, отдельно для каждого платёжного провайдера и notification provider.
- `Rate Limit` ставится на `Gateway` для клиентского входа и локально в `Transaction Service` / `Notifications Service` для внешних провайдеров.
- `Fallback` допускается только там, где он не нарушает денежный инвариант: чтения могут вернуть stale cache, а внешний платёж может быть переведён в `PROVIDER_PENDING` с отложенной обработкой. Для reserve/commit/release fallback не используется.

## Очереди, DLQ и backpressure

### Основные потоки и DLQ

| Поток / сценарий | Брокер | Тип | Есть DLQ | Обработка DLQ / комментарий |
|---|---|---|---|---|
| `PaymentInitiated -> Transaction Service` | `Kafka` | event | да, `payments.transaction.dlq` | ручной re-drive после разбора payload / бага consumer-а |
| `PaymentCompleted / PaymentFailed -> Wallet Service` | `Kafka` | event | да, `payments.wallet.dlq` | после `N` неуспешных попыток событие уходит в DLQ, создаётся алерт и задача на re-drive |
| `PaymentInitiated / PaymentCompleted / PaymentFailed -> Query Service` | `Kafka` | event | да, `payments.query.dlq` | повторная проекция или ручной replay из журнала |
| `Provider retry job` | `RabbitMQ` | job | да, `provider.retry.dlq` | ручной разбор, если провайдер долго недоступен или payload неконсистентен |
| `Notification dispatch` | `RabbitMQ` | job | да, `notifications.dlq` | повтор, ограничение скорости, ручной re-drive для долгих отказов |
| `Invalid provider callback` | `RabbitMQ` | command / job | да, `callbacks.invalid.dlq` | payload сохраняется для аудита и ручной проверки подписи / маппинга |

### Backpressure и изоляция потоков

- `Kafka` используется для доменных событий и replay. Конкурентность consumer-ов ограничивается числом partitions и consumer group-ами.
- `RabbitMQ` используется для операционных очередей: `provider.retry`, `notifications.dispatch`, `*.dlq`.
- тяжёлые и медленные процессы отделены от доменных событий: retry платёжного провайдера и рассылка уведомлений не блокируют `payments.events`
- у consumer-ов задаются `max concurrency`, `prefetch` и верхние лимиты на reprocessing batch size
- DLQ не переигрывается автоматически бесконечно; после заданного числа попыток событие уходит в отдельный контур разбора

### Как работает fallback при проблемах с провайдером

Если провайдер отвечает медленно или серия вызовов начинает завершаться timeout/`5xx`, `Transaction Service` сначала делает ограниченные retry с backoff. Если лимит попыток исчерпан и breaker открывается, сервис не публикует терминальный `PaymentFailed` сразу. Вместо этого он сохраняет локальный статус `PROVIDER_PENDING`, ставит retry job в `RabbitMQ` и переводит обработку в асинхронный режим. Только когда истекает общее окно ожидания и повторные попытки не помогли, срабатывает `Timeout Monitor`, публикуется `PaymentFailed`, а `Wallet Service` снимает резерв.

## Кэширование

### Что кэшируем

- `GET /api/payments/{paymentId}` - быстрый статус конкретного платежа
- `GET /api/users/{userId}/payments` - история платежей пользователя и первая страница списка
- справочные данные, которые не участвуют напрямую в денежном инварианте: merchant profile, routing hints, notification templates

### Что не кэшируем грубо

- баланс кошелька и состояние резервов как источник истины
- результат `reserveFunds`, `commitFunds`, `releaseFunds`
- terminal state платежа до того, как он зафиксирован в write-модели

### Выбранные стратегии

- для `Payment Query Service` используется `Cache-Aside` через `Redis`: при cache hit ответ возвращается сразу, при miss данные читаются из `Query DB`, после чего результат кладётся в cache с коротким TTL
- для справочных данных мерчанта и шаблонов уведомлений допустим `Read-Through` или локальный cache с коротким TTL
- `Write-Through` допускается только для небольших справочных данных, где важно, чтобы cache и store менялись вместе
- `Write-Behind` для денег и статусов платежа не используется: отложенная запись в хранилище создаёт риск потерять актуальное состояние

Для пользовательских чтений достаточно короткого TTL: `10-15 секунд` для статуса и `30-60 секунд` для истории. Дополнительно при приходе terminal event `Payment Query Service` инвалидирует соответствующий cache key и обновляет значение заново.

## Observability: метрики, логи, трейсы, SLI / SLO

### Стек наблюдаемости

- `Prometheus` - сбор и хранение метрик
- `Grafana` - дашборды и алерты
- `Grafana Alloy` - сбор метрик, логов и трейсов с сервисов и хостов
- `Loki` - централизованные логи
- `Tempo` - распределённый трейсинг через OpenTelemetry

### Какие метрики собираем

- `API Gateway / Orchestrator`: RPS, latency, доля `2xx/4xx/5xx`, rate-limit rejects
- `Wallet Service`: reserve/commit/release latency, number of insufficient funds, terminal event processing failures, outbox lag
- `Transaction Service`: provider call latency, timeout count, retry count, circuit breaker state, pending payments count, outbox lag
- `Callback Service`: callback throughput, invalid signature count, normalization failures, callback to internal API latency
- `Payment Query Service`: cache hit ratio, query latency, consumer lag, projection update failures
- `Kafka`: consumer lag, publish/consume throughput, DLQ growth
- `RabbitMQ`: queue depth, retry queue age, DLQ size, consumer utilization
- внешний провайдер: success rate, error rate, p95 latency, timeout rate

### SLI / SLO

| SLI | SLO | Где меряем |
|---|---|---|
| Успешность `createPayment` без `5xx` | `>= 99.9%` за `30 дней` | `API Gateway` + `Orchestrator` |
| `p95` latency `POST /api/payments` | `<= 2 s` | `Gateway` + `Wallet Service` |
| Доля вызовов провайдера с timeout/transport error | `<= 1%` от всех попыток за `7 дней` | `Transaction Service` |
| Доля событий, попавших в DLQ | `<= 0.1%` от общего event volume | `Kafka` / `RabbitMQ` metrics |
| Доля расхождений между terminal state в `Wallet` и `Transaction` | `0%` для подтверждённых платежей | reconcile job / observability pipeline |

### Дашборды

- `Payment Operations Dashboard`: create payment throughput, reserve latency, success/fail ratio, pending payments, outbox lag, wallet/query consumer lag
- `Provider Health Dashboard`: latency, timeout rate, retry volume, breaker state, размер очереди повторных вызовов провайдера, количество late callback-ов
- `Transaction Service Health Dashboard`: CPU, memory / heap, GC pauses, saturation worker threads, executor queue depth, HTTP connection pool usage, HikariCP active / idle / pending connections, provider retry rate, outbox lag

## Стратегия масштабирования и отказоустойчивости

- `Wallet Service`, `Transaction Service`, `Callback Service`, `Payment Query Service` и `Notifications Service` масштабируются горизонтально как stateless-инстансы поверх собственных БД и consumer group-ов
- `Kafka` масштабируется через partitions топика `payments.events`; порядок сохраняется по `paymentId`
- `RabbitMQ` разделяет фоновые задачи: provider retry, notification dispatch и DLQ не конкурируют с доменными событиями
- при падении одного инстанса `Wallet` / `Transaction` / `Callback` нагрузку берут остальные инстансы, а незавершённые сообщения дочитываются consumer group-ой
- при временной недоступности провайдера платёж не переводится в terminal fail мгновенно: сначала используется bounded retry и deferred processing
- при всплеске чтений нагрузка снимается через `Redis Cache`, а тяжёлые аналитические запросы не выполняются через `Payment Query Service`

## Нефункциональные аспекты

- `Idempotency`: внешний `CreatePayment` поддерживает `requestId`; обработчики событий используют уникальные ограничения, дедупликацию в read-модели и проверки терминальных состояний
- `Наблюдаемость`: все сервисы пробрасывают `correlation_id`, `payment_id`, `attempt_id` и экспортируют метрики в единый стек наблюдаемости
- `Отказоустойчивость`: синхронные вызовы защищены timeout/retry/circuit breaker, асинхронные контуры изолированы через очереди и DLQ
- `Масштабирование`: денежный путь, retry jobs, callback processing, read traffic и notifications разделены по пулам, consumer-ам и брокерам
- `Изоляция legacy`: любые изменения модели `Core Banking` локализованы в `Core Integration / ACL`

## Вывод

Платёжная вертикаль разделена по домену и по runtime-ролям: `Wallet Service` отвечает за деньги, `Transaction Service` - за внешний статус, `Callback Service` - за адаптацию callback-ов, `Payment Query Service` - за read-модель, а `Kafka` связывает шаги саги через outbox. Поверх этого контура добавлен эксплуатационный слой.

Теперь устойчивость достигается не одной идеей, а набором согласованных решений: bounded retry и circuit breaker на вызовах провайдера, deferred processing через очередь, DLQ для плохих сообщений, cache-aside для безопасных чтений, а также единый стек метрик, логов и трейсов.
