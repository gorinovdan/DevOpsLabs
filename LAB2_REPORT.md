# Лабораторная работа №2

## 1. Цель работы
Изучить и применить на практике:
1. Инфраструктуру как код (Terraform) для развёртывания VM в облаке.
2. Конфигурационное управление (Ansible) для автоматической установки Docker на VM.
3. Контейнеризацию backend/frontend, сборку multi-service окружения через Docker Compose и публикацию образов в облачный Docker Registry.

## 2. Выполнение работы
Исходный проект уже содержал:
- backend на Go;
- frontend на React/Vite;
- тесты backend/frontend;
- базовый `docker-compose.yml` и Dockerfile для backend/frontend.

### 2.1 Реализованные артефакты
#### 2.1.1 Terraform
- [`infra/terraform/versions.tf`](infra/terraform/versions.tf)
- [`infra/terraform/variables.tf`](infra/terraform/variables.tf)
- [`infra/terraform/main.tf`](infra/terraform/main.tf)
- [`infra/terraform/outputs.tf`](infra/terraform/outputs.tf)
- [`infra/terraform/terraform.tfvars.example`](infra/terraform/terraform.tfvars.example)

Реализованные ресурсы:
- [`twc_ssh_key`](infra/terraform/main.tf) - импорт публичного SSH-ключа в Timeweb;
- [`twc_server`](infra/terraform/main.tf) - создание VM;
- [`twc_server_ip`](infra/terraform/main.tf) - выделение публичного IPv4 для доступа по SSH/HTTP.

#### 2.1.2 Ansible
- [`infra/ansible/playbooks/install_docker.yml`](infra/ansible/playbooks/install_docker.yml)
- [`infra/ansible/playbooks/deploy_flowboard.yml`](infra/ansible/playbooks/deploy_flowboard.yml)
- [`infra/ansible/templates/compose.env.j2`](infra/ansible/templates/compose.env.j2)
- [`infra/ansible/ansible.cfg`](infra/ansible/ansible.cfg)

#### 2.1.3 Контейнеризация и деплой
- [`backend/Dockerfile`](backend/Dockerfile) (backend image)
- [`frontend/Dockerfile`](frontend/Dockerfile) (frontend image)
- [`deploy/docker-compose.prod.yml`](deploy/docker-compose.prod.yml) (3 сервиса: `backend`, `frontend`, `postgres`)
- [`scripts/build_and_push.sh`](scripts/build_and_push.sh) (сборка/пуш, плюс проверка существования образов в registry)

#### 2.1.4 Единый идемпотентный сценарий
- [`scripts/deploy_idempotent.sh`](scripts/deploy_idempotent.sh)

Скрипт выполняет полный pipeline:
1. Проверка/установка зависимостей на control-host.
2. Подготовка SSH-ключа.
3. Terraform `init/validate/apply`.
4. Ожидание готовности VM и SSH.
5. Сборка/публикация образов в registry (или skip, если уже есть).
6. Ansible установка Docker.
7. Условный deploy stack (skip, если нужные образы уже запущены).
8. Smoke-тест API.

### 2.2 Архитектура целевого окружения
После деплоя на VM развёрнуты контейнеры:
1. `flowboard-postgres-1` - база данных PostgreSQL.
2. `flowboard-backend-1` - REST API на порту `8080`.
3. `flowboard-frontend-1` - nginx + статическая сборка frontend на порту `80`.

Сеть:
- `frontend -> backend` по внутреннему имени сервиса.
- `backend -> postgres` по внутреннему имени сервиса.

### 2.3 Результаты развёртывания в облаке
Terraform outputs (фактические):
- `server_id = 6754645`
- `server_name = flowboard-lab-vm`
- `server_status = on`
- `server_main_ipv4 = 89.223.69.70`
- `ssh_command = ssh root@89.223.69.70`

Проверка доступности:
- Frontend: `http://89.223.69.70/`
- API (через nginx): `http://89.223.69.70/api/insights`
- API (напрямую): `http://89.223.69.70:8080/api/tasks`

### 2.4 Публикация образов в cloud registry
Для теста использован cloud registry `ttl.sh`:
- `ttl.sh/flowboard-idempotent-lab-20260226-backend:24h`
- `ttl.sh/flowboard-idempotent-lab-20260226-frontend:24h`
В GitHub Actions используется GHCR

## 3. Итог
Все задачи лабораторной выполнены:
1. VM развёрнута через Terraform (IaC).
2. Docker устанавливается через Ansible.
3. Backend и frontend контейнеризованы, создан docker compose минимум из 3 сервисов, образы публикуются в облачный registry.
4. Подготовлен и протестирован единый идемпотентный сценарий полного развёртывания.
