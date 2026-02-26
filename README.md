# DevOps
Лабораторные работы по дисциплине DevOps 1 курс магистратуры
- Горинов Даниил Андреевич (338960, P4116)
- Агафангелос Дмитрий Евстафьевич (410808, P4114)

## Проект
FlowBoard - учебное full-stack приложение для управления задачами с REST API, БД и CI. Проект иллюстрирует практики DevOps: автоматизация сборки/тестов, единый жизненный цикл кода, контроль версий и повторяемые окружения. Тема приложения согласовывается с преподавателем.

## Стек
- Backend: Go 1.25, Gin, GORM, PostgreSQL
- Frontend: React 18, Mantine, Vite, TypeScript
- Тесты: Go `testing` + `testify`, Vitest + Testing Library
- CI: GitHub Actions (4 job-а: build/test для backend и frontend)

## Запуск локально
### Требования
- Git
- Go 1.25+
- Node.js 20+
- PostgreSQL 16+ (или запуск через Docker Compose)

### Backend
```bash
cd backend
go run ./cmd/server
```
Переменные окружения:
- `PORT` - порт сервера (по умолчанию `8080`)
- `DB_DSN` - DSN подключения к PostgreSQL
  (по умолчанию `host=localhost user=postgres password=postgres dbname=flowboard port=5432 sslmode=disable TimeZone=UTC`)

### Frontend
```bash
cd frontend
npm install
npm run dev
```
Переменные окружения:
- `VITE_API_URL` - базовый URL API (по умолчанию `http://localhost:8080`)

## Тесты
Backend:
```bash
cd backend
go test ./...
```
Серверные тесты находятся в `backend/internal/**/_test.go` и `backend/tests`.

Frontend:
```bash
cd frontend
npm test
```
Тесты находятся в `frontend/tests`.

## Docker
Запуск всего проекта в Docker:
```bash
docker compose up --build
```
- Frontend: `http://localhost:5173`
- Backend API: `http://localhost:8080`
- PostgreSQL: `localhost:5432`

Остановка:
```bash
docker compose down
```
Данные PostgreSQL сохраняются в Docker volume `postgres-data`.

## IaC и деплой в облако
В репозиторий добавлена инфраструктура для лабораторной:
- `infra/terraform` - создание VM в Timeweb Cloud через Terraform;
- `infra/ansible` - установка Docker и деплой приложения;
- `deploy/docker-compose.prod.yml` - production compose (backend + frontend + postgres).

### 1. Terraform: создание VM в Timeweb Cloud
```bash
cd infra/terraform
cp terraform.tfvars.example terraform.tfvars
```

Укажите API-токен Timeweb Cloud:
```bash
export TWC_TOKEN="<TIMEWEB_API_TOKEN>"
```

Применение:
```bash
terraform init
terraform validate
terraform plan
terraform apply
```

После `apply` Terraform выведет IP и SSH-команду для подключения к VM.

### 2. Ansible: установка Docker на VM
```bash
cd infra/ansible
cp inventory.ini.example inventory.ini
cp group_vars/all.yml.example group_vars/all.yml
```

Отредактируйте `inventory.ini` (IP VM) и запустите:
```bash
ansible-playbook playbooks/install_docker.yml
```

### 3. Сборка и публикация образов в облачный реестр
Скрипт:
```bash
./scripts/build_and_push.sh <image_prefix> [tag]
```

Пример для облачного реестра `ttl.sh`:
```bash
./scripts/build_and_push.sh ttl.sh/flowboard-$(date +%Y%m%d%H%M%S) 24h
```

Запишите получившиеся `backend_image` и `frontend_image` в `infra/ansible/group_vars/all.yml`.

### 4. Деплой приложения на VM
```bash
cd infra/ansible
ansible-playbook playbooks/deploy_flowboard.yml
```

После запуска:
- Frontend: `http://<VM_IP>/`
- Backend API: `http://<VM_IP>:8080`

### Единый идемпотентный сценарий деплоя
Добавлен orchestration-скрипт:
```bash
./scripts/deploy_idempotent.sh
```

