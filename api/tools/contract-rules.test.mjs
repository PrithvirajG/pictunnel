import { test } from "node:test";
import assert from "node:assert/strict";
import { checkContract } from "./contract-rules.mjs";

const problem = {
  description: "error",
  content: { "application/problem+json": { schema: { $ref: "#/components/schemas/Problem" } } },
};
const P = "/api/v1/things/{thing_id}";

function validDoc() {
  return {
    openapi: "3.0.3",
    info: { title: "t", version: "1" },
    paths: {
      [P]: {
        get: {
          operationId: "getThing",
          tags: ["assets"],
          parameters: [
            { name: "thing_id", in: "path", required: true, schema: { type: "string" } },
            { name: "page_token", in: "query", schema: { type: "string" } },
            { name: "Upload-Offset", in: "header", schema: { type: "integer" } },
          ],
          responses: {
            "200": { description: "ok", content: { "application/json": { schema: { $ref: "#/components/schemas/Thing" } } } },
            "404": { $ref: "#/components/responses/NotFound" },
          },
        },
        head: { operationId: "headThing", tags: ["assets"], responses: { "200": { description: "ok" }, "404": { description: "missing" } } },
      },
    },
    components: {
      schemas: {
        Problem: { type: "object", properties: { code: { type: "string" }, request_id: { type: "string" } } },
        Thing: {
          type: "object",
          properties: { size_bytes: { type: "integer" }, live_video: { type: "object", properties: { sha256: { type: "string" } } } },
        },
      },
      responses: { NotFound: problem },
    },
  };
}

test("a valid contract has no errors", () => {
  assert.deepEqual(checkContract(validDoc()), []);
});

test("rejects OpenAPI versions other than 3.0.3", () => {
  const doc = validDoc();
  doc.openapi = "3.1.0";
  assert.match(checkContract(doc).join("\n"), /must be "3\.0\.3"/);
});

test("rejects camelCase schema properties, including nested ones", () => {
  const doc = validDoc();
  doc.components.schemas.Thing.properties.live_video.properties.pairSha = { type: "string" };
  assert.match(checkContract(doc).join("\n"), /"pairSha" is not snake_case/);
});

test("rejects camelCase inline request body properties", () => {
  const doc = validDoc();
  doc.paths[P].post = {
    operationId: "postThing",
    tags: ["assets"],
    requestBody: { content: { "application/json": { schema: { type: "object", properties: { assetIds: { type: "array" } } } } } },
    responses: { "400": { $ref: "#/components/responses/NotFound" } },
  };
  assert.match(checkContract(doc).join("\n"), /"assetIds" is not snake_case/);
});

test("rejects camelCase query parameters but allows HTTP header names", () => {
  const doc = validDoc();
  doc.paths[P].get.parameters.push({ name: "pageToken", in: "query", schema: { type: "string" } });
  const errors = checkContract(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /parameter "pageToken"/);
});

test("requires a problem+json error response except on HEAD and OPTIONS", () => {
  const doc = validDoc();
  doc.paths[P].get.responses = { "200": { description: "ok" } };
  assert.match(checkContract(doc).join("\n"), /GET \/api\/v1\/things\/\{thing_id\}: no 4xx\/5xx application\/problem\+json response/);
});

test("rejects paths outside /api/v1 except health probes", () => {
  const doc = validDoc();
  doc.paths["/healthz"] = { get: { operationId: "getHealthz", tags: ["server"], responses: { "503": { $ref: "#/components/responses/NotFound" } } } };
  doc.paths["/v2/things"] = { get: { operationId: "listThings", tags: ["assets"], responses: { "500": { $ref: "#/components/responses/NotFound" } } } };
  const errors = checkContract(doc);
  assert.equal(errors.length, 1);
  assert.match(errors[0], /\/v2\/things: must start with \/api\/v1\//);
});

test("rejects unknown tags and missing operationIds", () => {
  const doc = validDoc();
  doc.paths[P].get.tags = ["misc"];
  delete doc.paths[P].get.operationId;
  const text = checkContract(doc).join("\n");
  assert.match(text, /unknown tag "misc"/);
  assert.match(text, /missing operationId/);
});

test("rejects sibling keys next to $ref", () => {
  const doc = validDoc();
  doc.components.schemas.Thing.properties.owner = { $ref: "#/components/schemas/Problem", description: "x" };
  assert.match(checkContract(doc).join("\n"), /sibling keys next to \$ref/);
});

test("rejects closed enums reachable from responses", () => {
  const doc = validDoc();
  doc.components.schemas.Thing.properties.state = { type: "string", enum: ["active", "trashed"] };
  assert.match(checkContract(doc).join("\n"), /closed enum reachable from a response/);
});

test("allows enums in request-only schemas", () => {
  const doc = validDoc();
  doc.paths[P].post = {
    operationId: "postThing",
    tags: ["assets"],
    requestBody: { content: { "application/json": { schema: { type: "object", properties: { mode: { type: "string", enum: ["tokens", "cookie"] } } } } } },
    responses: { "400": { $ref: "#/components/responses/NotFound" } },
  };
  assert.deepEqual(checkContract(doc), []);
});
