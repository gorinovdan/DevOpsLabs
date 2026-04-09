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

## ЛР2: локальная VM через Terraform
Однокомандный запуск локальной VM (Multipass):

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\tf_vm.ps1 -Action apply -AutoApprove
```

Скрипт и IaC:
- `scripts/tf_vm.ps1`
- `infra/terraform/*`

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

HPA-проверка вынесена в opt-in шаг, потому что она специально меняет runtime-состояние:
```bash
RUN_HPA_VALIDATION=1 ./scripts/deploy_minikube_local.sh
```

Проверка:
```bash
kubectl -n flowboard get pods,svc,hpa
./scripts/smoke_test_minikube.sh
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
- `deploy-minikube` (runs-on `[self-hosted, windows]`)
- деплой в локальный Minikube и smoke-тест API

## API
Базовый URL: `http://localhost:8080`

- `GET /api/tasks`
- `GET /api/tasks/:id`
- `POST /api/tasks`
- `PUT /api/tasks/:id`
- `DELETE /api/tasks/:id`
- `GET /api/insights`
