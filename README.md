# SDIA

Документация по архитектуре системы обработки платежей.

## Основной документ

- `system-design/architecture/payment-platform-architecture.md` - целевая архитектура, Saga, Outbox, Idempotency, CQRS

## Контракты

- `system-design/architecture/api-contracts.md` - внешние и внутренние API
- `system-design/architecture/message-contracts.md` - сообщения брокера и их схемы

## Диаграммы

- `system-design/architecture/diagrams/c4-context.puml` - C4 Context
- `system-design/architecture/diagrams/context-map.puml` - Context Map
- `system-design/architecture/diagrams/c4-container.puml` - C4 Container
- `system-design/architecture/diagrams/wallet-components.puml` - компоненты Wallet Service
- `system-design/architecture/diagrams/transaction-components.puml` - компоненты Transaction Service
- `system-design/architecture/diagrams/query-components.puml` - компоненты Query Service
- `system-design/architecture/diagrams/sequence-success.puml` - успешный сценарий платежа
- `system-design/architecture/diagrams/sequence-failure-timeout.puml` - сценарий ошибки/таймаута и компенсации
- `system-design/architecture/diagrams/sequence-callback-flow.puml` - поток callback-а провайдера
- `system-design/architecture/diagrams/erd.puml` - ERD write/read моделей и outbox-таблиц
