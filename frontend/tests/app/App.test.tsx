import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { MantineProvider } from "@mantine/core";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "../../src/app/App";
import { Insights, Task } from "../../src/entities/task/types";

const baseTask: Task = {
  id: 1,
  title: "Release prep",
  description: "Finalize the deployment runbook",
  status: "done",
  priority: "high",
  owner: "unassigned",
  effortHours: 4,
  tags: [],
  dueDate: null,
  startedAt: "2026-02-05T10:00:00Z",
  completedAt: "2026-02-05T12:00:00Z",
  createdAt: "2026-02-05T08:00:00Z",
  updatedAt: "2026-02-05T12:00:00Z",
  risk: "completed",
  score: 22.4,
  ageHours: 4,
  cycleHours: 2,
};

const activeTask: Task = {
  ...baseTask,
  id: 2,
  title: "Pipeline",
  description: "Set up CI jobs",
  status: "in_progress",
  priority: "medium",
  owner: "alex",
  effortHours: 6,
  tags: ["devops"],
  dueDate: "2026-02-10T12:00:00Z",
  startedAt: "2026-02-06T08:00:00Z",
  completedAt: null,
  updatedAt: "2026-02-06T09:00:00Z",
  risk: "on_track",
  score: 35.1,
  ageHours: 6,
  cycleHours: null,
};

const insights: Insights = {
  total: 2,
  byStatus: { done: 1, in_progress: 1 },
  byPriority: { high: 1, medium: 1 },
  overdue: 0,
  atRisk: 0,
  blocked: 0,
  done: 1,
  averageAgeHours: 5,
  averageCycleHours: 2,
  workloadHours: 6,
  focusIndex: 0.5,
};

const highInsights: Insights = {
  ...insights,
  total: 2,
  done: 2,
  focusIndex: 0.8,
};

const response = (body: unknown, ok = true, status = 200) => ({
  ok,
  status,
  json: async () => body,
});

function getInput(testId: string): HTMLInputElement {
  const element = screen.getByTestId(testId);
  if (element instanceof HTMLInputElement) {
    return element;
  }
  return element.querySelector("input") as HTMLInputElement;
}

function getSelect(testId: string): HTMLSelectElement {
  const element = screen.getByTestId(testId);
  if (element instanceof HTMLSelectElement) {
    return element;
  }
  return element.querySelector("select") as HTMLSelectElement;
}

function getTextarea(testId: string): HTMLTextAreaElement {
  const element = screen.getByTestId(testId);
  if (element instanceof HTMLTextAreaElement) {
    return element;
  }
  return element.querySelector("textarea") as HTMLTextAreaElement;
}

async function confirmPrimary(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByTestId("confirm-primary"));
}

async function confirmCancel(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByTestId("confirm-cancel"));
}

