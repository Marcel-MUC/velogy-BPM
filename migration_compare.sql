-- ============================================================================
-- Migration: Compare feature — map two companies' process trees against
-- each other, level by level (L2-L5; L1 is computed on the fly and never
-- stored — see index.html).
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- ============================================================================

-- 1) One session per (unordered) company pair -----------------------------------
-- The app always normalizes company_a_id to be the lexicographically smaller
-- of the two ids before insert/query, so the order check below both
-- normalizes the pair AND lets a plain UNIQUE constraint enforce "only one
-- session per pair regardless of order" without needing a generated column.
create table if not exists mapping_sessions (
  id uuid primary key default gen_random_uuid(),
  company_a_id uuid not null references companies(id) on delete cascade,
  company_b_id uuid not null references companies(id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint mapping_sessions_order_check check (company_a_id < company_b_id),
  constraint mapping_sessions_pair_uniq unique (company_a_id, company_b_id)
);

alter table mapping_sessions enable row level security;
drop policy if exists "mapping_sessions_admin_all" on mapping_sessions;
create policy "mapping_sessions_admin_all"
  on mapping_sessions for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- 2) Links between two items at a given level -----------------------------------
-- item_a_id/item_b_id are plain uuids, not foreign keys: which table they
-- point into (subprocesses/steps/tasks/work_instructions) depends on
-- `level`, and a single column can't reference different tables
-- conditionally. The app resolves them based on `level` instead.
-- Exactly one of item_a_id/item_b_id may be null — a null side means "no
-- equivalent on that side" (always paired with status='gap').
create table if not exists mapping_links (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references mapping_sessions(id) on delete cascade,
  level text not null check (level in ('l2','l3','l4','l5')),
  item_a_id uuid,
  item_b_id uuid,
  status text not null check (status in ('match','partial','gap')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint mapping_links_item_check check (not (item_a_id is null and item_b_id is null))
);
create index if not exists mapping_links_session_level_idx on mapping_links(session_id, level);

alter table mapping_links enable row level security;
drop policy if exists "mapping_links_admin_all" on mapping_links;
create policy "mapping_links_admin_all"
  on mapping_links for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- ============================================================================
-- Note: this feature is admin-only end to end (both tables are admin-only
-- for read AND write) — comparing across two companies isn't scoped by the
-- existing per-company company_access/process_access model, so it
-- deliberately doesn't try to layer that model on top here.
--
-- There is no FK-driven cascade from mapping_links down to "deeper" links
-- (e.g. deleting an L2 link doesn't automatically delete the L3/L4/L5 links
-- nested under it) because item_a_id/item_b_id aren't real foreign keys to
-- begin with. The app performs that cleanup explicitly in
-- cascadeDeleteMappingLinks() before/after deleting a link.
-- ============================================================================
