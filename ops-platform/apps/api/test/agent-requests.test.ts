import { describe, expect, it } from "vitest";
import { buildServer } from "../src/server.js";
import { ownerAuthorization } from "./helpers.js";

describe("agent requests", () => {
  it("lets admins queue feedback Agent requests for external agents without side effects", async () => {
    const server = buildServer();
    const headers = await ownerAuthorization(server);

    const createResponse = await server.inject({
      method: "POST",
      url: "/api/v1/products/stacio/feedback/fb_001/agent-requests",
      headers,
      payload: {
        requestType: "summary",
        agentHint: "codex",
        prompt: "Summarize crash impact and suggested priority."
      }
    });

    expect(createResponse.statusCode).toBe(201);
    expect(createResponse.json()).toEqual(
      expect.objectContaining({
        ok: true,
        data: expect.objectContaining({
          id: expect.stringMatching(/^agent_req_/),
          productId: "stacio",
          targetType: "feedback",
          targetId: "fb_001",
          requestType: "summary",
          agentHint: "codex",
          prompt: "Summarize crash impact and suggested priority.",
          status: "queued"
        }),
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false,
          actionExecuted: false
        }
      })
    );

    const requestId = createResponse.json().data.id;
    const adminListResponse = await server.inject({
      method: "GET",
      url: "/api/v1/products/stacio/feedback/fb_001/agent-requests",
      headers
    });
    expect(adminListResponse.statusCode).toBe(200);
    expect(adminListResponse.json().data).toEqual([
      expect.objectContaining({
        id: requestId,
        requestType: "summary",
        status: "queued"
      })
    ]);

    const agentQueueResponse = await server.inject({
      method: "GET",
      url: "/api/agent/v1/products/stacio/feedback/agent-requests?status=queued",
      headers: {
        authorization: "Bearer development-agent-key"
      }
    });
    expect(agentQueueResponse.statusCode).toBe(200);
    expect(agentQueueResponse.json()).toEqual(
      expect.objectContaining({
        ok: true,
        data: [
          expect.objectContaining({
            id: requestId,
            targetType: "feedback",
            targetId: "fb_001",
            requestType: "summary",
            prompt: "Summarize crash impact and suggested priority."
          })
        ],
        policy: {
          customerVisibleEmailSent: false,
          publicGitHubReplySent: false,
          otaPublished: false,
          licenseChanged: false,
          feedbackDeleted: false
        }
      })
    );

    const auditResponse = await server.inject({
      method: "GET",
      url: "/api/v1/audit-logs?productId=stacio&action=agent_request.created",
      headers
    });
    expect(auditResponse.json().data).toEqual([
      expect.objectContaining({
        action: "agent_request.created",
        targetType: "agent_request",
        targetId: requestId
      })
    ]);
  });
});
