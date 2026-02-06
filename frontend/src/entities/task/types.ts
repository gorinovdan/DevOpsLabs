export type TaskStatus = "todo" | "in_progress" | "blocked" | "done";
export type TaskPriority = "low" | "medium" | "high" | "critical";
export type RiskLevel = "on_track" | "at_risk" | "overdue" | "unscheduled" | "blocked" | "completed";

export interface Task {
  id: number;
  title: string;
  description: string;
  status: TaskStatus;
  priority: TaskPriority;
  owner: string;
  effortHours: number;
  tags: string[];
  dueDate?: string | null;
  startedAt?: string | null;
  completedAt?: string | null;
  createdAt: string;
  updatedAt: string;
  risk: RiskLevel;
  score: number;
  ageHours: number;
  cycleHours?: number | null;
}

export interface Insights {
  total: number;
  byStatus: Record<string, number>;
  byPriority: Record<string, number>;
  overdue: number;
  atRisk: number;
  blocked: number;
  done: number;
  averageAgeHours: number;
  averageCycleHours: number;
  workloadHours: number;
  focusIndex: number;
}

export interface TaskFilters {
  statuses: TaskStatus[];
  priorities: TaskPriority[];
  owner: string;
  tag: string;
  query: string;
  sortBy: string;
  order: "asc" | "desc";
}
