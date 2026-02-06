import { beforeEach, describe, expect, it, vi } from "vitest";
import { request } from "../../../src/shared/api/client";

const response = (body: unknown, ok = true, status = 200) => ({
  ok,
  status,
  json: async () => body,
});

describe("client", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    global.fetch = vi.fn();
  });

  it("returns json for successful responses", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(response({ ok: true }));

    const result = await request<{ ok: boolean }>("/ping");

    expect(result).toEqual({ ok: true });
    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining("/ping"),
      expect.objectContaining({ headers: { "Content-Type": "application/json" } })
    );
  });

  it("returns undefined for 204 responses", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: true,
      status: 204,
      json: async () => ({}),
    });

    await expect(request<void>("/empty")).resolves.toBeUndefined();
  });

  it("throws api error messages", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(
      response({ error: "Boom" }, false, 400)
    );

    await expect(request("/boom")).rejects.toThrow("Boom");
  });

  it("throws fallback error messages", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      ok: false,
      status: 500,
      json: async () => {
        throw new Error("bad");
      },
    });

    await expect(request("/fallback")).rejects.toThrow("Ошибка запроса");
  });
});
