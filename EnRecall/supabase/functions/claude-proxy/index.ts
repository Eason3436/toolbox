// EnRecall iOS：App 內「助理」呼叫 Claude 的代理（規格見 EnRecall/supabase/DEPLOY-9.md）
//
// - Claude API key 只放在 Edge Function secrets（ANTHROPIC_API_KEY，選填 ANTHROPIC_API_KEY_BACKUP），不進 App、不進 repo
// - 驗證呼叫者：跟 enrecall-packs 一樣要帶下載密碼（x-store-password，比對 STORE_PASSWORD），
//   另外要帶 App 的配對碼（x-device-code），而且這台裝置要已經註冊在 ios_devices
// - App 組好 Messages API 的 body；這裡只檢查模型、beta 白名單，用官方 SDK 串流呼叫、等完整回覆再整份回傳
// - 主要的 key 帳單或認證有問題時才改用備用的 key 重送一次（不輪流用）
//
// 部署：verify_jwt = false（App 帶的是 publishable／anon key，不靠它驗證）

import Anthropic from "npm:@anthropic-ai/sdk@1.12.0";
import { createClient } from "jsr:@supabase/supabase-js@2";

const MODELS = new Set(["claude-opus-5-5"]);
const BETAS = new Set(["server-side-fallback-2026-07-01", "thinking-binding-controls-2026-08-01"]);
const MAX_BODY = 24 * 1024 * 1024;
const MAX_TOKENS = 32000;
const CODE_RE = /^[A-Za-z0-9_-]{16,128}$/;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-store-password, x-device-code",
};

function json(status: number, body: unknown, extra: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", ...cors, ...extra },
  });
}

/** 固定時間比較：先比長度，再逐位元 XOR 累加 */
function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  const n = Math.max(x.length, y.length);
  for (let i = 0; i < n; i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function unauthorized(): Promise<Response> {
  // 拖慢暴力猜密碼
  await new Promise((r) => setTimeout(r, 500));
  return json(401, { error: { code: "unauthorized", message: "unauthorized" } });
}

/** 這把 key 不能用（帳單、額度、認證）：值得換備用的 key */
function isKeyProblem(error: unknown): boolean {
  return error instanceof Anthropic.APIError && (error.status === 401 || error.status === 402 || error.status === 403);
}

async function callClaude(apiKey: string, params: Record<string, unknown>, betas: string[]) {
  const client = new Anthropic({ apiKey, maxRetries: 2 });
  // 串流等完整回覆：回覆很長時不會碰到 HTTP 逾時
  return await client.beta.messages
    // deno-lint-ignore no-explicit-any
    .stream({ ...params, betas } as any)
    .finalMessage();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json(405, { error: { code: "method_not_allowed" } });

  // 1. 下載密碼
  const expected = Deno.env.get("STORE_PASSWORD") ?? "";
  const given = req.headers.get("x-store-password") ?? "";
  if (!expected || !given || !safeEqual(given, expected)) return unauthorized();

  // 2. 配對碼（App 第一次打開就註冊過）
  const code = req.headers.get("x-device-code") ?? "";
  if (!CODE_RE.test(code)) return unauthorized();
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const codeHash = await sha256Hex(code);
  const { data: device, error: deviceError } = await supabase
    .from("ios_devices").select("code_hash").eq("code_hash", codeHash).maybeSingle();
  if (deviceError) {
    console.error("claude-proxy: device lookup failed", deviceError.code);
    return json(502, { error: { code: "upstream", message: "device lookup failed" } });
  }
  if (!device) return unauthorized();

  // 3. 請求內容：{ "request": { Messages API 的 body }, "betas": [...] }
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > MAX_BODY) return json(413, { error: { code: "too_large", message: "請求太大" } });
  let payload: { request?: Record<string, unknown>; betas?: unknown };
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY) return json(413, { error: { code: "too_large", message: "請求太大" } });
    payload = JSON.parse(raw);
  } catch {
    return json(400, { error: { code: "bad_json", message: "JSON 格式不對" } });
  }
  const params = payload.request;
  if (!params || typeof params !== "object" || Array.isArray(params)) {
    return json(400, { error: { code: "bad_request", message: "少了 request" } });
  }
  const model = typeof params.model === "string" ? params.model : "";
  if (!MODELS.has(model)) return json(400, { error: { code: "model_not_allowed", message: `不支援的模型：${model}` } });
  const maxTokens = typeof params.max_tokens === "number" ? params.max_tokens : 0;
  if (maxTokens < 1 || maxTokens > MAX_TOKENS) {
    return json(400, { error: { code: "bad_request", message: `max_tokens 要 1–${MAX_TOKENS}` } });
  }
  delete params.stream;
  const betas = Array.isArray(payload.betas) ? payload.betas.filter((b): b is string => typeof b === "string") : [];
  const unknown = betas.filter((b) => !BETAS.has(b));
  if (unknown.length > 0) return json(400, { error: { code: "beta_not_allowed", message: `不支援的 beta：${unknown.join(", ")}` } });

  const primary = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
  const backup = Deno.env.get("ANTHROPIC_API_KEY_BACKUP") ?? "";
  if (!primary && !backup) return json(500, { error: { code: "not_configured", message: "還沒設定 Claude API key" } });

  // 4. 先用主要的 key；帳單或認證有問題才換備用的 key 重送一次
  let used = primary ? "primary" : "backup";
  try {
    let message;
    try {
      message = await callClaude(primary || backup, params, betas);
    } catch (error) {
      if (!(primary && backup && isKeyProblem(error))) throw error;
      console.warn("claude-proxy: primary key unavailable, switching to backup", (error as InstanceType<typeof Anthropic.APIError>).status);
      used = "backup";
      message = await callClaude(backup, params, betas);
    }
    return json(200, message, { "x-claude-key": used });
  } catch (error) {
    if (error instanceof Anthropic.APIError) {
      const status = error.status ?? 502;
      // 只印狀態碼和錯誤類型，不印內容
      console.error("claude-proxy: api error", used, status);
      if (isKeyProblem(error)) {
        // App 顯示「AI 額度已用完」、不再重試
        return json(402, { error: { code: "quota_exhausted", message: "AI 額度已用完" } }, { "x-claude-key": used });
      }
      if (status === 429) return json(429, { error: { code: "rate_limited", message: "太多請求，稍後再試" } });
      if (status >= 500) return json(503, { error: { code: "overloaded", message: "AI 伺服器忙，稍後再試" } });
      // 400 之類：把 API 的訊息交給 App（參數不對時方便看）
      const apiMessage = (error.error as { error?: { message?: string } } | undefined)?.error?.message ?? error.message;
      return json(status, { error: { code: "api_error", message: apiMessage } });
    }
    console.error("claude-proxy: unexpected error", (error as Error)?.name);
    return json(502, { error: { code: "upstream", message: "連不上 Claude，稍後再試" } });
  }
});
