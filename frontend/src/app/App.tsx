import {
  ActionIcon,
  AppShell,
  Badge,
  Box,
  Button,
  Card,
  Container,
  Divider,
  Group,
  LoadingOverlay,
  Modal,
  NativeSelect,
  NumberInput,
  Paper,
  Progress,
  RingProgress,
  SimpleGrid,
  Stack,
  TagsInput,
  Text,
  Textarea,
  TextInput,
  ThemeIcon,
  Title,
  Tooltip,
} from "@mantine/core";
import { useDebouncedValue } from "@mantine/hooks";
import {
  IconAlertTriangle,
  IconBolt,
  IconCheck,
  IconFilter,
  IconPlus,
  IconRefresh,
  IconTrash,
} from "@tabler/icons-react";
import { useEffect, useMemo, useState } from "react";
import type { ReactNode } from "react";
import { createTask, deleteTask, listTasks, updateTask } from "../features/tasks/api";
import { getInsights } from "../features/insights/api";
import { Insights, RiskLevel, Task, TaskFilters, TaskPriority, TaskStatus } from "../entities/task/types";

const statusOptions: Array<{ value: TaskStatus; label: string; description: string }> = [
  { value: "todo", label: "К выполнению", description: "Задачи в очереди" },
  { value: "in_progress", label: "В работе", description: "Активные задачи" },
  { value: "blocked", label: "Заблокировано", description: "Нужна помощь" },
  { value: "done", label: "Готово", description: "Выполнено" },
];

const statusLabels: Record<TaskStatus, string> = {
  todo: "К выполнению",
  in_progress: "В работе",
  blocked: "Заблокировано",
  done: "Готово",
};

const priorityOptions: Array<{ value: TaskPriority; label: string }> = [
  { value: "low", label: "Низкий" },
  { value: "medium", label: "Средний" },
  { value: "high", label: "Высокий" },
  { value: "critical", label: "Критический" },
];

const priorityLabels: Record<TaskPriority, string> = {
  low: "Низкий",
  medium: "Средний",
  high: "Высокий",
  critical: "Критический",
};

const sortOptions = [
  { value: "score", label: "Индекс" },
  { value: "priority", label: "Приоритет" },
  { value: "due_date", label: "Срок" },
  { value: "updated_at", label: "Недавно обновлённые" },
  { value: "created_at", label: "Недавно созданные" },
  { value: "title", label: "Название" },
];

const orderOptions = [
  { value: "desc", label: "По убыванию" },
  { value: "asc", label: "По возрастанию" },
];

const riskLabels: Record<RiskLevel, string> = {
  on_track: "В графике",
  at_risk: "Есть риск",
  overdue: "Просрочено",
  unscheduled: "Без срока",
  blocked: "Заблокировано",
  completed: "Завершено",
};

const riskColors: Record<RiskLevel, string> = {
  on_track: "teal",
  at_risk: "orange",
  overdue: "red",
  unscheduled: "gray",
  blocked: "violet",
  completed: "blue",
};

const statusColors: Record<TaskStatus, string> = {
  todo: "gray",
  in_progress: "cyan",
  blocked: "violet",
  done: "green",
};

const priorityColors: Record<TaskPriority, string> = {
  low: "gray",
  medium: "blue",
  high: "orange",
  critical: "red",
};

const defaultFilters: TaskFilters = {
  statuses: [],
  priorities: [],
  owner: "",
  tag: "",
  query: "",
  sortBy: "score",
  order: "desc",
};

type FormState = {
  title: string;
  description: string;
  status: TaskStatus;
  priority: TaskPriority;
  owner: string;
  effortHours: number;
  dueDate: string;
  tags: string[];
};

const emptyForm: FormState = {
  title: "",
  description: "",
  status: "todo",
  priority: "medium",
  owner: "",
  effortHours: 1,
  dueDate: "",
  tags: [],
};

const dateFormatter = new Intl.DateTimeFormat("ru-RU", {
  dateStyle: "medium",
  timeStyle: "short",
});

const scoreFormatter = new Intl.NumberFormat("ru-RU", {
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
});

function formatDate(value?: string | null): string {
  if (!value) return "Без срока";
  return dateFormatter.format(new Date(value));
}

function toLocalInputValue(value?: string | null): string {
  if (!value) return "";
  const date = new Date(value);
  const offset = date.getTimezoneOffset();
  const local = new Date(date.getTime() - offset * 60000);
  return local.toISOString().slice(0, 16);
}

