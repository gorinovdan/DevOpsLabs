# Лабораторная работа №3 (Minikube + GitHub Runner)

## 1. Цель
- Развернуть приложение в Kubernetes (локально через Minikube).
- Настроить HPA для backend по CPU.
- Подключить мониторинг Prometheus + Grafana.
- Выполнять деплой через GitHub Actions на self-hosted runner.

## 2. Требования
- Docker Desktop
- kubectl
- minikube
- helm
- self-hosted GitHub Runner на локальной машине

Запуск кластера:

```bash
minikube start --driver=docker
```

## 3. Деплой в Minikube
Windows PowerShell:

```powershell
.\scripts\deploy_minikube.ps1
```

Linux/macOS:

```bash
./scripts/deploy_minikube.sh
```

Скрипт:
- применяет манифесты из `deploy/k8s`,
- включает `metrics-server`,
- устанавливает `kube-prometheus-stack` (Grafana + Prometheus),
- обновляет образы backend/frontend,
- дожидается rollout и выводит `pods,svc,hpa`.

## 4. HPA
Backend HPA: `deploy/k8s/backend-hpa.yaml`
- target CPU: `15%`
- min/max replicas: `1/5`

Проверка:

```bash
kubectl -n flowboard get hpa
```

Пример нагрузки:

```bash
kubectl -n flowboard run loadgen --rm -it --image=busybox --restart=Never -- /bin/sh -c "while true; do wget -q -O- http://backend:8080/api/tasks >/dev/null; done"
```

## 5. Мониторинг
Проверка namespace:

```bash
kubectl -n monitoring get pods
```

Доступ:

```bash
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 13000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 19090:9090
```

- Grafana: `http://127.0.0.1:13000`
- Prometheus: `http://127.0.0.1:19090`

## 6. GitHub Actions + self-hosted runner
Workflow: `.github/workflows/ci.yml`

CD job:
- `deploy-minikube` (runs-on: `[self-hosted, windows]`)
- берёт образы из `docker-publish`
- запускает `scripts/deploy_minikube.ps1`
- выполняет smoke-тест `GET /api/insights` и `GET /api/tasks`

## 7. Итог
ЛР3 полностью переведена в локальный контур: Kubernetes поднят через Minikube, backend масштабируется через HPA, мониторинг работает через Prometheus/Grafana, деплой выполняется GitHub Actions job на локальном self-hosted runner.
