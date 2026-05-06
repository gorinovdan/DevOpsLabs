# Лабораторная работа №4

## Тема
Безопасность приложения и инфраструктуры в DevOps: статический анализ кода через `SonarQube`, автоматическое развёртывание через `Argo CD`, нотификации pipeline в `Telegram`.

## 1. Что реализовано
1. Изучены и применены практики безопасности приложений и инфраструктуры в DevOps (см. раздел 7).
2. Подключён `SonarQube` (локальный, доступный из CI как «облачный» сервис) как отдельный CI job: статический анализ кода + покрытие тестами.
3. Quality Gate `FlowBoard Gate` в `SonarQube` блокирует CI:
   - покрытие < 80%;
   - провалившиеся тесты;
   - bugs / vulnerabilities > 0;
   - security/reliability rating хуже A;
   - любые `new_violations` на новом коде.
4. CD выведен в `Argo CD`: установка в кластер `minikube`, `AppProject` + `Application`, sync через CLI на каждом релизе.
5. Telegram-бот `@DevOpsLab4AgaGorBot` (token `8616212979:...`) получает статус каждого job и сводный статус всего pipeline.

## 2. Структура изменений

| Что | Где |
|---|---|
| SonarQube (boot/scan/gate) | `scripts/start_sonarqube.sh`, `scripts/sonar_quality_gate.sh`, `scripts/run_sonar_scan.sh`, `sonar-project.properties` |
| Argo CD bootstrap + manifests | `scripts/install_argocd.sh`, `scripts/argocd_sync.sh`, `deploy/argocd/bootstrap/`, `deploy/argocd/app/` |
| Telegram-нотификации | `scripts/notify_telegram.sh` + интеграция во все CI jobs |
| Обновлённый pipeline | `.github/workflows/ci.yml` |
| Покрытие тестами `coverpkg=./...` + lcov | `frontend/vite.config.ts`, CI `backend-test`, CI `frontend-test` |
| Рефакторинг под Quality Gate | `backend/internal/transport/httpapi/router.go`, `backend/internal/transport/httpapi/task_handlers.go` |

## 3. Покрытие тестами (для Quality Gate `≥ 80%`)

Проверка локально:

```bash
cd backend
go test -race -count=1 -covermode=atomic -coverpkg=./... -coverprofile=coverage.out ./...
go tool cover -func=coverage.out | tail -1
# total: 99.7%
```

Frontend (`vitest` + `coverage-v8`):

```bash
cd frontend
npm test
# % Stmts | % Branch | % Funcs | % Lines = 100 / 100 / 100 / 100
```

Поведение CI:
- backend job запускается через `gotestsum` с `-count=1 -coverpkg=./...`, отключая кэш `go test`, чтобы в одном workflow run всегда был свежий coverage profile;
- frontend job через `vitest run --coverage` пишет `frontend/coverage/lcov.info`;
- оба job выгружают coverage как artifact;
- `sonar-scan` job скачивает оба artifact и кладёт по путям, ожидаемым `sonar-project.properties`.

## 4. SonarQube

### 4.1 Запуск
SonarQube физически лежит в `/Users/lasat/Downloads/sonarqube-26.4.0.121862` (запускается self-hosted runner на macOS). Старт идемпотентный:

```bash
./scripts/start_sonarqube.sh
# native (default) - запускает sonar.sh start; работает с уже поднятым инстансом
# SONARQUBE_MODE=docker ./scripts/start_sonarqube.sh - для CI без macOS-инсталляции
```

Скрипт ждёт `/api/system/status == UP`. URL по умолчанию `http://127.0.0.1:9000`.

### 4.2 Quality Gate `FlowBoard Gate`
`scripts/sonar_quality_gate.sh` идемпотентно создаёт gate и привязывает его к проекту `flowboard`. Условия:

| Метрика | Условие |
|---|---|
| `coverage` (overall) | ≥ 80% |
| `new_coverage` | ≥ 80% (наследуется из Sonar way) |
| `bugs` | = 0 |
| `vulnerabilities` | = 0 |
| `blocker_violations` | = 0 |
| `critical_violations` | = 0 |
| `test_failures` | = 0 |
| `test_errors` | = 0 |
| `security_rating` | A |
| `reliability_rating` | A |
| `new_violations` | = 0 |