function formatOwner(value: string): string {
  return value === "unassigned" ? "Не назначен" : value;
}

function formatScore(score: number): string {
  return scoreFormatter.format(score);
}

function toPayload(formState: FormState) {
  const dueDate = formState.dueDate ? new Date(formState.dueDate).toISOString() : null;

  return {
    title: formState.title.trim(),
    description: formState.description.trim(),
    status: formState.status,
    priority: formState.priority,
    owner: formState.owner.trim(),
    effortHours: formState.effortHours,
    dueDate,
    tags: formState.tags,
  };
}

type ConfirmAction =
  | { kind: "delete"; task: Task }
  | { kind: "status"; task: Task; nextStatus: TaskStatus; force: boolean };

type ConfirmTone = "danger" | "primary";

type ConfirmMeta = {
  title: string;
  description: string;
  confirmLabel: string;
  tone: ConfirmTone;
  icon: ReactNode;
};

function buildConfirmMeta(action: ConfirmAction): ConfirmMeta {
  if (action.kind === "delete") {
    return {
      title: "Удалить задачу",
      description: `Удалить «${action.task.title}»? Это действие нельзя отменить.`,
      confirmLabel: "Удалить",
      tone: "danger",
      icon: <IconAlertTriangle size={20} />,
    };
  }

  const isReopen = action.task.status === "done" && action.nextStatus === "todo";
  const from = statusLabels[action.task.status];
  const to = statusLabels[action.nextStatus];

  return {
    title: isReopen ? "Вернуть в работу" : "Изменить статус",
    description: isReopen
      ? `Задача «${action.task.title}» снова перейдёт в работу и появится в очереди.`
      : `Изменить статус «${action.task.title}» с «${from}» на «${to}»?`,
    confirmLabel: isReopen ? "Вернуть в работу" : "Изменить статус",
    tone: "primary",
    icon: <IconCheck size={20} />,
  };
}

