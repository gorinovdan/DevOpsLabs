# Лабораторная работа №3

## Тема
Локальное развёртывание `FlowBoard` в `Minikube` с `HPA`, `Prometheus`, `Grafana` и idempotent `CI/CD` через `GitHub Actions` + self-hosted runner.

## 1. Что реализовано
- приложение из `LAB1` и контейнеризация из `LAB2` продолжены до Kubernetes-сценария;
- backend, frontend и PostgreSQL разворачиваются в namespace `flowboard`;
- backend масштабируется через `HorizontalPodAutoscaler` по CPU с target `15%`;
- backend экспортирует Prometheus-метрики на `/metrics`;
- локально разворачиваются `Prometheus`, `Grafana`, `kube-state-metrics`;
- весь цикл `build/test/publish/deploy/update/verify` выполняется bash-скриптами и используется из `GitHub Actions`;
- после deploy автоматически поднимаются локальные `port-forward`:
  - `http://127.0.0.1:18081` - frontend
  - `http://127.0.0.1:18080/health` - backend
  - `http://127.0.0.1:13000` - Grafana
  - `http://127.0.0.1:19090` - Prometheus

## 2. Основные bash-скрипты
- `scripts/deploy_minikube.sh` - основной idempotent deploy/update в `minikube`;
- `scripts/deploy_minikube_local.sh` - локальный entrypoint для полного сценария `build -> deploy -> observability -> smoke`;
- `scripts/run_local_cicd.sh` - локальная реализация pipeline, которую вызывает self-hosted GitHub runner;
- `scripts/enable_observability_minikube.sh` - установка и обновление `Prometheus + Grafana + kube-state-metrics`;
- `scripts/verify_observability_minikube.sh` - проверка health, dashboard provisioning и scrape targets;
- `scripts/smoke_test_minikube.sh` - smoke CRUD через frontend reverse proxy;
- `scripts/load_test_backend_hpa.sh` - нагрузочный тест backend для проверки HPA;
- `scripts/stop_minikube_local.sh` - остановка `port-forward` и `minikube`;
- `scripts/configure_github_runner.sh` и `scripts/start_github_runner.sh` - настройка и запуск локального GitHub Actions runner.

## 3. Локальный deploy
Полный локальный прогон:

```bash
./scripts/deploy_minikube_local.sh
```

Этот entrypoint по умолчанию:
- поднимает `minikube`, если он ещё не запущен;
- собирает backend и frontend локально host-toolchain'ом;
- собирает runtime-образы с локальными hash-тегами;
- загружает их в `minikube`;
- включает `metrics-server`;
- разворачивает monitoring stack;
- применяет манифесты приложения;
- поднимает локальные `port-forward`;
- запускает smoke-тест.

Если нужно развернуть не локально собранные образы, а уже опубликованные Docker-образы из `LAB2`/`CI`, используется основной deploy-скрипт:

```bash
BUILD_LOCAL=0 \
BACKEND_IMAGE=ghcr.io/<owner>/<repo>/backend:<tag> \
FRONTEND_IMAGE=ghcr.io/<owner>/<repo>/frontend:<tag> \
RUN_SMOKE_TEST=1 \
ENABLE_PORT_FORWARD=1 \
./scripts/deploy_minikube.sh
```

`deploy_minikube.sh` работает идемпотентно:
- неизменные манифесты не переапплаиваются без необходимости;
- уже загруженные образы не грузятся повторно;
- существующие `port-forward` переиспользуются;
- повторный запуск теми же параметрами выполняет корректный update без ручного вмешательства.

Повторный deploy тем же entrypoint:

```bash
./scripts/deploy_minikube_local.sh
```

## 4. Доступ к приложению
При `ENABLE_PORT_FORWARD=1` проброс портов делается автоматически самим deploy-скриптом.

Проверка:

```bash
curl -fsS http://127.0.0.1:18081 >/dev/null
curl -fsS http://127.0.0.1:18080/health
curl -fsS http://127.0.0.1:13000/api/health
curl -fsS http://127.0.0.1:19090/-/healthy
```

Smoke-тест:

```bash
./scripts/smoke_test_minikube.sh
```

Остановка локального стенда:

```bash
./scripts/stop_minikube_local.sh
```

Полное удаление кластера:

```bash
MINIKUBE_ACTION=delete PURGE=1 ./scripts/stop_minikube_local.sh
```

## 5. HPA
Манифест backend HPA:

```text
deploy/k8s/backend-hpa.yaml
```

Параметры:
- `minReplicas: 1`
- `maxReplicas: 5`
- `averageUtilization: 15`

Проверка HPA:

```bash
kubectl -n flowboard get hpa
./scripts/load_test_backend_hpa.sh
```

Во время проверки backend получает нагрузку, и `backend-hpa` увеличивает число pod'ов выше `1`, если средняя CPU-утилизация превышает target `15%`.

