import { request } from "../../shared/api/client";
import { buildQuery, TaskQuery } from "../../shared/api/query";
import { Task, TaskPriority, TaskStatus } from "../../entities/task/types";

export interface TaskPayload {
  title?: string;
  description?: string;
  status?: TaskStatus;
  priority?: TaskPriority;
  owner?: string;
  effortHours?: number;
  dueDate?: string | null;
  tags?: string[];
}

export function listTasks(query: TaskQuery = {}): Promise<Task[]> {
  return request<Task[]>(`/api/tasks${buildQuery(query)}`);
}

export function createTask(payload: TaskPayload): Promise<Task> {
  return request<Task>("/api/tasks", {
    method: "POST",
    body: JSON.stringify(payload),
  });
}

export function updateTask(id: number, payload: TaskPayload, force = false): Promise<Task> {
  const suffix = force ? "?force=true" : "";
  return request<Task>(`/api/tasks/${id}${suffix}`, {
    method: "PUT",
    body: JSON.stringify(payload),
  });
}

export function deleteTask(id: number): Promise<void> {
  return request<void>(`/api/tasks/${id}`, { method: "DELETE" });
}