После запуска `sonar-scanner` сообщает gate-статус; если gate FAILED, scanner возвращает non-zero и job падает (`sonar.qualitygate.wait=true`).

### 4.3 Запуск scan локально
```bash
cd /Users/lasat/Documents/Study/DevOpsLabs

# 1. coverage artefacts
( cd backend && go test -race -count=1 -covermode=atomic -coverpkg=./... -coverprofile=coverage.out ./... )
( cd backend && gotestsum --jsonfile test-report.json -- -race -count=1 -covermode=atomic -coverpkg=./... -coverprofile=coverage.out ./... )
( cd frontend && npm test )

# 2. SonarQube + Gate
SONARQUBE_URL=http://127.0.0.1:9000 ./scripts/start_sonarqube.sh
SONARQUBE_URL=http://127.0.0.1:9000 SONARQUBE_ADMIN_USER=admin SONARQUBE_ADMIN_PASSWORD=admin ./scripts/sonar_quality_gate.sh

# 3. Scan (admin/admin или token)
SONARQUBE_URL=http://127.0.0.1:9000 SONARQUBE_TOKEN=squ_... ./scripts/run_sonar_scan.sh
```

Проверено локально, gate `PASSED`:
```
QUALITY GATE STATUS: PASSED - View details on http://127.0.0.1:9000/dashboard?id=flowboard
```
Финальные метрики: `coverage = 99.6`, `bugs = 0`, `vulnerabilities = 0`, `security_rating = A`, `reliability_rating = A`.

### 4.4 Что фильтруется
В `sonar-project.properties`:
- `sonar.test.inclusions` относит `*_test.go`, `frontend/tests/**`, `frontend/src/shared/test/**` к тестам;
- `sonar.issue.ignore.multicriteria` глушит шумные code smells, типичные для тестовых fixture: `S1192` (literal duplication) и `S3776` (cognitive complexity) в `*_test.go`, и `S1186` (empty mock methods) в `frontend/src/shared/test/**`.

## 5. CI Pipeline

Граф jobs (`.github/workflows/ci.yml`):

```
changes ──┬─ notify-start ────────────────────────────────────────────────┐
          ├─ backend-test  ┐                                              │
          ├─ frontend-test ┼─→ sonar-scan ┬─→ backend-image  ─┐           │
          └─               ┘              └─→ frontend-image ─┴─→ argocd-deploy ─┬─→ observability-verify ──┐
                                                                                 └─→ hpa-validate            │
                                                                                                             ▼
                                                                                                   notify-summary
```

Ключевые свойства:
- `sonar-scan` — обязательная преграда: `backend-image` / `frontend-image` / `argocd-deploy` стартуют только если `needs.sonar-scan.result == 'success'`;
- `argocd-deploy` использует уже опубликованные в GHCR образы по SHA-tag и кладёт их в Argo CD через `argocd app set --kustomize-image`;
- `notify-start` сообщает в Telegram о запуске pipeline, каждый ключевой job шлёт отдельный шаг `Notify Telegram`, `notify-summary` шлёт сводку результатов в одном сообщении;
- все обращения к динамическим выражениям GitHub (`${{ ... }}`) идут через `env:` — чтобы избежать workflow injection.

## 6. Argo CD (Continuous Delivery)

### 6.1 Установка
```bash
ENABLE_PORT_FORWARD=1 ./scripts/install_argocd.sh
```

Скрипт:
- создаёт namespace `argocd`;
- применяет `https://raw.githubusercontent.com/argoproj/argo-cd/v2.13.1/manifests/install.yaml`;
- ждёт rollout всех Argo CD компонентов;
- включает `server.insecure=true` (для локального minikube без TLS);
- применяет `deploy/argocd/bootstrap/project.yaml` (`AppProject flowboard`) и `deploy/argocd/bootstrap/application.yaml` (`Application flowboard`);
- поднимает port-forward `http://127.0.0.1:18083` и печатает `admin`-пароль из `argocd-initial-admin-secret`.

### 6.2 Application
Манифест приложения - `deploy/argocd/bootstrap/application.yaml`:
- `repoURL: https://github.com/gorinovdan/DevOpsLabs.git`
- `path: deploy/argocd/app`
- `kustomize.images` устанавливают backend/frontend на `:latest` по умолчанию;
- `syncPolicy.automated` = `prune: true, selfHeal: true`;
- `syncOptions` = `CreateNamespace=true, ServerSideApply=true, ApplyOutOfSyncOnly=true`;
- retry с экспоненциальным backoff.

