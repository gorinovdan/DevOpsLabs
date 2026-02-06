import { request } from "../../shared/api/client";
import { buildQuery, TaskQuery } from "../../shared/api/query";
import { Insights } from "../../entities/task/types";

export function getInsights(query: TaskQuery = {}): Promise<Insights> {
  return request<Insights>(`/api/insights${buildQuery(query)}`);
}
