import createClient from "openapi-fetch";
import type { paths } from "./schema";

export type ApiClient = ReturnType<typeof createClient<paths>>;

export function createApiClient(baseUrl: string, fetchImpl?: (input: Request) => Promise<Response>): ApiClient {
  return createClient<paths>({ baseUrl, credentials: "include", ...(fetchImpl ? { fetch: fetchImpl } : {}) });
}
