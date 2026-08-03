-- ============================================================================
-- Migration: replace mapping_links' match/partial/gap linking with a
-- drag-and-drop "build a target process" model.
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Requires migration_compare.sql / migration_compare_view_access.sql to
-- already be applied (mapping_sessions is unchanged and stays).
--
-- Classification (Merged/Adopted from A/Adopted from B/New) is no longer a
-- stored decision — it's derived at display time from which of a target
-- item's two source slots are filled. Likewise "Open" vs "Eliminated" for a
-- not-yet-built source item is derived from whether a build_completions row
-- exists for that level+parent scope, not stored per item.
-- ============================================================================

-- 1) Drop the old linking table entirely — only ever had test data.
drop table if exists mapping_links;

-- 2) target_items: the tree the admin builds by dragging source items in ----
-- level='l2' rows with no parent_target_item_id are the top of a build tree,
-- rooted under one matched L1 (mega-cycle) pair — since L1 itself is never
-- stored (purely computed by name match), l1_process_a_id/l1_process_b_id
-- capture which L1 pair that root belongs to (a session can have several
-- matched L1 pairs, each with its own independent L2 build). From L3 down,
-- parent_target_item_id alone fully identifies the scope, so those two
-- columns are left null.
create table if not exists target_items (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references mapping_sessions(id) on delete cascade,
  level text not null check (level in ('l2','l3','l4','l5')),
  parent_target_item_id uuid references target_items(id) on delete cascade,
  l1_process_a_id uuid references processes(id) on delete cascade,
  l1_process_b_id uuid references processes(id) on delete cascade,
  name text not null default '',
  position int not null default 0,
  source_item_a_id uuid,
  source_item_b_id uuid,
  created_at timestamptz not null default now(),
  constraint target_items_root_check check (
    (parent_target_item_id is not null and l1_process_a_id is null and l1_process_b_id is null)
    or (parent_target_item_id is null and l1_process_a_id is not null and l1_process_b_id is not null)
  )
);
create index if not exists target_items_scope_idx
  on target_items(session_id, level, parent_target_item_id, l1_process_a_id, l1_process_b_id);

alter table target_items enable row level security;
drop policy if exists "target_items_admin_all" on target_items;
create policy "target_items_admin_all"
  on target_items for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- 3) build_completions: "this level, scoped to this parent, is finished" ----
-- Same root-vs-nested scoping columns as target_items, for the same reason.
-- No uniqueness constraint here: since parent_target_item_id is null for
-- every L2 (root) row, a plain UNIQUE constraint including it wouldn't
-- actually block duplicate root completions (Postgres never treats two
-- NULLs as equal for uniqueness purposes) — the app already checks for an
-- existing row before inserting (same find-or-create pattern used for
-- mapping_sessions), so this is enforced in application code instead of
-- the database for the root case.
create table if not exists build_completions (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references mapping_sessions(id) on delete cascade,
  level text not null check (level in ('l2','l3','l4','l5')),
  parent_target_item_id uuid references target_items(id) on delete cascade,
  l1_process_a_id uuid references processes(id) on delete cascade,
  l1_process_b_id uuid references processes(id) on delete cascade,
  completed_at timestamptz not null default now(),
  completed_by uuid references profiles(id),
  constraint build_completions_root_check check (
    (parent_target_item_id is not null and l1_process_a_id is null and l1_process_b_id is null)
    or (parent_target_item_id is null and l1_process_a_id is not null and l1_process_b_id is not null)
  )
);
create index if not exists build_completions_scope_idx
  on build_completions(session_id, level, parent_target_item_id, l1_process_a_id, l1_process_b_id);

alter table build_completions enable row level security;
drop policy if exists "build_completions_admin_all" on build_completions;
create policy "build_completions_admin_all"
  on build_completions for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- ============================================================================
-- Note: source_item_a_id/source_item_b_id (on target_items) are plain
-- uuids, not foreign keys, for the same reason as the old mapping_links —
-- which table they point into (subprocesses/steps/tasks/work_instructions)
-- depends on `level`. Removing a target_item cascades to any deeper
-- target_items AND build_completions scoped under it automatically via the
-- real parent_target_item_id foreign keys above (no manual JS cleanup
-- needed here, unlike the old mapping_links model).
-- ============================================================================
