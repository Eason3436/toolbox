-- Recap ↔ Claude 同步用的資料表（Supabase）。
-- App 用 publishable key + 自己產生的 x-recap-token 讀寫；Claude 用官方 Supabase 連接器（execute_sql）讀寫。

create extension if not exists pgcrypto with schema extensions;

-- 綁定的那支手機（只存 Token 的雜湊，最多一列）
create table if not exists public.recap_owner (
  id int primary key default 1 check (id = 1),
  token_hash text not null,
  created_at timestamptz not null default now()
);
alter table public.recap_owner enable row level security; -- 沒有 policy：API 讀不到

create or replace function public.recap_authorized() returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (
    select 1 from public.recap_owner
    where token_hash = encode(digest(coalesce(current_setting('request.headers', true)::json->>'x-recap-token', ''), 'sha256'), 'hex')
  );
$$;

-- 第一次連線時認領；已經有主人就只接受同一個 Token
create or replace function public.recap_claim(token text) returns boolean
language plpgsql security definer set search_path = public, extensions as $$
declare h text := encode(digest(token, 'sha256'), 'hex');
begin
  if length(coalesce(token, '')) < 32 then return false; end if;
  if exists (select 1 from public.recap_owner) then
    return exists (select 1 from public.recap_owner where token_hash = h);
  end if;
  insert into public.recap_owner (token_hash) values (h);
  return true;
end;
$$;
revoke all on function public.recap_claim(text) from public;
grant execute on function public.recap_claim(text) to anon, authenticated;
revoke all on function public.recap_authorized() from public;
grant execute on function public.recap_authorized() to anon, authenticated;

-- App 上傳的內容：全天錄音的每一段（kind = segment）與每一堂課（kind = lecture）
create table if not exists public.recap_items (
  id text primary key,
  kind text not null check (kind in ('segment', 'lecture')),
  day date not null,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  title text,
  subject text,
  transcript text not null default '',
  ai_points jsonb not null default '[]',
  exam_points jsonb not null default '[]',
  todos jsonb not null default '[]',
  updated_at timestamptz not null default now()
);
create index if not exists recap_items_day on public.recap_items (day, starts_at);
alter table public.recap_items enable row level security;
create policy recap_items_owner on public.recap_items for all to anon, authenticated
  using (public.recap_authorized()) with check (public.recap_authorized());

-- Claude 寫回的筆記：item_id 對應 recap_items.id；整天的整理則 item_id 為 null、填 day
create table if not exists public.claude_notes (
  target text primary key,            -- 'item:<id>' 或 'day:<YYYY-MM-DD>'
  item_id text references public.recap_items (id) on delete cascade,
  day date,
  markdown text not null,
  updated_at timestamptz not null default now()
);
create index if not exists claude_notes_updated on public.claude_notes (updated_at);
alter table public.claude_notes enable row level security;
create policy claude_notes_owner on public.claude_notes for all to anon, authenticated
  using (public.recap_authorized()) with check (public.recap_authorized());

create or replace function public.recap_touch() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end; $$;
drop trigger if exists recap_items_touch on public.recap_items;
create trigger recap_items_touch before update on public.recap_items for each row execute function public.recap_touch();
drop trigger if exists claude_notes_touch on public.claude_notes;
create trigger claude_notes_touch before update on public.claude_notes for each row execute function public.recap_touch();

comment on table public.recap_items is 'Recap App 上傳的錄音逐字稿。kind=segment 是全天錄音的一段（約 5 分鐘），kind=lecture 是一整堂課。day 是台灣日期。ai_points/exam_points/todos 是 App 裡 AI 整理的重點、會考、待辦（JSON 陣列）。';
comment on table public.claude_notes is 'Claude 寫回給 Recap App 的筆記（Markdown）。單段或單堂課：target=''item:<recap_items.id>''、item_id 填該 id；整天的整理：target=''day:YYYY-MM-DD''、day 填日期、item_id 為 null。用 insert ... on conflict (target) do update 覆寫。App 會在下次同步時下載。';
comment on table public.recap_owner is '綁定的手機 Token 雜湊。要換手機重新綁定時清空這張表。';
