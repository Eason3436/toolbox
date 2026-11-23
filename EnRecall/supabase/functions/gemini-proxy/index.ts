// EnRecall iOS：App 內「助理」呼叫 Gemini 的代理（規格見 EnRecall/supabase/DEPLOY-8.md）
//
// - Gemini API key 只放在 Edge Function secrets（GEMINI_KEY_PRIMARY、GEMINI_KEY_BACKUP），不進 App、不進 repo
// - 驗證呼叫者：跟 enrecall-packs 一樣要帶下載密碼（x-store-password，比對 STORE_PASSWORD），
//   另外要帶 App 的配對碼（x-device-code），而且這台裝置要已經註冊在 ios_devices
// - 預設用 PRIMARY；PRIMARY 回額度或計費錯誤時才改用 BACKUP 重送一次（不輪流用）
// - 只轉送白名單裡的模型；回傳 Gemini 的原始 JSON（裡面有 usageMetadata）
//
// 部署：verify_jwt = false（App 帶的是 publishable／anon key，不靠它驗證）

import { createClient } from "jsr:@supabase/supabase-js@2";

const MODELS = new Set(["gemini-4-hydrogen", "gemini-4-neon"]);
const GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models";
const MAX_BODY = 20 * 1024 * 1024;
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

/** PRIMARY 不能用、值得改用 BACKUP 的錯誤：額度不足、計費、key 被停用 */
function isQuotaOrBilling(status: number, body: string): boolean {
  if (status === 429) return true;
  if (status === 403 || status === 400) {
    return /billing|quota|RESOURCE_EXHAUSTED|API_KEY_INVALID|API key not valid|PERMISSION_DENIED|consumer_suspended/i.test(body);
  }
  return false;
}

async function callGemini(model: string, key: string, body: string): Promise<{ status: number; text: string }> {
  const res = await fetch(`${GEMINI_BASE}/${model}:generateContent`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-goog-api-key": key },
    body,
  });
  return { status: res.status, text: await res.text() };
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
    console.error("gemini-proxy: device lookup failed", deviceError.code);
    return json(502, { error: { code: "upstream", message: "device lookup failed" } });
  }
  if (!device) return unauthorized();

  // 3. 請求內容：{ "model": "...", "request": { generateContent 的 body } }
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > MAX_BODY) return json(413, { error: { code: "too_large", message: "請求太大" } });
  let payload: { model?: unknown; request?: unknown };
  try {
    const raw = await req.text();
    if (raw.length > MAX_BODY) return json(413, { error: { code: "too_large", message: "請求太大" } });
    payload = JSON.parse(raw);
  } catch {
    return json(400, { error: { code: "bad_json", message: "JSON 格式不對" } });
  }
  const model = typeof payload.model === "string" ? payload.model : "";
  if (!MODELS.has(model)) return json(400, { error: { code: "model_not_allowed", message: `不支援的模型：${model}` } });
  if (!payload.request || typeof payload.request !== "object") {
    return json(400, { error: { code: "bad_request", message: "少了 request" } });
  }
  const body = JSON.stringify(payload.request);

  const primary = Deno.env.get("GEMINI_KEY_PRIMARY") ?? "";
  const backup = Deno.env.get("GEMINI_KEY_BACKUP") ?? "";
  if (!primary && !backup) return json(500, { error: { code: "not_configured", message: "還沒設定 Gemini key" } });

  // 4. 先 PRIMARY；額度或計費錯誤才換 BACKUP 重送一次
  let used = primary ? "primary" : "backup";
  let result = await callGemini(model, primary || backup, body);
  if (primary && backup && isQuotaOrBilling(result.status, result.text)) {
    console.warn("gemini-proxy: primary unavailable, switching to backup", result.status);
    used = "backup";
    result = await callGemini(model, backup, body);
  }

  if (result.status >= 200 && result.status < 300) {
    return new Response(result.text, {
      status: 200,
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "x-gemini-key": used, ...cors },
    });
  }

  // 兩把都額度不足：給 App 一個固定的錯誤碼，App 會顯示「本月 AI 額度已用完」、不再重試
  if (isQuotaOrBilling(result.status, result.text)) {
    console.error("gemini-proxy: quota exhausted on", used, result.status);
    return json(429, { error: { code: "quota_exhausted", message: "本月 AI 額度已用完" } }, { "x-gemini-key": used });
  }

  // 其他錯誤（參數不對、模型錯誤）：原樣回傳，App 顯示訊息並可以重試
  console.error("gemini-proxy: gemini error", result.status);
  return new Response(result.text, {
    status: result.status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "x-gemini-key": used, ...cors },
  });
});
