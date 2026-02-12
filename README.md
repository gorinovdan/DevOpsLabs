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

## Принципы DevOps и влияние
- Совместная ответственность: разработка и эксплуатация работают как единая команда.
- Автоматизация: сборка, тестирование, проверка качества и релизы выполняются предсказуемо.
- Непрерывность: изменения быстро попадают в основной поток через CI.
- Наблюдаемость: метрики и логи дают понимание качества и стабильности.
- Культура улучшений: короткие циклы обратной связи ускоряют развитие продукта.

## Git (установка и настройка)
1. Установить Git: https://git-scm.com/downloads
2. Настроить пользователя:
```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```
3. Проверить состояние:
```bash
git --version
git config --list
```

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
Workflow находится в `/.github/workflows/ci.yml`. Включает 4 независимых job-а:
- `backend-build`
- `backend-test`
- `frontend-build`
- `frontend-test`

Дополнительно:
- backend test job запускает `go test -race -covermode=atomic -coverprofile=coverage.out ./...`
- frontend test job запускает `vitest` с coverage и порогами `100%`
- покрытия backend/frontend сохраняются как артефакты GitHub Actions

## Репозиторий и Git
Проект готов к публикации в GitHub/GitLab. В корне есть `.gitignore` для Go и Node.js, а все команды запуска и тестов воспроизводимы локально и в CI.
