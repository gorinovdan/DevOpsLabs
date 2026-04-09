# DevOps Labs (Local Runner + Minikube)

Лабораторные работы по дисциплине DevOps для проекта **FlowBoard**.

## Команда
- Горинов Даниил Андреевич (338960, P4116)
- Агафангелос Дмитрий Евстафьевич (410808, P4114)

## Проект
FlowBoard - учебное full-stack приложение для управления задачами:
- backend (Go, REST API)
- frontend (React + Vite)
- PostgreSQL

## Стек
- Backend: Go 1.25, Gin, GORM
- Frontend: React 18, Vite, TypeScript
- DB: PostgreSQL 16
- CI/CD: GitHub Actions + self-hosted runner
- Orchestration: Kubernetes (Minikube)

## Отчёты по лабораторным 1-3
- [ЛР1: Git, приложение, CI](LAB1_REPORT.md)
- [ЛР2: Terraform + Ansible + Docker (локально)](LAB2_REPORT.md)
- [ЛР3: Minikube + HPA + Monitoring + Runner deploy](LAB3_MINIKUBE.md)

## Быстрый локальный запуск

### Docker Compose
```bash
docker compose up --build
```

- Frontend: `http://localhost:5173`
- Backend: `http://localhost:8080`
- PostgreSQL: `localhost:5432`

Остановка:
```bash
docker compose down
```

## ЛР3: Minikube локально

Полный локальный deploy:
```bash
./scripts/deploy_minikube_local.sh
```

Идемпотентный повторный deploy тем же скриптом:
```bash
./scripts/deploy_minikube_local.sh
```

Полная остановка локального стенда:
```bash
./scripts/stop_minikube_local.sh
```

Полное удаление кластера:
```bash
MINIKUBE_ACTION=delete PURGE=1 ./scripts/stop_minikube_local.sh
```

Проверка HPA:
```bash
./scripts/load_test_backend_hpa.sh
```

Проверка:
```bash
kubectl -n flowboard get pods,svc,hpa
./scripts/smoke_test_minikube.sh
./scripts/verify_observability_minikube.sh
```

## CI/CD
Workflow: `.github/workflows/ci.yml`

CI jobs:
- `backend-build`
- `backend-test`
- `frontend-build`
- `frontend-test`

Publish job:
- `docker-publish` (push backend/frontend образов в GHCR)

CD job (локально):
- `deploy-minikube` (runs-on `[self-hosted, macOS, minikube-local]`)
- деплой в локальный Minikube из GHCR-образов, повторный idempotent redeploy, smoke-тест, observability check и HPA validation

Локальный GitHub Actions runner:
```bash
./scripts/configure_github_runner.sh
./scripts/start_github_runner.sh
```

## API
Базовый URL: `http://localhost:8080`

- `GET /api/tasks`
- `GET /api/tasks/:id`
- `POST /api/tasks`
- `PUT /api/tasks/:id`
- `DELETE /api/tasks/:id`
- `GET /api/insights`
