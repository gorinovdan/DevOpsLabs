# Лабораторная работа №1 (локальный контур)

## 1. Цель
- Развернуть и вести проект в Git.
- Реализовать full-stack приложение (backend + frontend + БД) с REST API.
- Покрыть сервер и клиент модульными тестами.
- Настроить CI в GitHub Actions с минимум 4 job: `backend-build`, `backend-test`, `frontend-build`, `frontend-test`.
- Выполнять jobs через GitHub Actions + self-hosted runner (локальная машина).

## 2. Что реализовано
- Backend: Go + Gin + GORM + PostgreSQL.
- Frontend: React + Vite + TypeScript.
- REST API с CRUD и endpoint для метрик/сводки (`/api/insights`).
- Модульные тесты:
  - backend: `backend/internal/**/_test.go`, `backend/tests`
  - frontend: `frontend/tests`

## 3. CI (GitHub Actions)
Workflow: `.github/workflows/ci.yml`

Стадия CI:
- `backend-build` - `go build ./...`
- `backend-test` - `go test -race -covermode=atomic -coverprofile=coverage.out ./...`
- `frontend-build` - `npm run build`
- `frontend-test` - `npm test`

Покрытия сохраняются как artifacts:
- `backend-coverage`
- `frontend-coverage`

## 4. Локальный self-hosted runner
Runner используется как локальный исполнитель GitHub Actions jobs для деплоя в Minikube (и при необходимости для CI jobs, если назначить соответствующие labels).

Минимальный набор на runner-хосте:
- Docker
- kubectl
- minikube
- helm
- Go/Node.js (если CI jobs тоже переводятся на self-hosted)

## 5. Итог
Требования ЛР1 закрыты в локальном контуре: код в GitHub, сервер и клиент реализованы, есть unit-тесты, CI pipeline на GitHub Actions содержит требуемые 4 job-а.
