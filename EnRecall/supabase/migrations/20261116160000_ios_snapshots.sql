-- EnRecall iOS：學習紀錄快照（給 Claude 連接器分析成效、做講義）
--
-- 部署在 EnRecall iOS 專用的 Supabase 專案（<IOS_REF>），不是使用者自己的 EnRecall 專案。
-- 一台裝置只留最新一份（App 每次上傳整份覆蓋）。配對碼刪除時跟著 cascade 刪除。
-- anon 只能呼叫 ios_push_snapshot；表本身開 RLS、沒有 policy、權限收回。
-- Edge Function enrecall-mcp 用 service_role 讀。

create table if not exists public.ios_snapshots (
  code_hash   text primary key references public.ios_devices(code_hash) on delete cascade,
  payload     jsonb not null,
  updated_at  timestamptz not null default now()
);
alter table public.ios_snapshots enable row level security;
revoke all on public.ios_snapshots from anon, authenticated;

-- App 上傳學習紀錄（整份覆蓋）。裝置還沒註冊就順便註冊
create or replace function public.ios_push_snapshot(p_code text, p_payload jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_hash text := public.ios_code_hash(p_code);
begin
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' or (p_payload->>'v') is null then
    raise exception 'invalid payload' using errcode = '22023';
  end if;
  if octet_length(p_payload::text) > 8 * 1024 * 1024 then
    raise exception 'payload too large' using errcode = '22023';
  end if;

  insert into public.ios_devices (code_hash)
  values (v_hash)
  on conflict (code_hash) do update set last_seen = now();

  insert into public.ios_snapshots (code_hash, payload, updated_at)
  values (v_hash, p_payload, now())
  on conflict (code_hash) do update set payload = excluded.payload, updated_at = now();
end $$;

revoke all on function public.ios_push_snapshot(text, jsonb) from public, anon, authenticated;
grant execute on function public.ios_push_snapshot(text, jsonb) to anon;