export default function App() {
  const [tasks, setTasks] = useState<Task[]>([]);
  const [insights, setInsights] = useState<Insights | null>(null);
  const [filters, setFilters] = useState<TaskFilters>(defaultFilters);
  const [editingTask, setEditingTask] = useState<Task | null>(null);
  const [formState, setFormState] = useState<FormState>(emptyForm);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [confirmAction, setConfirmAction] = useState<ConfirmAction | null>(null);
  const [confirmLoading, setConfirmLoading] = useState(false);

  const [debouncedQuery] = useDebouncedValue(filters.query, 300);

  const tagOptions = useMemo(() => {
    const tags = new Set<string>();
    tasks.forEach((task) => task.tags.forEach((tag) => tags.add(tag)));
    return Array.from(tags);
  }, [tasks]);

  const completionRate = insights ? Math.round(insights.focusIndex * 100) : 0;
  const confirmMeta = confirmAction ? buildConfirmMeta(confirmAction) : null;

  useEffect(() => {
    void refresh();
  }, [
    filters.statuses,
    filters.priorities,
    filters.owner,
    filters.tag,
    debouncedQuery,
    filters.sortBy,
    filters.order,
  ]);

  async function refresh() {
    setLoading(true);
    setError(null);
    const query = {
      ...filters,
      query: debouncedQuery,
    };
    try {
      const [tasksData, insightsData] = await Promise.all([
        listTasks(query),
        getInsights(query),
      ]);
      setTasks(tasksData);
      setInsights(insightsData);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Не удалось загрузить задачи");
      setInsights(null);
    } finally {
      setLoading(false);
    }
  }

  function resetForm() {
    setEditingTask(null);
    setFormState(emptyForm);
  }

  function handleEdit(task: Task) {
    setEditingTask(task);
    setFormState({
      title: task.title,
      description: task.description,
      status: task.status,
      priority: task.priority,
      owner: task.owner === "unassigned" ? "" : task.owner,
      effortHours: task.effortHours,
      dueDate: toLocalInputValue(task.dueDate),
      tags: task.tags,
    });
  }

  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault();

    if (!formState.title.trim()) {
      setError("Нужно указать название");
      return;
    }

    try {
      setError(null);
      if (editingTask) {
        const updated = await updateTask(editingTask.id, toPayload(formState));
        setTasks((prev) => prev.map((task) => (task.id === updated.id ? updated : task)));
      } else {
        const created = await createTask(toPayload(formState));
        setTasks((prev) => [created, ...prev]);
      }
      resetForm();
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Не удалось сохранить задачу");
    }
  }

  async function performDelete(task: Task) {
    try {
      await deleteTask(task.id);
      setTasks((prev) => prev.filter((item) => item.id !== task.id));
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Не удалось удалить задачу");
    }
  }

  async function performStatusChange(task: Task, status: TaskStatus, force = false) {
    try {
      const updated = await updateTask(task.id, { status }, force);
      setTasks((prev) => prev.map((item) => (item.id === updated.id ? updated : item)));
      await refresh();
    } catch (err) {
      setError(err instanceof Error ? err.message : "Не удалось обновить статус");
    }
  }

  function requestDelete(task: Task) {
    setConfirmAction({ kind: "delete", task });
  }

  function requestStatusChange(task: Task, status: TaskStatus, force = false) {
    setConfirmAction({ kind: "status", task, nextStatus: status, force });
  }

  function closeConfirm() {
    setConfirmAction(null);
    setConfirmLoading(false);
  }

  async function handleConfirm() {
    const action = confirmAction as ConfirmAction;
    setConfirmLoading(true);
    try {
      if (action.kind === "delete") {
        await performDelete(action.task);
      } else {
        await performStatusChange(action.task, action.nextStatus, action.force);
      }
    } finally {
      setConfirmLoading(false);
      setConfirmAction(null);
    }
  }

  return (
    <AppShell header={{ height: 72 }} padding={0} className="app-shell">
      <AppShell.Header className="app-header">
        <Container size="xl" className="header-content">
          <Group justify="space-between" align="center">
            <Box>
              <Text className="eyebrow">Лабораторная DevOps</Text>
              <Title order={2}>FlowBoard</Title>
            </Box>
            <Group gap="sm">
              <Button
                variant="light"
                leftSection={<IconRefresh size={18} />}
                onClick={() => void refresh()}
              >
                Обновить
              </Button>
              <Button leftSection={<IconPlus size={18} />} onClick={resetForm}>
                Новая задача
              </Button>
            </Group>
          </Group>
        </Container>
      </AppShell.Header>

      <AppShell.Main>
        <Container size="xl" className="main-grid">
          <GridLayout
            left={
              <Stack gap="lg">
                <Card className="glass-card" padding="lg" radius="xl">
                  <Group justify="space-between" align="center">
                    <Box>
                      <Text className="section-label">Пульс поставки</Text>
                      <Title order={3}>{completionRate}% фокуса</Title>
                      <Text size="sm" c="dimmed">
                        Доля выполненных задач от общего объёма.
                      </Text>
                    </Box>
                    <RingProgress
                      size={120}
                      thickness={10}
                      sections={[
                        {
                          value: completionRate,
                          color: completionRate > 65 ? "teal" : completionRate > 35 ? "orange" : "red",
                        },
                      ]}
                      label={
                        <Text ta="center" fw={600} size="lg">
                          {completionRate}%
                        </Text>
                      }
                    />
                  </Group>
                  <Divider my="md" />
                  <SimpleGrid cols={{ base: 2, md: 4 }} spacing="md">
                    <Metric label="Всего" value={insights?.total ?? 0} />
                    <Metric label="Просрочено" value={insights?.overdue ?? 0} accent="red" />
                    <Metric label="Заблокировано" value={insights?.blocked ?? 0} accent="violet" />
                    <Metric label="Нагрузка" value={`${insights?.workloadHours ?? 0} ч`} />
                  </SimpleGrid>
                  <Progress
                    mt="md"
                    value={completionRate}
                    radius="xl"
                    size="md"
                    color={completionRate > 65 ? "teal" : completionRate > 35 ? "orange" : "red"}
                  />
                </Card>

                <Card className="glass-card" padding="lg" radius="xl" withBorder>
                  <Stack gap="md">
                    <Box>
                      <Text className="section-label">
                        {editingTask ? "Редактирование" : "Новая задача"}
                      </Text>
                      <Title order={3}>
                        {editingTask ? "Обновить план выполнения" : "Спланировать следующий шаг"}
                      </Title>
                    </Box>

                    <form onSubmit={handleSubmit} className="form-stack" noValidate>
                      <TextInput
                        label="Название"
                        placeholder="Спроектировать CI пайплайн"
                        value={formState.title}
                        onChange={(event) =>
                          setFormState((prev) => ({ ...prev, title: event.currentTarget.value }))
                        }
                        data-testid="title-input"
                        required
                      />
                      <Textarea
                        label="Описание"
                        placeholder="Определить этапы, кэширование и передачу артефактов."
                        value={formState.description}
                        onChange={(event) =>
                          setFormState((prev) => ({ ...prev, description: event.currentTarget.value }))
                        }
                        minRows={3}
                        data-testid="description-input"
                      />
                      <SimpleGrid cols={{ base: 1, md: 2 }} spacing="md">
                        <NativeSelect
                          label="Статус"
                          data={statusOptions.map((option) => ({
                            value: option.value,
                            label: option.label,
                          }))}
                          value={formState.status}
                          onChange={(event) =>
                            setFormState((prev) => ({
                              ...prev,
                              status: event.currentTarget.value as TaskStatus,
                            }))
                          }
                          data-testid="status-select"
                        />
                        <NativeSelect
                          label="Приоритет"
                          data={priorityOptions}
                          value={formState.priority}
                          onChange={(event) =>
                            setFormState((prev) => ({
                              ...prev,
                              priority: event.currentTarget.value as TaskPriority,
                            }))
                          }
                          data-testid="priority-select"
                        />
                        <TextInput
                          label="Ответственный"
                          placeholder="Участник команды"
                          value={formState.owner}
                          onChange={(event) =>
                            setFormState((prev) => ({ ...prev, owner: event.currentTarget.value }))
                          }
                          data-testid="owner-input"
                        />
                        <NumberInput
                          label="Трудозатраты (часы)"
                          min={1}
                          max={200}
                          value={formState.effortHours}
                          onChange={(value) =>
                            setFormState((prev) => ({
                              ...prev,
                              effortHours: typeof value === "number" ? value : 1,
                            }))
                          }
                          data-testid="effort-input"
                        />
                      </SimpleGrid>
                      <TextInput
                        label="Срок"
                        type="datetime-local"
                        placeholder="Выберите срок"
                        value={formState.dueDate}
                        onChange={(event) =>
                          setFormState((prev) => ({ ...prev, dueDate: event.currentTarget.value }))
                        }
                        data-testid="due-date-input"
                      />
                      <TagsInput
                        label="Теги"
                        data={tagOptions}
                        value={formState.tags}
                        onChange={(value) => setFormState((prev) => ({ ...prev, tags: value }))}
                        placeholder="Добавить теги"
                        data-testid="tags-input"
                      />
                      <Group justify="space-between" mt="md">
                        <Button type="submit" leftSection={<IconBolt size={18} />}>
                          {editingTask ? "Сохранить изменения" : "Создать задачу"}
                        </Button>
                        <Button variant="light" color="gray" onClick={resetForm}>
                          {editingTask ? "Отмена" : "Очистить"}
                        </Button>
                      </Group>
                    </form>
                  </Stack>
                </Card>
              </Stack>
            }
            right={
              <Stack gap="lg">
                <Card className="glass-card" padding="lg" radius="xl">
                  <Group justify="space-between">
                    <Box>
                      <Text className="section-label">Фильтры</Text>
                      <Title order={3}>Очередь разбора</Title>
                    </Box>
                    <IconFilter size={24} />
                  </Group>
                  <SimpleGrid cols={{ base: 1, md: 2 }} spacing="md" mt="md">
                    <NativeSelect
                      label="Статус"
                      data={[
                        { value: "", label: "Все" },
                        ...statusOptions.map((option) => ({ value: option.value, label: option.label })),
                      ]}
                      value={filters.statuses[0] || ""}
                      onChange={(event) =>
                        setFilters((prev) => ({
                          ...prev,
                          statuses: event.currentTarget.value
                            ? ([event.currentTarget.value] as TaskStatus[])
                            : [],
                        }))
                      }
                      data-testid="filter-status"
                    />
                    <NativeSelect
                      label="Приоритет"
                      data={[{ value: "", label: "Все" }, ...priorityOptions]}
                      value={filters.priorities[0] || ""}
                      onChange={(event) =>
                        setFilters((prev) => ({
                          ...prev,
                          priorities: event.currentTarget.value
                            ? ([event.currentTarget.value] as TaskPriority[])
                            : [],
                        }))
                      }
                      data-testid="filter-priority"
                    />
                    <TextInput
                      label="Ответственный"
                      placeholder="Поиск по ответственному"
                      value={filters.owner}
                      onChange={(event) =>
                        setFilters((prev) => ({ ...prev, owner: event.currentTarget.value }))
                      }
                      data-testid="filter-owner"
                    />
                    <TextInput
                      label="Тег"
                      placeholder="Фильтр по тегу"
                      value={filters.tag}
                      onChange={(event) => setFilters((prev) => ({ ...prev, tag: event.currentTarget.value }))}
                      data-testid="filter-tag"
                    />
                    <TextInput
                      label="Поиск"
                      placeholder="Поиск по названию или описанию"
                      value={filters.query}
                      onChange={(event) =>
                        setFilters((prev) => ({ ...prev, query: event.currentTarget.value }))
                      }
                      data-testid="filter-query"
                    />
                    <Group gap="xs">
                      <NativeSelect
                        label="Сортировка"
                        data={sortOptions}
                        value={filters.sortBy}
                        onChange={(event) =>
                          setFilters((prev) => ({ ...prev, sortBy: event.currentTarget.value }))
                        }
                        data-testid="filter-sort"
                      />
                      <NativeSelect
                        label="Порядок"
                        data={orderOptions}
                        value={filters.order}
                        onChange={(event) =>
                          setFilters((prev) => ({
                            ...prev,
                            order: event.currentTarget.value as "asc" | "desc",
                          }))
                        }
                        data-testid="filter-order"
                      />
                    </Group>
                  </SimpleGrid>
                </Card>

                <Card className="glass-card" padding="lg" radius="xl" withBorder>
                  <Group justify="space-between">
                    <Box>
                      <Text className="section-label">Доска задач</Text>
                      <Title order={3}>Очередь исполнения</Title>
                    </Box>
                    <Badge color="dark">{tasks.length} задач</Badge>
                  </Group>

                  <Box pos="relative" mt="md">
                    <LoadingOverlay visible={loading} />
                    {error && (
                      <Paper className="alert" p="sm">
                        <Group gap="xs">
                          <IconAlertTriangle size={18} />
                          <Text>{error}</Text>
                        </Group>
                      </Paper>
                    )}
                    {!loading && !error && tasks.length === 0 && (
                      <Paper className="empty" p="md">
                        <Group gap="sm">
                          <IconCheck size={20} />
                          <Text>По заданным фильтрам задач пока нет.</Text>
                        </Group>
                      </Paper>
                    )}
                    <Stack gap="md" mt="md" data-testid="task-list">
                      {tasks.map((task) => (
                        <Card
                          key={task.id}
                          className={`task-card task-card--${task.status}`}
                          radius="lg"
                          withBorder
                        >
                          <Group justify="space-between" align="flex-start">
                            <Box>
                              <Title order={4}>{task.title}</Title>
                              <Text size="sm" c="dimmed">
                                {task.description || "Нет описания"}
                              </Text>
                            </Box>
                            <Stack gap={6} align="flex-end">
                              <Badge color={statusColors[task.status]}>
                                {statusLabels[task.status]}
                              </Badge>
                              <Badge color={priorityColors[task.priority]} variant="light">
                                {priorityLabels[task.priority]}
                              </Badge>
                              <Badge color={riskColors[task.risk]} variant="outline">
                                {riskLabels[task.risk]}
                              </Badge>
                            </Stack>
                          </Group>

                          <SimpleGrid cols={{ base: 1, md: 3 }} spacing="sm" mt="md">
                            <Box>
                              <Text size="xs" c="dimmed">
                                Ответственный
                              </Text>
                              <Text fw={600}>{formatOwner(task.owner)}</Text>
                            </Box>
                            <Box>
                              <Text size="xs" c="dimmed">
                                Срок
                              </Text>
                              <Text fw={600}>{formatDate(task.dueDate)}</Text>
                            </Box>
                            <Box>
                              <Text size="xs" c="dimmed">
                                Индекс
                              </Text>
                              <Text fw={600}>{formatScore(task.score)}</Text>
                            </Box>
                          </SimpleGrid>

                          <Group gap="xs" mt="md">
                            {task.tags.length > 0 ? (
                              task.tags.map((tag) => (
                                <Badge key={tag} color="gray" variant="outline">
                                  {tag}
                                </Badge>
                              ))
                            ) : (
                              <Badge color="gray" variant="outline">
                                без тегов
                              </Badge>
                            )}
                          </Group>

                          <Group justify="space-between" mt="md" wrap="wrap">
                            <NativeSelect
                              data={statusOptions.map((option) => ({
                                value: option.value,
                                label: option.label,
                              }))}
                              value={task.status}
                              onChange={(event) => {
                                const nextStatus = event.currentTarget.value as TaskStatus;
                                const force = task.status === "done" && nextStatus === "todo";
                                requestStatusChange(task, nextStatus, force);
                              }}
                              data-testid={`status-change-${task.id}`}
                            />
                            <Group gap="xs">
                              {task.status === "done" && (
                                <Tooltip label="Вернуть в работу">
                                  <ActionIcon
                                    color="blue"
                                    variant="light"
                                    aria-label="Вернуть в работу"
                                    onClick={() => requestStatusChange(task, "todo", true)}
                                  >
                                    <IconRefresh size={18} />
                                  </ActionIcon>
                                </Tooltip>
                              )}
                              <Button variant="light" onClick={() => handleEdit(task)}>
                                Редактировать
                              </Button>
                              <ActionIcon
                                color="red"
                                variant="light"
                                aria-label="Удалить задачу"
                                onClick={() => requestDelete(task)}
                              >
                                <IconTrash size={18} />
                              </ActionIcon>
                            </Group>
                          </Group>
                        </Card>
                      ))}
                    </Stack>
                  </Box>
                </Card>
              </Stack>
            }
          />
        </Container>
      </AppShell.Main>

      <Modal
        opened={Boolean(confirmAction)}
        onClose={closeConfirm}
        centered
        size="lg"
        radius="lg"
        overlayProps={{ blur: 6, backgroundOpacity: 0.45 }}
        classNames={{
          content: "confirm-modal",
          header: "confirm-modal-header",
          title: "confirm-modal-title",
          body: "confirm-modal-body",
        }}
        title={
          confirmMeta ? (
            <Group gap="sm">
              <ThemeIcon
                color={confirmMeta.tone === "danger" ? "red" : "blue"}
                variant="light"
                radius="xl"
              >
                {confirmMeta.icon}
              </ThemeIcon>
              <Text fw={700}>{confirmMeta.title}</Text>
            </Group>
          ) : null
        }
      >
        {confirmAction && confirmMeta && (
          <Stack gap="md">
            <Text size="sm" c="dimmed">
              {confirmMeta.description}
            </Text>
            <Paper className="confirm-details" p="md" radius="lg">
              <Group justify="space-between" align="center">
                <Text fw={600}>{confirmAction.task.title}</Text>
                <Badge color={statusColors[confirmAction.task.status]} variant="light">
                  {statusLabels[confirmAction.task.status]}
                </Badge>
              </Group>
              <Text size="sm" c="dimmed" mt="xs">
                {confirmAction.task.description || "Нет описания"}
              </Text>
              <Group gap="xs" mt="xs" wrap="wrap">
                <Badge color={priorityColors[confirmAction.task.priority]} variant="outline">
                  Приоритет: {priorityLabels[confirmAction.task.priority]}
                </Badge>
                <Badge color="gray" variant="outline">
                  Срок: {formatDate(confirmAction.task.dueDate)}
                </Badge>
                <Badge color="gray" variant="outline">
                  Ответственный: {formatOwner(confirmAction.task.owner)}
                </Badge>
              </Group>
              {confirmAction.kind === "status" && (
                <Group gap="xs" mt="xs" wrap="wrap">
                  <Badge color={statusColors[confirmAction.nextStatus]}>
                    Новый статус: {statusLabels[confirmAction.nextStatus]}
                  </Badge>
                </Group>
              )}
            </Paper>
            <Group justify="space-between" mt="xs">
              <Button variant="light" color="gray" onClick={closeConfirm} data-testid="confirm-cancel">
                Отмена
              </Button>
              <Button
                color={confirmMeta.tone === "danger" ? "red" : "blue"}
                onClick={() => void handleConfirm()}
                loading={confirmLoading}
                data-testid="confirm-primary"
              >
                {confirmMeta.confirmLabel}
              </Button>
            </Group>
          </Stack>
        )}
      </Modal>
    </AppShell>
  );
}

function Metric({ label, value, accent }: { label: string; value: string | number; accent?: string }) {
  return (
    <Paper className="metric-card" p="sm" radius="md">
      <Text size="xs" c="dimmed">
        {label}
      </Text>
      <Text fw={700} c={accent}>
        {value}
      </Text>
    </Paper>
  );
}

function GridLayout({ left, right }: { left: ReactNode; right: ReactNode }) {
  return (
    <SimpleGrid cols={{ base: 1, md: 2 }} spacing="xl" className="grid-layout">
      <Stack gap="lg">{left}</Stack>
      <Stack gap="lg">{right}</Stack>
    </SimpleGrid>
  );
}
