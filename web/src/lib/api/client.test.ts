import { describe, expect, it } from "vitest";
import { createApiClient } from "./client";

const serverInfo = {
  server_id: "01928f3e-7b2a-7c4d-9e1f-2a3b4c5d6e7f",
  name: "Home server",
  version: "0.1.0",
  api_version: "1.0",
  min_client_version: { android: "0.1.0", ios: "0.1.0", web: "0.1.0" },
  capabilities: ["tus"],
  upload: { tus_version: "1.0.0", max_file_bytes: 53687091200, recommended_chunk_bytes: 8388608 },
  time: "2026-10-03T12:00:00Z",
};

describe("createApiClient", () => {
  it("calls the server info endpoint and returns typed data", async () => {
    const paths: string[] = [];
    const fakeFetch = async (input: Request) => {
      paths.push(new URL(input.url).pathname);
      return new Response(JSON.stringify(serverInfo), { status: 200, headers: { "Content-Type": "application/json" } });
    };
    const client = createApiClient("https://localhost:8443", fakeFetch);
    const { data, error } = await client.GET("/api/v1/server/info");
    expect(error).toBeUndefined();
    expect(data?.api_version).toBe("1.0");
    expect(data?.upload.recommended_chunk_bytes).toBe(8388608);
    expect(paths).toEqual(["/api/v1/server/info"]);
  });
});
