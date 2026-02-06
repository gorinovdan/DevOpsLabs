import type { TaskFilters } from "../../entities/task/types";

export type TaskQuery = Partial<TaskFilters>;

export function buildQuery(query: TaskQuery): string {
  const params = new URLSearchParams();

  if (query.statuses && query.statuses.length > 0) {
    params.set("status", query.statuses.join(","));
  }
  if (query.priorities && query.priorities.length > 0) {
    params.set("priority", query.priorities.join(","));
  }
  if (query.owner) {
    params.set("owner", query.owner);
  }
  if (query.tag) {
    params.set("tag", query.tag);
  }
  if (query.query) {
    params.set("q", query.query);
  }
  if (query.sortBy) {
    params.set("sort", query.sortBy);
  }
  if (query.order) {
    params.set("order", query.order);
  }

  const queryString = params.toString();
  return queryString ? `?${queryString}` : "";
}
