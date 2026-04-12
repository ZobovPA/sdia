# Release Checklist

## Перед релизом

- все migration scripts backward-compatible
- rollout strategy выбрана: canary или blue-green
- analysis thresholds в `Argo Rollouts` актуальны
- `Gateway` policy changes проверены в `stage`
- новые scopes/roles заведены в `IdP`
- secrets подготовлены в `Vault` / `K8s Secrets`
- feature flags созданы и выключены по умолчанию
- runbook для новых ошибок обновлён

## Во время релиза

- `GitLab CI` прошёл build/test/security scan
- image опубликован в registry
- manifests обновлены в GitOps repo
- `ArgoCD` синхронизировал окружение
- canary стартовал с `10%`
- dashboard и traces мониторятся в паузе rollout
- нет всплеска `5xx`, `DLQ`, callback signature failures, provider timeout

## После промоушена

- rollout дошёл до `100%`
- старый replica set scaled down
- SLI/SLO не деградировали
- outbox lag и consumer lag в норме
- нет роста `EXPIRED` / stuck holds
- нет всплеска `401/403` по JWT/service tokens

## При откате

- abort rollout
- зафиксировать момент и метрики
- проверить feature flags
- если проблема только в read-path, откатить флаг без rollback приложения
- если проблема в secrets/policy, вернуть previous secret window