Что делает скрипт:
1. Проверяет/до устанавливает инструменты (`ansible`, `docker`, `docker compose`), проверяет `terraform`.
2. Готовит SSH-ключ и `infra/terraform/terraform.auto.tfvars` (если файла нет).
3. Выполняет `terraform init/validate/apply` для VM в Timeweb Cloud.
4. Ждёт готовность VM и SSH.
5. Собирает и пушит Docker-образы (или пропускает сборку, если образы уже есть в registry).
6. Запускает Ansible playbook для Docker.
7. Если контейнеры уже запущены на целевых образах - пропускает повторный deploy (идемпотентность).
8. Выполняет smoke-тест API.

Обязательная переменная:
```bash
export TWC_TOKEN="<TIMEWEB_API_TOKEN>"
```

Полезные опции через env:
- `REGISTRY_PREFIX` (по умолчанию `ttl.sh/flowboard-lab-amd64`)
- `IMAGE_TAG` (по умолчанию `24h`)
- `BUILD_PLATFORM` (например `linux/amd64`)
- `FORCE_REBUILD=1` (принудительная пересборка образов)

Пример:
```bash
TWC_TOKEN="<token>" \
REGISTRY_PREFIX="ttl.sh/flowboard-idempotent-lab-20260226" \
IMAGE_TAG="24h" \
./scripts/deploy_idempotent.sh
```

Подробный отчёт по лабораторной: `LAB2_REPORT.md`.

## REST API
Базовый URL: `http://localhost:8080`

- `GET /api/tasks` - список задач (поддерживает фильтры)
- `GET /api/tasks/:id` - получить задачу
- `POST /api/tasks` - создать задачу
- `PUT /api/tasks/:id` - обновить задачу
- `DELETE /api/tasks/:id` - удалить задачу
- `GET /api/insights` - метрики и сводка

Фильтры:
- `status=todo,in_progress,blocked,done`
- `priority=low,medium,high,critical`
- `owner=alex`
- `tag=devops`
- `q=search`
- `sort=score|priority|due_date|updated_at|created_at|title`
- `order=asc|desc`

Пример `POST /api/tasks`:
```json
{
  "title": "Ship CI pipeline",
  "description": "Add build and test jobs",
  "status": "todo",
  "priority": "high",
  "owner": "alex",
  "effortHours": 6,
  "dueDate": "2026-02-10T12:00:00Z",
  "tags": ["ci", "release"]
}
```

## CI
Workflow находится в `/.github/workflows/ci.yml`.

### CI stage
Включает 4 независимых job-а:
- `backend-build`
- `backend-test`
- `frontend-build`
- `frontend-test`

Дополнительно:
- backend test job запускает `go test -race -covermode=atomic -coverprofile=coverage.out ./...`
- frontend test job запускает `vitest` с coverage и порогами `100%`
- покрытия backend/frontend сохраняются как артефакты GitHub Actions

### CD stage
После успешного CI на `push` в `main/master` выполняются:
- `docker-publish` - сборка и публикация backend/frontend образов в GHCR:
  - `ghcr.io/<owner>/<repo>/backend:<git_sha>`
  - `ghcr.io/<owner>/<repo>/frontend:<git_sha>`
- `deploy-production` - деплой на прод-сервер `178.253.43.153` через Ansible:
  - установка Docker (идемпотентно),
  - обновление compose-стека,
  - smoke-тест API.

Для CD необходимо задать GitHub Secrets в репозитории:
- `DEPLOY_PASSWORD` - пароль пользователя `root` на `178.253.43.153`
- `DEPLOY_SSH_KEY` - опционально, приватный SSH-ключ для деплоя (если задан, приоритетнее пароля)

Рекомендуется:
1. Добавить SSH-ключ и перейти на key-based auth.
2. Ограничить доступ к job `deploy-production` через GitHub Environment protection rules.

Пример подготовки deploy-ключа:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/devopslabs_ci_deploy -N ""
ssh-copy-id -i ~/.ssh/devopslabs_ci_deploy.pub root@178.253.43.153
```
Содержимое `~/.ssh/devopslabs_ci_deploy` добавьте в GitHub Secret `DEPLOY_SSH_KEY`.
