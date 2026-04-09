# Лабораторная работа №2 (локальная машина)

## 1. Цель
- Поднять инфраструктуру как код через Terraform.
- Автоматизировать конфигурацию окружения через Ansible.
- Подготовить контейнеризацию backend/frontend и multi-service запуск с БД.
- Публиковать Docker-образы в облачный registry из CI.

## 2. Локальная реализация (без облачного провайдера)
Вместо удалённого облака используется локальная VM на хост-машине:
- Terraform создаёт VM через Multipass.
- Ansible настраивает VM (Docker, kubectl, Minikube).
- Приложение контейнеризовано (backend, frontend), есть `docker-compose.yml` минимум из 3 сервисов.

Ключевые файлы:
- `infra/terraform/main.tf`, `infra/terraform/variables.tf`, `infra/terraform/outputs.tf`
- `infra/ansible/playbooks/install_docker.yml`
- `infra/ansible/playbooks/deploy_flowboard.yml`
- `backend/Dockerfile`, `frontend/Dockerfile`, `docker-compose.yml`
- `.github/workflows/ci.yml` (job `docker-publish`)

## 3. Terraform (локальная VM)
Terraform-конфигурация для локальной VM сохранена в `infra/terraform/*` как часть LAB2.
В активном сценарии репозитория для LAB3 используется локальный `minikube` и bash-скрипты; PowerShell-обвязка для VM удалена.

## 4. Ansible (настройка VM)
После создания VM можно запустить playbook'и:
- `install_docker.yml` - установка Docker + kubectl + Minikube;
- `deploy_flowboard.yml` - применение k8s-манифестов, обновление образов, smoke-тест.

## 5. Контейнеризация и compose
Собраны отдельные Dockerfile для backend/frontend и compose-окружение минимум из 3 сервисов:
- `backend`
- `frontend`
- `postgres`

Локальная проверка:

```bash
docker compose up --build
```

## 6. Публикация образов в registry (из CI)
В workflow `.github/workflows/ci.yml` есть job `docker-publish`, который:
- собирает backend/frontend образ,
- пушит в GHCR:
  - `ghcr.io/<owner>/<repo>/backend:latest`
  - `ghcr.io/<owner>/<repo>/frontend:latest`

## 7. Итог
ЛР2 переписана под локальную машину:
- IaC выполнен через Terraform для локальной VM,
- конфигурация автоматизирована через Ansible,
- контейнеризация и multi-service окружение реализованы,
- образы автоматически сохраняются в облачном registry через CI.
