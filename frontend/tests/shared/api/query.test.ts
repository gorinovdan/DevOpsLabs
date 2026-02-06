import { describe, expect, it } from "vitest";
import { buildQuery } from "../../../src/shared/api/query";

describe("query", () => {
  it("builds query params", () => {
    const query = buildQuery({
      statuses: ["todo", "done"],
      priorities: ["high"],
      owner: "alex",
      tag: "devops",
      query: "pipeline",
      sortBy: "score",
      order: "asc",
    });

    expect(query).toContain("status=todo%2Cdone");
    expect(query).toContain("priority=high");
    expect(query).toContain("owner=alex");
    expect(query).toContain("tag=devops");
    expect(query).toContain("q=pipeline");
    expect(query).toContain("sort=score");
    expect(query).toContain("order=asc");
  });

  it("returns empty string for empty query", () => {
    expect(buildQuery({})).toBe("");
  });
});
