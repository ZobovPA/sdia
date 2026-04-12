# Operations: Safe Deployments and Rollouts

## Цель

Релиз платежной системы должен проходить без потери трафика, без ломания активных саг и с автоматическим откатом при деградации.

## Выбранная модель

- `GitLab CI` для build/test/security checks
- container registry для образов
- `ArgoCD` для GitOps-доставки манифестов
- `Argo Rollouts` для canary / blue-green
- `Kong Ingress` или `Gateway API` weights для переключения трафика

## CI/CD pipeline

Этапы:

1. `lint` / static checks
2. unit + integration tests
3. security scan / dependency scan
4. build image
5. push image в registry
6. update manifests / image tag в GitOps repo
7. `ArgoCD` синхронизирует окружение
8. `Argo Rollouts` делает canary

## Rollout strategy

Базовой стратегией для stateless edge/read сервисов выбирается canary:

- `10%`
- пауза и analysis
- `50%`
- пауза и analysis
- `100%`

Критерии автоматического abort:

- рост `5xx`
- рост `p95` latency `POST /api/payments`
- рост `DLQ`
- рост provider timeout rate
- readiness failures

## Blue-Green vs Canary

### Canary

Подходит для:

- `Gateway`
- `Orchestrator`
- `Query Service`
- `Notifications Service`
- schema-compatible rollout `Wallet Service` и `Transaction Service`, если сохраняются backward-compatible контракты и расширенная пауза анализа

Плюсы:

- плавный вход нового релиза
- быстро видно деградацию на части трафика

### Blue-Green

Может использоваться для:

- крупных schema-compatible релизов
- сложных gateway/plugin changes

Плюсы:

- быстрое переключение stable/candidate
- простой rollback

Минус:

- дороже по ресурсам

## Graceful shutdown

Обязательно:

- `readinessProbe` снимает pod из балансировки до остановки
- `preStop` даёт время закончить in-flight запросы
- consumer-ы перестают брать новые сообщения до завершения текущих

Примерная политика:

- `terminationGracePeriodSeconds: 30-60`
- `preStop` sleep / drain endpoint
- pause consumer loop before SIGTERM handling

## Где переключается трафик

Трафик между `stable` и `canary` сервисами переключает `Argo Rollouts` через ingress weights.

Для `Gateway`:

- `Kong Ingress Controller` или `Gateway API` получает изменённые веса
- внешний клиент не знает о stable/canary split

Для внутренних сервисов:

- rollout идёт через k8s service selector и stable/canary services

## Rollback

Автоматический rollback:

- по analysis templates
- по readiness/liveness failures
- по manual abort из `Argo Rollouts`

После rollback:

- stable replica set остаётся receiving traffic
- новый canary масштабируется вниз
- инцидент разбирается по dashboard + traces + logs

## Что важно для нашей платёжной системы

- write-сервисы должны оставаться schema-compatible в рамках rollout window
- для `Wallet Service` и `Transaction Service` canary допустим только при schema-compatible изменениях, совместимых сообщениях и безопасной работе `Saga / Outbox`
- rollout не должен ломать `Saga`, `Outbox`, `Query` и `Callback Service`
- изменения в `Gateway` и callback validation откатываются отдельно от бизнес-сервисов
