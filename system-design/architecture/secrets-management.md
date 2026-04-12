# Security: Secrets Management

## Какие секреты есть в системе

- `provider_api_key`
- `provider_api_secret`
- `webhook_signing_secret_current`
- `webhook_signing_secret_previous`
- `oidc_client_secret`
- `m2m_client_secret`
- `db_password_wallet`
- `db_password_transaction`
- `db_password_query`
- `jwt_private_keys` для внутренних service tokens, если используются локально

## Базовый и production-ready сценарии

### Базовый: K8s Secrets

`K8s Secrets` подходят как стартовая модель:

- секреты монтируются в pod как env vars или volume
- жизненный цикл управляется deployment manifest-ами
- подходит для `dev` и простого `stage`

Ограничения:

- слабее аудит и ротация
- сложнее fine-grained policies
- сложнее динамические креды

### Production-ready: Vault

Для production выбирается `HashiCorp Vault`.

Почему:

- централизованный аудит доступа
- policies по namespace / service account
- безопасная ротация
- поддержка динамических DB credentials

## Как pod получает секреты

Выбранный вариант:

- `Vault Agent sidecar`
- аутентификация в Vault через `Kubernetes Auth`

Поток:

1. pod стартует с service account
2. `Vault Agent` аутентифицируется в `Vault` через `Kubernetes Auth`
3. agent получает short-lived token
4. agent рендерит секреты в memory volume или файл
5. приложение читает секреты из файла / env bridge при старте и на refresh

Почему не `AppRole`:

- для Kubernetes workloads естественнее `Kubernetes Auth`
- меньше ручного обращения с bootstrap secret-id

## Ротация секретов

### Webhook signing secret

Безопасная схема:

- `Gateway` хранит `current` и `previous` secret
- новый секрет сначала включается у провайдера и в Vault
- на окне совместимости подпись принимается по старому и новому секрету
- после окна совместимости старый секрет удаляется

### Provider API key

Схема:

1. создать новый ключ у провайдера
2. положить его в Vault как `current`, старый оставить как `previous`
3. rollout сервисов
4. проверить success rate и отсутствие `401/403`
5. отозвать старый ключ

### DB credentials

Предпочтительно использовать динамические креды Vault:

- короткоживущие username/password
- lease renewal через agent
- отзыв при завершении workload

Если это недоступно, допускаются статические креды в Vault с регулярной ротацией через rollout.

## Что хранится где

| Секрет | K8s Secret | Vault | Комментарий |
|---|---|---|---|
| provider API key | допустимо для `dev` | да | в `prod` лучше Vault |
| webhook signing secret | допустимо для `dev` | да | нужен current + previous |
| gateway client secret к IdP | допустимо | да | лучше Vault |
| DB credentials | только как fallback | да | динамические креды предпочтительны |
| JWT verification keys | обычно нет, это публичные `JWKS` | не секрет | читаются по `OIDC` metadata |

## Что нельзя делать

- хранить секреты в Git
- вставлять реальные значения в Helm values
- логировать секреты или полные токены
- передавать provider key между сервисами через business events

## Вывод

Для production-контуров секреты должны приходить из `Vault`, а `K8s Secrets` остаются упрощённым базовым вариантом. Ключевой паттерн: секреты живут вне кода, читаются через workload identity и ротируются без остановки сервиса.
