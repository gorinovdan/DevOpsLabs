const API_BASE = import.meta.env.VITE_API_URL ?? "http://localhost:8080";

export async function request<T>(path: string, options?: RequestInit): Promise<T> {
  const response = await fetch(`${API_BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...options,
  });

  if (!response.ok) {
    const body = await response.json().catch(() => ({}));
    const message = body?.error || "Ошибка запроса";
    throw new Error(message);
  }

  if (response.status === 204) {
    return undefined as T;
  }

  return response.json() as Promise<T>;
}
