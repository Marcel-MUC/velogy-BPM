-- ============================================================================
-- Migration: simplify profiles.role to just ('admin', 'user')
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- ============================================================================

-- Drop whatever the current check constraint on profiles.role is called —
-- dynamically, since I can't see the actual constraint name from here. This
-- finds any CHECK constraint on `profiles` whose definition mentions `role`.
do $$
declare
  con record;
begin
  for con in
    select conname from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) ilike '%role%'
  loop
    execute format('alter table profiles drop constraint %I', con.conname);
  end loop;
end $$;

-- Backfill BEFORE adding the new, stricter constraint (the old constraint is
-- already gone at this point, so this won't violate it).
update profiles set role = 'user' where role in ('process_owner','viewer');

alter table profiles add constraint profiles_role_check check (role in ('admin','user'));

-- ============================================================================
-- Note: can_view()/can_edit() (from migration_company_access_levels.sql)
-- already only special-case role='admin' and otherwise fall through to
-- profile_companies-based scoping — 'process_owner'/'viewer' were never
-- checked directly in those functions, only used elsewhere in the app to
-- pick a default level, which is being removed in this same change. No
-- function changes needed here.
-- ============================================================================
