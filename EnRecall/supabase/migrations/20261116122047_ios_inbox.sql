-- EnRecall iOS：配對碼與收件匣
--
-- 部署在 EnRecall iOS 專用的 Supabase 專案（不是使用者自己的 EnRecall 專案）。
-- 不碰任何既有資料表。單字商店在 EnRecall 專案的公開 Storage（packs bucket），App 和 MCP 直接用 HTTPS 讀，不需要 view。
--
-- anon 能做的事：只能呼叫 ios_register_device / ios_claim_inbox / ios_unregister_device。
-- ios_* 表開了 RLS 而且沒有 policy，另外也把表權限收回，anon/authenticated 都不能直接讀寫。
-- Edge Function enrecall-mcp 用 service_role 寫入 ios_inbox。

create extension if not exists pg_cron with schema pg_catalog;

-- ---------------------------------------------------------------------------
-- 裝置（配對碼只存 sha256，不存明碼）
-- ---------------------------------------------------------------------------
create table if not exists public.ios_devices (
  code_hash   text primary key check (code_hash ~ '^[0-9a-f]{64}$'),
  created_at  timestamptz not null default now(),
  last_seen   timestamptz not null default now()
);
alter table public.ios_devices enable row level security;
revoke all on public.ios_devices from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 收件匣（只放單字，不放進度；App 取回即刪除，7 天自動清除）
-- ---------------------------------------------------------------------------
create table if not exists public.ios_inbox (
  id               uuid primary key default gen_random_uuid(),
  code_hash        text not null references public.ios_devices(code_hash) on delete cascade,
  deck_name        text not null check (char_length(btrim(deck_name)) between 1 and 60),
  word             text not null check (char_length(btrim(word)) between 1 and 120),
  pos              text,
  zh               text not null check (char_length(btrim(zh)) > 0),
  example          text,
  example_zh       text,
  source           text not null check (source in ('library', 'claude')),
  library_word_id  text,                 -- source = library 時填，例如 w:ability、p:such as
  created_at       timestamptz not null default now(),
  check (source = 'claude' or library_word_id is not null)
);
create index if not exists ios_inbox_code_hash_created_at_idx
  on public.ios_inbox (code_hash, created_at);
alter table public.ios_inbox enable row level security;
revoke all on public.ios_inbox from anon, authenticated;

-- ---------------------------------------------------------------------------
-- RPC
-- ---------------------------------------------------------------------------
create or replace function public.ios_code_hash(p_code text)
returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p_code is null or p_code !~ '^[A-Za-z0-9_-]{16,128}$' then
    raise exception 'invalid code' using errcode = '22023';
  end if;
  return encode(extensions.digest(p_code, 'sha256'), 'hex');
end $$;

-- App 第一次開啟（或每次進前景）時註冊配對碼
create or replace function public.ios_register_device(p_code text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.ios_devices (code_hash)
  values (public.ios_code_hash(p_code))
  on conflict (code_hash) do update set last_seen = now();
end $$;

-- App 取回收件匣（取回即刪除）
create or replace function public.ios_claim_inbox(p_code text)
returns setof public.ios_inbox
language plpgsql security definer set search_path = '' as $$
declare
  v_hash text := public.ios_code_hash(p_code);
begin
  update public.ios_devices set last_seen = now() where code_hash = v_hash;
  return query
    delete from public.ios_inbox where code_hash = v_hash
    returning *;
end $$;

-- 重新產生配對碼時刪除舊的（收件匣跟著 cascade 刪除）
create or replace function public.ios_unregister_device(p_code text)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.ios_devices where code_hash = public.ios_code_hash(p_code);
end $$;

-- Supabase 預設會把 public 新函式的執行權給 anon/authenticated，這裡全部收回再只給 anon 三個
revoke all on function public.ios_code_hash(text),
                       public.ios_register_device(text),
                       public.ios_claim_inbox(text),
                       public.ios_unregister_device(text)
  from public, anon, authenticated;
grant execute on function public.ios_register_device(text),
                          public.ios_claim_inbox(text),
                          public.ios_unregister_device(text)
  to anon;
grant execute on function public.ios_code_hash(text) to service_role;

-- ---------------------------------------------------------------------------
-- 自動清除：收件匣 7 天、裝置 180 天沒出現
-- ---------------------------------------------------------------------------
select cron.schedule('ios-inbox-cleanup', '0 3 * * *', $cron$
  delete from public.ios_inbox where created_at < now() - interval '7 days';
  delete from public.ios_devices where last_seen < now() - interval '180 days';
$cron$);