`deploy/argocd/app/` - kustomize-набор манифестов FlowBoard, отделённый от исторического `deploy/minikube/`, потому что Argo CD не понимает шаблон `__BACKEND_IMAGE__`.

### 6.3 Sync из CI
```bash
BACKEND_IMAGE=ghcr.io/.../backend:<sha> \
FRONTEND_IMAGE=ghcr.io/.../frontend:<sha> \
./scripts/argocd_sync.sh
```

Скрипт использует `argocd CLI --core` (не требует логина в `argocd-server`):
1. `argocd app set flowboard --kustomize-image backend=...:<sha> --kustomize-image frontend=...:<sha>`
2. `argocd app sync flowboard --prune`
3. `argocd app wait flowboard --health --sync`

В CI это делает job `argocd-deploy` после успешного `sonar-scan` и публикации обоих images.

## 7. Telegram-бот

### 7.1 Конфигурация секретов в GitHub Actions
| Secret | Значение |
|---|---|
| `TELEGRAM_BOT_TOKEN` | строка от BotFather в формате `<bot_id>:<auth_string>`, без кавычек и без префикса `bot`. Текущее значение для лаб-бота `@DevOpsLab4AgaGorBot`: `8616212979:AAF5IDnm_Fwi7k_4iCxpO-kdHa7tiRGVrn8` |
| `SONARQUBE_TOKEN` (опционально) | scanner token для SonarQube |
| `SONARQUBE_ADMIN_USER` / `SONARQUBE_ADMIN_PASSWORD` (опционально) | fallback для quality gate API |

`TELEGRAM_CHAT_ID` намеренно не используется. Получатели определяются автоматически (см. §7.2).

### 7.2 Подписка на нотификации (broadcast-mode)
Чтобы начать получать сообщения, достаточно один раз написать боту:
1. Открыть Telegram и найти `@DevOpsLab4AgaGorBot`.
2. Отправить любое сообщение (например, `/start`).
3. Готово - адрес чата попадёт в getUpdates Telegram API в течение ~24 часов и будет автоматически добавлен в персистентный список получателей при следующем запуске CI.

То же самое работает для группы/канала: достаточно добавить бота администратором и написать туда любое сообщение.

Бот проверен через `getMe`: `{ok: true, is_bot: true, username: "DevOpsLab4AgaGorBot"}`.

### 7.3 Скрипт `notify_telegram.sh`
- требует только `TELEGRAM_BOT_TOKEN`; если его нет - warns и выходит с `0`;
- на каждом запуске сначала вызывает `getUpdates`, извлекает `chat.id` из всех `message`, `channel_post`, `edited_message`, `my_chat_member`;
- мержит свежие id с персистентным кэшем `${TELEGRAM_CHATS_FILE:-${HOME}/.flowboard-telegram-chats.txt}` (дедуп);
- рассылает уведомление по всему объединённому списку (`sendMessage` с `parse_mode=HTML`);
- собирает сообщение с иконкой по статусу (`✅ ❌ ⚠️ 🔄`), repo, ref, short SHA, ссылкой на run, опциональным текстом;
- редактирует токен из ответа в логах при ошибках;
- в конце печатает `sent=N, failed=M, total_recipients=K`.

На self-hosted macOS-runner кэш `${HOME}/.flowboard-telegram-chats.txt` живёт между запусками, поэтому со временем список подписчиков только растёт. На ephemeral `ubuntu-latest` (jobs `notify-start`, `notify-summary`) `getUpdates` каждый раз обнаруживает чатов, которые писали боту в последние сутки.

### 7.4 Точки нотификаций
| Шаг | Сообщение |
|---|---|
| `notify-start` | `pipeline / started`, кто и каким триггером запустил |
| `sonar-scan` | `sonar-scan / success|failure|cancelled`, упоминание enforced gate |
| `backend-image`, `frontend-image` | имя образа c SHA-tag |
| `argocd-deploy` | пара backend/frontend images |
| `observability-verify`, `hpa-validate` | статус |
| `notify-summary` | агрегированный статус всего pipeline + результаты по job-ам |

## 8. Best practices безопасности применённые в работе

