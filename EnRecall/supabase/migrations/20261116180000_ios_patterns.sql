-- EnRecall iOS：句型庫與句型卡收件匣
--
-- 部署在 EnRecall iOS 專用的 Supabase 專案（zjlitlhepabrvvtpcjgz），不是使用者自己的 EnRecall 專案。
-- 句型庫是共用的（不分裝置）：Claude 整理過的句型存在這裡，下次遇到同一個句型直接拿，不用重寫。
-- 只有 Edge Function enrecall-mcp（service_role）讀寫；anon 完全碰不到。

-- ---------------------------------------------------------------------------
-- 句型庫
-- ---------------------------------------------------------------------------
create table if not exists public.ios_patterns (
  id          text primary key check (id like 'pt:%'),
  -- 固定字（anchors）正規化後用 | 連起來，例如 it is not until|that
  key         text not null unique check (char_length(key) between 1 and 200),
  pattern     text not null check (char_length(btrim(pattern)) between 1 and 120),
  zh          text not null check (char_length(btrim(zh)) between 1 and 120),
  detail      jsonb not null check (jsonb_typeof(detail) = 'object' and octet_length(detail::text) <= 32768),
  uses        integer not null default 1,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.ios_patterns enable row level security;
revoke all on public.ios_patterns from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 收件匣加上句型卡
-- ---------------------------------------------------------------------------
alter table public.ios_inbox add column if not exists kind text not null default 'word';
alter table public.ios_inbox add column if not exists detail jsonb;
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'ios_inbox_kind_check') then
    alter table public.ios_inbox add constraint ios_inbox_kind_check
      check (kind in ('word', 'pattern') and (kind = 'word' or (detail is not null and library_word_id like 'pt:%')));
  end if;
end $$;

-- 欄位變了，重建領取函式（回傳型別跟著表走，App 會收到 kind、detail）
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

revoke all on function public.ios_claim_inbox(text) from public, anon, authenticated;
grant execute on function public.ios_claim_inbox(text) to anon;
