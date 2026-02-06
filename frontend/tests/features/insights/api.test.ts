import { beforeEach, describe, expect, it, vi } from "vitest";
import { getInsights } from "../../../src/features/insights/api";

const response = (body: unknown, ok = true, status = 200) => ({
  ok,
  status,
  json: async () => body,
});

describe("insights api", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
    global.fetch = vi.fn();
  });

  it("getInsights includes query parameters", async () => {
    (global.fetch as ReturnType<typeof vi.fn>).mockResolvedValueOnce(response({ total: 0 }));

    await getInsights({ statuses: ["todo"] });

    expect(global.fetch).toHaveBeenCalledWith(
      expect.stringContaining("/api/insights?status=todo"),
      expect.any(Object)
    );
  });
});