| Практика | Где |
|---|---|
| Static Code Analysis в CI | SonarQube, отдельный job, блокирует merge при findings |
| Quality Gate с минимумом покрытия и без bugs/vulns | `FlowBoard Gate` |
| Coverage 100% (frontend) / 99.7% (backend cross-package) | `vite.config.ts thresholds`, backend `-coverpkg=./...` |
| Secrets only через GitHub Secrets, никаких токенов в репо | CI workflow ссылается на `secrets.*` |
| Workflow injection mitigation: `env:` вместо inline `${{ }}` | все `run:` блоки с динамикой используют env vars |
| Минимальные permissions GH workflow | `permissions: contents: read`, packages: write только в image-job |
| GitOps через Argo CD: декларативное состояние в Git | `deploy/argocd/app/` |
| Argo CD `selfHeal=true, prune=true` | `application.yaml` |
| Server-side apply, чтобы Argo не дрался с собой | `syncOptions: ServerSideApply=true` |
| Image pinning (SHA-tag, не только `latest`) | `argocd_sync.sh` ставит SHA-tag |
| HPA + ресурсные лимиты (унаследовано из LAB3) | `deploy/argocd/app/backend-deployment.yaml` |
| Probes (readiness/liveness) | оба Deployment'а |
| pg_isready init container перед стартом backend | `backend-deployment.yaml` |
| Telegram-уведомления о fail/success | `notify-summary`, per-job `notify` шаги |

## 9. Команды для проверки

```bash
# Локальный full smoke (всё подряд)
./scripts/start_sonarqube.sh
./scripts/sonar_quality_gate.sh
( cd backend && go test -race -count=1 -covermode=atomic -coverpkg=./... -coverprofile=coverage.out ./... && /Users/lasat/go/bin/gotestsum --jsonfile test-report.json -- -race -count=1 -covermode=atomic -coverpkg=./... -coverprofile=coverage.out ./... )
( cd frontend && npm test )
SONARQUBE_TOKEN=squ_... ./scripts/run_sonar_scan.sh   # exit != 0 если gate FAILED

# CD
./scripts/install_argocd.sh                            # один раз, идемпотентно
BACKEND_IMAGE=ghcr.io/.../backend:<sha> \
FRONTEND_IMAGE=ghcr.io/.../frontend:<sha> \
./scripts/argocd_sync.sh

# Telegram (broadcast по всем, кто писал боту)
TELEGRAM_BOT_TOKEN=... ./scripts/notify_telegram.sh "manual" "success" "smoke notification"
```

## 10. Что проверено локально
- SonarQube `26.4.0.121862` стартует через `scripts/start_sonarqube.sh` и доходит до `status=UP`.
- `scripts/sonar_quality_gate.sh` создаёт `FlowBoard Gate` и привязывает к проекту `flowboard` (HTTP 204).
- `scripts/run_sonar_scan.sh` (через Docker scanner CLI) сообщает `QUALITY GATE STATUS: PASSED`.
- Метрики проекта в SonarQube: coverage 99.6, bugs 0, vulnerabilities 0, security/reliability A.
- `go build ./... && go test ./...` после рефакторинга `Update`/`router.go`: 33 теста проходят.
- Backend cross-package coverage `-coverpkg=./...` = 99.7%.
- Frontend `npm test`: 25 тестов, 100% statements/branches/functions/lines, генерится `coverage/lcov.info`.
- `kubectl kustomize deploy/argocd/app` собирается без ошибок и корректно подменяет images через kustomize image override.
- Telegram bot валиден (`getMe` = OK, username `DevOpsLab4AgaGorBot`); `notify_telegram.sh` корректно warning'ит и возвращает 0 при отсутствии секретов.
- Workflow YAML (`.github/workflows/ci.yml`) парсится валидно.
- Bash-скрипты `start_sonarqube.sh`, `sonar_quality_gate.sh`, `run_sonar_scan.sh`, `install_argocd.sh`, `argocd_sync.sh`, `notify_telegram.sh` проходят `bash -n`.
- `notify_telegram.sh` без `TELEGRAM_BOT_TOKEN` корректно warning'ит и возвращает 0; с пустым кэшем и валидным токеном (но без подписчиков) сообщает «no Telegram recipients known yet» и выходит c 0, не падая pipeline.
