# SDIA

Документация по архитектуре системы обработки платежей.

## Основной документ

- `system-design/architecture/payment-platform-architecture.md` - целевая архитектура, Saga, Outbox, Idempotency, CQRS, Resilience, Cache, DLQ и Observability

## Контракты

- `system-design/architecture/api-contracts.md` - внешние и внутренние API
- `system-design/architecture/message-contracts.md` - сообщения брокера и их схемы

## Security and Operations

- `system-design/architecture/security-auth.md` - OIDC/OAuth2, JWT validation, scopes и service-to-service trust
- `system-design/architecture/webhooks-security.md` - HMAC подпись, anti-replay и идемпотентность callback-ов
- `system-design/architecture/secrets-management.md` - Vault / K8s Secrets, injection и ротация
- `system-design/architecture/deployment-strategy.md` - GitLab CI, ArgoCD, Argo Rollouts, canary / blue-green
- `system-design/architecture/db-migration-feature-toggle.md` - zero-downtime миграция через feature flag
- `system-design/architecture/release-checklist.md` - чеклист релиза
- `system-design/architecture/runbook.md` - операционные сценарии и реакции

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
- `system-design/architecture/diagrams/sequence-provider-resilience.puml` - таймауты, retry, circuit breaker и fallback
- `system-design/architecture/diagrams/sequence-dlq-reprocessing.puml` - повторные ошибки consumer-а и уход в DLQ
- `system-design/architecture/diagrams/sequence-cache-read.puml` - чтение через cache hit/miss
- `system-design/architecture/diagrams/sequence-observability-flow.puml` - trace-id, метрики и логи по платёжному потоку
- `system-design/architecture/diagrams/c4-container-auth-security.puml` - AuthN/AuthZ и service trust
- `system-design/architecture/diagrams/sequence-oidc-auth-flow.puml` - OIDC Authorization Code Flow + API вызов
- `system-design/architecture/diagrams/c4-container-webhook-security.puml` - webhook security
- `system-design/architecture/diagrams/sequence-webhook-security-flow.puml` - webhook validation + anti-replay + idempotency
- `system-design/architecture/diagrams/c4-container-vault-secrets.puml` - Vault и secret injection
- `system-design/architecture/diagrams/sequence-vault-rotation.puml` - Vault agent + rotation
- `system-design/architecture/diagrams/c4-container-delivery-rollout.puml` - GitLab CI, ArgoCD и Argo Rollouts
- `system-design/architecture/diagrams/sequence-rollout-canary.puml` - canary rollout + rollback
- `system-design/architecture/diagrams/c4-container-feature-toggle-migration.puml` - feature toggle migration
- `system-design/architecture/diagrams/sequence-expand-contract-migration.puml` - expand / contract migration
- `system-design/architecture/diagrams/erd.puml` - ERD write/read моделей и outbox-таблиц

## Конфиги

- `system-design/architecture/configs/.gitlab-ci.yml` - пример GitLab CI pipeline
- `system-design/architecture/configs/rollout-canary.yaml` - пример Argo Rollout
- `system-design/architecture/configs/gateway-config.md` - gateway security policies
- `system-design/architecture/configs/vault-policy.hcl` - пример Vault policy
- `system-design/architecture/configs/k8s-secret-example.yaml` - пример базового K8s Secret
