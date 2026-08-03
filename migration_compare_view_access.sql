-- ============================================================================
-- Migration: let any authenticated user READ Compare data (session list +
-- mapping_links), while keeping writes admin-only.
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New
-- query). Requires migration_compare.sql to already be applied.
--
-- The Compare companies screen now shows the list of existing comparisons
-- to everyone (so a non-admin can open one to view, read-only) instead of
-- being entirely admin-only — mirrors the groups table's
-- select-for-everyone / write-for-admins split from migration_groups.sql.
-- ============================================================================

drop policy if exists "mapping_sessions_admin_all" on mapping_sessions;
drop policy if exists "mapping_sessions_select_all" on mapping_sessions;
create policy "mapping_sessions_select_all"
  on mapping_sessions for select to authenticated using (true);
drop policy if exists "mapping_sessions_admin_write" on mapping_sessions;
create policy "mapping_sessions_admin_write"
  on mapping_sessions for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

drop policy if exists "mapping_links_admin_all" on mapping_links;
drop policy if exists "mapping_links_select_all" on mapping_links;
create policy "mapping_links_select_all"
  on mapping_links for select to authenticated using (true);
drop policy if exists "mapping_links_admin_write" on mapping_links;
create policy "mapping_links_admin_write"
  on mapping_links for all to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- ============================================================================
-- Note: the app now also hides Compare's mutation controls (link/unlink,
-- mark-as-gap, status change, "Start comparison") from non-admins in the
-- UI, since RLS would reject those writes anyway — this keeps a
-- non-admin's view genuinely read-only instead of showing controls that
-- silently fail.
-- ============================================================================
