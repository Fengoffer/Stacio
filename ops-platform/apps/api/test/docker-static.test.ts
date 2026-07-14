import { execFileSync } from "node:child_process";
import { describe, expect, it } from "vitest";

describe("Docker production deployment static checks", () => {
  it("validates the Docker Compose, Dockerfiles, nginx proxy, env example, and ignore rules", () => {
    const output = execFileSync("npm", ["run", "verify:docker-static"], {
      cwd: process.cwd(),
      encoding: "utf8"
    });

    expect(output).toContain("docker-static: ok");
  });
});
