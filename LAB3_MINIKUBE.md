# Лабораторная работа №3 (Minikube, HPA, Prometheus, Grafana)

## 1. Что сделано
- приложение `FlowBoard` из `LAB1` и контейнеризация из `LAB2` продолжены до локального Kubernetes-сценария;
- backend и frontend разворачиваются в `minikube`, PostgreSQL работает внутри кластера;
- backend масштабируется через `HorizontalPodAutoscaler` по CPU с целевым порогом `15%`;
- backend экспортирует Prometheus-метрики на `/metrics`;
- добавлены bash-скрипты для полного локального цикла: deploy, smoke, HPA load test, observability.

## 2. Новые bash-скрипты
- `scripts/deploy_minikube.sh` - основной idempotent deploy в `minikube`;
- `scripts/deploy_minikube_local.sh` - единый локальный entrypoint `build -> deploy -> observability -> smoke`;
- `scripts/smoke_test_minikube.sh` - проверка CRUD через frontend reverse proxy;
- `scripts/load_test_backend_hpa.sh` - отдельная нагрузка на backend для проверки HPA;
- `scripts/enable_observability_minikube.sh` - установка `Prometheus + Grafana` в namespace `monitoring`.

## 3. Локальный deploy
Полный локальный прогон:

```bash
./scripts/deploy_minikube_local.sh
```

По умолчанию скрипт:
- поднимает `minikube`, если он ещё не запущен;
- собирает backend локально через host `go`, а frontend через host `npm`;
- упаковывает runtime-образы с content-hash тегами вида `flowboard-backend:local-<hash>` и `flowboard-frontend:local-<hash>`;
- загружает их в `minikube`;
- применяет манифесты из `deploy/k8s`;
- поднимает `metrics-server`, `Prometheus` и `Grafana`;
- запускает smoke-тест.

Сценарий идемпотентный:
- повторный запуск с тем же исходным кодом не пересобирает backend/frontend образы заново;
- повторный запуск повторно применяет те же манифесты через `kubectl apply`;
- HPA-нагрузка не запускается по умолчанию, потому что она сознательно меняет runtime-состояние и вынесена в отдельный шаг.

Более короткий повторный deploy без пересборки:

```bash
BUILD_LOCAL=0 \
RUN_SMOKE_TEST=1 \
./scripts/deploy_minikube.sh
```

## 4. Smoke и доступ
Smoke-тест идёт через `kubectl port-forward`, поэтому не зависит от особенностей `minikube` driver на macOS:

```bash
./scripts/smoke_test_minikube.sh
```

Ручной доступ:

```bash
kubectl -n flowboard port-forward svc/frontend 18081:80
kubectl -n flowboard port-forward svc/backend 18080:8080
```

- Frontend: `http://127.0.0.1:18081`
- Backend: `http://127.0.0.1:18080`

## 5. HPA
Манифест: `deploy/k8s/backend-hpa.yaml`

- `minReplicas: 1`
- `maxReplicas: 5`
- `averageUtilization: 15`

Проверка:

```bash
kubectl -n flowboard get hpa
./scripts/load_test_backend_hpa.sh
```

Если нужен именно полный deploy со встроенной HPA-проверкой, она включается явно:

```bash
RUN_HPA_VALIDATION=1 ./scripts/deploy_minikube_local.sh
```

## 6. Monitoring
Backend экспортирует Prometheus-метрики на `/metrics`.
Prometheus и Grafana разворачиваются прямым манифестом:

```text
deploy/k8s/monitoring.yaml
```

Установка observability:

```bash
./scripts/enable_observability_minikube.sh
```

Доступ после установки:

```bash
kubectl -n monitoring port-forward svc/grafana 13000:80
kubectl -n monitoring port-forward svc/prometheus 19090:9090
```

- Grafana: `http://127.0.0.1:13000`
- Prometheus: `http://127.0.0.1:19090`

## 7. Что проверено локально
- `go test ./...` в `backend` проходит;
- `npm test` и `npm run build` в `frontend` проходят;
- локальный `minikube` deploy одним entrypoint проходит;
- smoke-тест CRUD через frontend reverse proxy проходит;
- HPA-проверка проходит как отдельный opt-in шаг;
- манифесты HPA и observability приведены к воспроизводимому локальному сценарию.

## 8. Важное замечание
На полностью холодной машине самые долгие шаги - не манифесты приложения, а докачка системных образов `minikube`, `metrics-server`, `Prometheus/Grafana`. Если локальный Docker/Minikube кэш пустой, первый прогон observability может занять заметно больше времени, чем сам deploy приложения.