describe("App", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    global.fetch = vi.fn();
  });

  afterEach(() => {
    vi.useRealTimers();
    cleanup();
  });

  it("loads tasks and reopens a completed item", async () => {
    const user = userEvent.setup();
    const reopenedTask = { ...baseTask, status: "todo", risk: "unscheduled", completedAt: null, startedAt: null };

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([baseTask, activeTask]))
      .mockResolvedValueOnce(response(highInsights))
      .mockResolvedValueOnce(response(reopenedTask))
      .mockResolvedValueOnce(response([reopenedTask, activeTask]))
      .mockResolvedValueOnce(response({ ...insights, done: 0, focusIndex: 0 }));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    expect(await screen.findByText("Release prep")).toBeInTheDocument();
    expect(screen.getByText("Pipeline")).toBeInTheDocument();
    expect(screen.getByText("Не назначен")).toBeInTheDocument();
    expect(screen.getByText("Без срока")).toBeInTheDocument();
    expect(screen.getByText("без тегов")).toBeInTheDocument();
    expect(screen.getAllByText("devops").length).toBeGreaterThan(0);

    await user.click(screen.getByLabelText("Вернуть в работу"));
    await confirmPrimary(user);

    await waitFor(() => {
      expect(global.fetch).toHaveBeenCalledWith(
        expect.stringContaining("/api/tasks/1?force=true"),
        expect.any(Object)
      );
    });
  });

  it("creates and edits tasks with due dates", async () => {
    const user = userEvent.setup();
    const createdTask = {
      ...activeTask,
      id: 3,
      title: "New item",
      status: "blocked",
      priority: "critical",
      dueDate: "2026-02-09T10:00:00Z",
      tags: ["release"],
    };
    const updatedTask = { ...activeTask, title: "Pipeline v2", dueDate: null, risk: "unscheduled" };

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([activeTask]))
      .mockResolvedValueOnce(response({ ...insights, total: 1, done: 0, focusIndex: 0 }))
      .mockResolvedValueOnce(response(createdTask))
      .mockResolvedValueOnce(response([createdTask, activeTask]))
      .mockResolvedValueOnce(response({ ...insights, total: 2, done: 0, focusIndex: 0 }))
      .mockResolvedValueOnce(response(updatedTask))
      .mockResolvedValueOnce(response([createdTask, updatedTask]))
      .mockResolvedValueOnce(response({ ...insights, total: 2, done: 0, focusIndex: 0 }));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("Pipeline");

    await user.type(getInput("title-input"), "New item");
    await user.type(getTextarea("description-input"), "Add monitoring");
    await user.type(getInput("owner-input"), "Dana");
    await user.selectOptions(getSelect("status-select"), "blocked");
    await user.selectOptions(getSelect("priority-select"), "critical");
    await user.clear(getInput("effort-input"));
    await user.type(getInput("effort-input"), "12");

    const dueInput = getInput("due-date-input");
    await user.type(dueInput, "2026-02-09T10:00");

    const tagsInput = getInput("tags-input");
    await user.type(tagsInput, "release");
    await user.keyboard("{Enter}");

    await user.click(screen.getByRole("button", { name: "Создать задачу" }));

    await waitFor(() => {
      expect(screen.getByText("New item")).toBeInTheDocument();
    });

    await user.click(screen.getAllByRole("button", { name: "Редактировать" })[0]);

    const editTitle = getInput("title-input");
    await user.clear(editTitle);
    await user.type(editTitle, "Pipeline v2");

    await user.clear(getInput("due-date-input"));

    await user.click(screen.getByRole("button", { name: "Сохранить изменения" }));

    await waitFor(() => {
      expect(screen.getByText("Pipeline v2")).toBeInTheDocument();
    });
  });

  it("shows errors on load and validation", async () => {
    const user = userEvent.setup();

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response({ error: "Сбой" }, false, 400))
      .mockResolvedValueOnce(response(insights));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    expect(await screen.findByText("Сбой")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Создать задачу" }));
    await screen.findByText("Нужно указать название");
  });

  it("shows fallback load error for non-error failures", async () => {
    (global.fetch as ReturnType<typeof vi.fn>)
      .mockRejectedValueOnce("boom")
      .mockRejectedValueOnce("boom");

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    expect(await screen.findByText("Не удалось загрузить задачи")).toBeInTheDocument();
  });

  it("shows save error messages", async () => {
    const user = userEvent.setup();

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([]))
      .mockResolvedValueOnce(response({ ...insights, total: 0, done: 0, focusIndex: 0 }))
      .mockRejectedValueOnce("save boom")
      .mockResolvedValueOnce(response({ error: "Ошибка сохранения" }, false, 400));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("По заданным фильтрам задач пока нет.");

    await user.type(getInput("title-input"), "Broken");

    await user.click(screen.getByRole("button", { name: "Создать задачу" }));
    expect(await screen.findByText("Не удалось сохранить задачу")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Создать задачу" }));
    expect(await screen.findByText("Ошибка сохранения")).toBeInTheDocument();
  });

  it("prepares edit form for unassigned tasks", async () => {
    const user = userEvent.setup();
    const noDescriptionTask = { ...baseTask, description: "" };

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([noDescriptionTask]))
      .mockResolvedValueOnce(response(insights));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    expect(await screen.findByText("Нет описания")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Редактировать" }));

    expect(getInput("owner-input").value).toBe("");
    expect(getInput("due-date-input").value).toBe("");
  });

  it("handles delete cancel and delete failure", async () => {
    const user = userEvent.setup();
    const noDescriptionTask = { ...baseTask, description: "" };

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([noDescriptionTask]))
      .mockResolvedValueOnce(response(insights))
      .mockResolvedValueOnce(response({ error: "Ошибка удаления" }, false, 400));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("Release prep");

    await user.click(screen.getByLabelText("Удалить задачу"));
    await confirmCancel(user);

    await user.click(screen.getByLabelText("Удалить задачу"));
    await confirmPrimary(user);

    await waitFor(() => {
      expect(screen.getByText("Ошибка удаления")).toBeInTheDocument();
    });
  });

  it("handles delete fallback errors", async () => {
    const user = userEvent.setup();

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([baseTask]))
      .mockResolvedValueOnce(response(insights))
      .mockRejectedValueOnce("delete boom");

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("Release prep");

    await user.click(screen.getByLabelText("Удалить задачу"));
    await confirmPrimary(user);

    await waitFor(() => {
      expect(screen.getByText("Не удалось удалить задачу")).toBeInTheDocument();
    });
  });

  it("handles status change and reopen errors", async () => {
    const user = userEvent.setup();

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([baseTask, activeTask]))
      .mockResolvedValueOnce(response(insights))
      .mockResolvedValueOnce(response({ error: "Ошибка статуса" }, false, 400))
      .mockResolvedValueOnce(response({ error: "Ошибка возврата" }, false, 400));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("Pipeline");

    await user.selectOptions(getSelect("status-change-2"), "done");
    await confirmPrimary(user);

    await waitFor(() => {
      expect(screen.getByText("Ошибка статуса")).toBeInTheDocument();
    });

    await user.selectOptions(getSelect("status-change-1"), "todo");
    await confirmPrimary(user);

    await waitFor(() => {
      expect(screen.getByText("Ошибка возврата")).toBeInTheDocument();
    });
  });

  it("handles status change and reopen fallback errors", async () => {
    const user = userEvent.setup();

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([baseTask, activeTask]))
      .mockResolvedValueOnce(response(insights))
      .mockRejectedValueOnce("status boom")
      .mockRejectedValueOnce("reopen boom");

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("Pipeline");

    await user.selectOptions(getSelect("status-change-2"), "done");
    await confirmPrimary(user);

    await waitFor(() => {
      expect(screen.getByText("Не удалось обновить статус")).toBeInTheDocument();
    });

    await user.click(screen.getByLabelText("Вернуть в работу"));
    await confirmPrimary(user);

    await waitFor(() => {
      expect(global.fetch).toHaveBeenCalledTimes(4);
    });
  });

  it("updates status and deletes tasks successfully", async () => {
    const user = userEvent.setup();
    const updatedTask = { ...activeTask, status: "blocked", risk: "blocked" };

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([baseTask, activeTask]))
      .mockResolvedValueOnce(response({ ...insights, total: 2, done: 1, focusIndex: 0.5 }))
      .mockResolvedValueOnce(response(updatedTask))
      .mockResolvedValueOnce(response([baseTask, updatedTask]))
      .mockResolvedValueOnce(response({ ...insights, total: 2, done: 1, focusIndex: 0.5 }))
      .mockResolvedValueOnce(response({}))
      .mockResolvedValueOnce(response([updatedTask]))
      .mockResolvedValueOnce(response({ ...insights, total: 1, done: 0, focusIndex: 0.5 }));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("Release prep");

    await user.selectOptions(getSelect("status-change-2"), "blocked");
    await confirmPrimary(user);

    await waitFor(() => {
      expect(getSelect("status-change-2").value).toBe("blocked");
    });

    await user.click(screen.getAllByLabelText("Удалить задачу")[0]);
    await confirmPrimary(user);

    await waitFor(() => {
      expect(screen.queryByText("Release prep")).not.toBeInTheDocument();
    });
  });

  it("updates filters and shows empty state", async () => {
    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([]))
      .mockResolvedValueOnce(response({ ...insights, total: 0, done: 0, focusIndex: 0 }))
      .mockResolvedValueOnce(response([]))
      .mockResolvedValueOnce(response({ ...insights, total: 0, done: 0, focusIndex: 0 }));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("По заданным фильтрам задач пока нет.");

    fireEvent.change(getInput("filter-owner"), { target: { value: "alex" } });
    fireEvent.change(getInput("filter-tag"), { target: { value: "devops" } });
    fireEvent.change(getInput("filter-query"), { target: { value: "pipe" } });

    fireEvent.change(getSelect("filter-sort"), { target: { value: "priority" } });
    fireEvent.change(getSelect("filter-order"), { target: { value: "asc" } });
    fireEvent.change(getSelect("filter-status"), { target: { value: "todo" } });
    fireEvent.change(getSelect("filter-priority"), { target: { value: "high" } });
    fireEvent.change(getSelect("filter-status"), { target: { value: "" } });
    fireEvent.change(getSelect("filter-priority"), { target: { value: "" } });
  });

  it("refreshes data when sync is clicked", async () => {
    const user = userEvent.setup();

    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response([]))
      .mockResolvedValueOnce(response({ ...insights, total: 0, done: 0, focusIndex: 0 }))
      .mockResolvedValueOnce(response([]))
      .mockResolvedValueOnce(response({ ...insights, total: 0, done: 0, focusIndex: 0 }));

    render(
      <MantineProvider>
        <App />
      </MantineProvider>
    );

    await screen.findByText("По заданным фильтрам задач пока нет.");

    await user.click(screen.getByRole("button", { name: "Обновить" }));

    await waitFor(() => {
      expect(global.fetch).toHaveBeenCalledTimes(4);
    });
  });
});
