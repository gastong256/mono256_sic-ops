const DEFAULT_EVENT_TYPE = "keep-alive-tick";
const DEFAULT_API_URL = "https://api.github.com";

async function dispatchKeepAlive(env, meta = {}) {
  const owner = env.GITHUB_OWNER;
  const repo = env.GITHUB_REPO;
  const token = env.GITHUB_DISPATCH_TOKEN;
  const apiUrl = (env.GITHUB_API_URL || DEFAULT_API_URL).replace(/\/+$/, "");
  const eventType = env.GITHUB_EVENT_TYPE || DEFAULT_EVENT_TYPE;

  if (!owner || !repo || !token) {
    throw new Error(
      "Missing required worker configuration: GITHUB_OWNER, GITHUB_REPO, or GITHUB_DISPATCH_TOKEN."
    );
  }

  const response = await fetch(`${apiUrl}/repos/${owner}/${repo}/dispatches`, {
    method: "POST",
    headers: {
      Accept: "application/vnd.github+json",
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
      "User-Agent": "ops-keepalive-dispatch-worker",
      "X-GitHub-Api-Version": "2022-11-28",
    },
    body: JSON.stringify({
      event_type: eventType,
      client_payload: {
        source: "cloudflare-workers-cron",
        scheduled_at: meta.scheduledAt || new Date().toISOString(),
        cron: meta.cron || null,
      },
    }),
  });

  if (!response.ok) {
    const body = (await response.text()).slice(0, 1000) || "<empty>";
    throw new Error(
      `GitHub repository_dispatch failed with HTTP ${response.status}: ${body}`
    );
  }

  return new Response("repository_dispatch accepted", { status: 200 });
}

export default {
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(
      dispatchKeepAlive(env, {
        scheduledAt: new Date().toISOString(),
        cron: controller.cron,
      })
    );
  },

  async fetch() {
    return new Response("Not found", { status: 404 });
  },
};
