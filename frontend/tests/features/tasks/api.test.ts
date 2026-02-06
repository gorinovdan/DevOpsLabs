import { beforeEach, describe, expect, it, vi } from "vitest";
import { createTask, deleteTask, listTasks, updateTask } from "../../../src/features/tasks/api";

const response = (body: unknown, ok = true, status = 200) => ({
  ok,
  status,
  json: async () => body,
});

describe("tasks api", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    global.fetch = vi.fn();
  });

  it("listTasks includes query parameters", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(response([]));

    await listTasks({ statuses: ["todo"] });

    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining("/api/tasks?status=todo"),
      expect.any(Object)
    );
  });

  it("createTask and updateTask send payloads", async () => {
    (global.fetch as ReturnType<typeof vi.fn>)
      .mockResolvedValueOnce(response({ id: 1 }))
      .mockResolvedValueOnce(response({ id: 1 }))
      .mockResolvedValueOnce(response({ id: 2 }));

    await createTask({ title: "Ship" });
    await updateTask(1, { status: "done" }, true);
    await updateTask(2, { status: "blocked" });

    expect(global.fetch).toHaveBeenNthCalledWith(
      1,
      expect.stringContaining("/api/tasks"),
      expect.objectContaining({ method: "POST" })
    );
    expect(global.fetch).toHaveBeenNthCalledWith(
      2,
      expect.stringContaining("/api/tasks/1?force=true"),
      expect.objectContaining({ method: "PUT" })
    );

    const thirdCallUrl = (global.fetch as ReturnType<typeof vi.fn>).mock.calls[2][0] as string;
    expect(thirdCallUrl).toContain("/api/tasks/2");
    expect(thirdCallUrl).not.toContain("force=true");
  });

  it("deleteTask issues delete request", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: true,
      status: 204,
      json: async () => ({}),
    });

    await expect(deleteTask(1)).resolves.toBeUndefined();

    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining("/api/tasks/1"),
      expect.objectContaining({ method: "DELETE" })
    );
  });
});
