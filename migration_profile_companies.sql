-- ============================================================================
-- Migration: profile <-> company assignments (many-to-many)
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- ============================================================================

-- One row per (user, company) assignment. Replaces the idea of a single
-- department-style foreign key with a proper many-to-many join table, since a
-- user can now be assigned to zero, one, or several companies.
create table if not exists profile_companies (
  id uuid primary key default gen_random_uuid(),
  profile_id uuid not null references profiles(id) on delete cascade,
  company_id uuid not null references companies(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (profile_id, company_id)
);

alter table profile_companies enable row level security;

-- Admin-only for now: this table only feeds the Admin > Pending/Users screens
-- today. See the caveat at the bottom before relying on it for anything else.
drop policy if exists "profile_companies_admin_all" on profile_companies;
create policy "profile_companies_admin_all"
  on profile_companies for all
  to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- ============================================================================
-- IMPORTANT — things to double check:
--
-- 1) profiles.department_id: this change does NOT touch it at all. The admin
--    approve/save actions no longer send a department_id value (the app's
--    Department picker was removed from these rows), so newly approved users
--    will simply keep whatever department_id they already had (null, for a
--    fresh signup). If profiles.department_id has a NOT NULL constraint
--    without a default, approving a user will start failing at the database
--    level — check that constraint before relying on this. This migration
--    deliberately leaves it as-is per your instruction not to touch
--    department handling; relaxing that constraint (if it exists) is a
--    separate decision for you to make.
--
-- 2) RLS is admin-only right now (both directions: only admins can read or
--    write rows in this table). That's fine for the current use — nothing
--    outside the Admin screens reads this table, and the Companies tab still
--    shows every company to every approved user regardless of assignment.
--    If you later want a user's own company assignments to matter (e.g. to
--    restrict which companies/processes they can see, or just to let a user
--    see their own assignments), you'll need to add a SELECT policy such as
--    `profile_id = auth.uid()` — the current policy does not allow that.
--
-- 3) No RLS changes were made to `companies` or `processes` — assignments in
--    this table are captured but not yet enforced anywhere. If the intent is
--    eventually to scope visibility by company assignment, that's follow-up
--    work on those tables' policies, not something this migration does.
-- ============================================================================
