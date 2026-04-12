# Operations: Zero-Downtime DB Migration via Feature Toggle

## Выбранный пример

Миграция: добавление `provider_fee_amount` в `payments`.

Текущее состояние:

- read-path при необходимости вычисляет комиссию из provider payload или не показывает её отдельно

Целевое состояние:

- `payments.provider_fee_amount` и `payments.provider_fee_currency` хранятся явно
- `Payment Query Service` читает комиссию из materialized fields

## Почему это хороший пример

- изменение затрагивает write и read контур
- есть реальный смысл для UI и reconciliation
- можно показать `expand / dual write / switch read / contract`

## План миграции

### 1. Expand

- Liquibase/Flyway добавляет nullable поля:
  - `provider_fee_amount bigint null`
  - `provider_fee_currency char(3) null`
- старый код продолжает работать без изменений

### 2. Dual write / shadow write

- `Transaction Service` начинает заполнять новые поля для новых платежей
- старый read-path пока ещё не зависит от них
- feature flag: `payments.read-provider-fee-from-column=false`

### 3. Backfill

- фоновый job читает исторические `payments`
- восстанавливает комиссию из provider payload / audit источника
- заполняет новые поля пачками

### 4. Switch read

- включается feature flag `payments.read-provider-fee-from-column=true`
- `Payment Query Service` и API читают fee из новых колонок
- старый fallback path ещё остаётся

### 5. Contract

- удаляется старый fallback на вычисление комиссии из сырых payload
- при необходимости колонки становятся `NOT NULL` для новых записей

## Rollback plan

Если новый read-path ломается:

1. выключаем feature flag
2. возвращаем чтение на старый источник
3. dual write можно оставить включённым
4. схема не откатывается немедленно, потому что expand-изменение backward-compatible

Если ломается backfill:

- останавливаем job
- production traffic не страдает
- исправляем логику и продолжаем с последнего батча

## Условия перехода между шагами

- после `Expand`: rollout без роста ошибок миграции
- после `Dual write`: новые записи стабильно заполняют fee
- перед `Switch read`: backfill >= `99.9%`, проверка выборкой
- перед `Contract`: окно совместимости прошло, rollback через старый path больше не нужен

## Почему нужен feature flag

Он отделяет rollout кода от переключения поведения:

- код уже задеплоен
- схема уже расширена
- но чтение можно переключить отдельно и быстро откатить

Это ключевой элемент zero-downtime миграций для write-heavy систем.