Если нужен встроенный HPA-тест сразу после deploy:

```bash
RUN_HPA_VALIDATION=1 ./scripts/deploy_minikube_local.sh
```

В `CI/CD` HPA-проверка по умолчанию отключена и включается вручную через `workflow_dispatch`, чтобы не тормозить каждый обычный прогон.

## 6. Monitoring
Monitoring stack описан в:

```text
deploy/k8s/monitoring.yaml
```

Установка отдельно:

```bash
./scripts/enable_observability_minikube.sh
```

После deploy доступны:
- Grafana: `http://127.0.0.1:13000`
- Prometheus: `http://127.0.0.1:19090`

Dashboard `FlowBoard Overview` показывает:
- HTTP requests по backend pod'ам;
- inflight requests по backend pod'ам;
- latency по маршрутам;
- readiness backend pod'ов;
- current/desired replicas у `backend-hpa`;
- desired/available replicas у backend deployment.

Проверка observability:

```bash
./scripts/verify_observability_minikube.sh
```

Скрипт подтверждает:
- `Grafana /api/health`;
- наличие dashboard `flowboard-overview`;
- `Prometheus /-/healthy`;
- scrape backend pod'ов;
- scrape `kube-state-metrics`;
- наличие application и Kubernetes state metrics, нужных dashboard'у.

## 7. CI/CD
Workflow:

```text
.github/workflows/ci.yml
```

Текущая структура workflow:
- `changes` - быстрый job на `ubuntu-latest`, который определяет, что реально изменилось;
- `local-cicd` - основной self-hosted job на локальном runner с labels `[self-hosted, macOS, minikube-local]`.

`local-cicd` не гоняет несколько отдельных job'ов для backend/frontend, а запускает единый локальный pipeline:

```text
scripts/run_local_cicd.sh
```

Этот pipeline:
- проверяет backend и frontend только если это нужно по changed paths или manual run;
- локально собирает backend/frontend runtime images;
- пушит образы в `GHCR` отдельным publish-этапом;
- деплоит в локальный `minikube` из `GHCR` образов с SHA-tag;
- выполняет повторный deploy тем же скриптом для проверки идемпотентности;
- проверяет smoke;
- проверяет observability;
- при ручном запуске может дополнительно прогнать HPA validation.

По умолчанию в workflow включён автопроброс портов:

```text
ENABLE_PORT_FORWARD=1
```

Поэтому после успешного `local-cicd` run локально остаются доступны:
- `http://127.0.0.1:18081`
- `http://127.0.0.1:18080/health`
- `http://127.0.0.1:13000`
- `http://127.0.0.1:19090`

Для self-hosted runner'а исправлен важный нюанс: detached `kubectl port-forward` запускаются без `RUNNER_TRACKING_ID`, поэтому GitHub Actions не убивает их после завершения job.

Подготовка локального runner:

```bash
./scripts/configure_github_runner.sh
./scripts/start_github_runner.sh
```

Полный ручной запуск workflow с HPA:

```bash
gh workflow run "CI/CD" -f run_hpa_validation=true
```

## 8. Что проверено
- `go test ./...` в `backend` проходит;
- `npm test` и `npm run build` в `frontend` проходят;
- локальный deploy одним скриптом проходит;
- повторный idempotent redeploy проходит;
- smoke-тест CRUD через frontend reverse proxy проходит;
- HPA увеличивает число backend pod'ов при нагрузке;
- `Prometheus`, `Grafana`, `kube-state-metrics` поднимаются и проходят health-check;
- dashboard provisioning в Grafana проходит автоматически;
- self-hosted GitHub Actions runner выполняет полный deploy/update в `minikube`;
- после завершения GitHub Actions локальные порты `18081` и `18080` остаются подняты.

## 9. Итог по требованиям LAB3
Требование 2 выполнено:
- `Minikube` поднимается локально;
- приложение запускается в Kubernetes из Docker-образов, подготовленных в `LAB2` или опубликованных через `CI`.

Требование 3 выполнено:
- backend масштабируется через `HPA`;
- target по CPU выставлен на `15%`;
- масштабирование проверяется нагрузочным bash-скриптом.

Требование 4 выполнено:
- `Prometheus` и `Grafana` развёрнуты;
- backend отдаёт метрики на `/metrics`;
- dashboard показывает состояние pod'ов, запросов и реплик.

Требование 5 выполнено:
- в `CI/CD` есть отдельный publish-этап в рамках `local-cicd`, который пушит Docker-образы в `GHCR`;
- deploy использует уже опубликованные образы по SHA-tag.

## 10. Замечание по первому прогону
На полностью холодной машине самые долгие шаги - это не манифесты приложения, а загрузка системных образов `minikube`, `metrics-server`, `Prometheus`, `Grafana`, `kube-state-metrics`. После прогрева локального Docker/Minikube-кэша повторные deploy/update заметно быстрее.
