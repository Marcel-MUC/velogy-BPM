-- ============================================================================
-- Migration: allow admins to write user_company_access_processes directly
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Requires migration_company_access_levels.sql to already be applied.
-- ============================================================================

-- migration_company_access_levels.sql gave user_company_access_processes only
-- a SELECT policy ("read your own rows") and deliberately no write policy,
-- with a comment that writes should go through "the same admin-only path as
-- company assignment" — but profile_companies' admin path is a direct
-- for-all RLS policy (profile_companies_admin_all), not an RPC, and no
-- equivalent was ever added here. The new Permissions tab writes to this
-- table directly from the client (mirroring how it already writes to
-- profile_companies), so it needs the same admin-checked policy.
drop policy if exists "ucap_admin_write" on user_company_access_processes;
create policy "ucap_admin_write"
  on user_company_access_processes for all
  to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') )
  with check ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- This is additive: the existing "ucap_select_own" policy from
-- migration_company_access_levels.sql is untouched, so a non-admin can still
-- only read their own rows and still can't write at all.
