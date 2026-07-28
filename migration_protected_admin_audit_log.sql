-- ============================================================================
-- Migration: protected super admin + audit log
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- ============================================================================

-- 1) Protected super admin --------------------------------------------------
alter table profiles add column if not exists is_protected boolean not null default false;

-- One-off: protect the specific account confirmed by the user (not something
-- the UI ever sets).
update profiles set is_protected = true where email = 'marcel.pfitzner@aequita.com';

-- Enforced in the database, not just hidden in the UI: any UPDATE that would
-- move a protected row's role away from 'admin' or its status away from
-- 'approved' is rejected outright, even if called directly (e.g. via the API
-- or SQL editor) rather than through the app.
create or replace function prevent_protected_profile_changes()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if OLD.is_protected = true then
    if NEW.role is distinct from 'admin' then
      raise exception 'This profile is protected and cannot be demoted from admin.';
    end if;
    if NEW.status is distinct from 'approved' then
      raise exception 'This profile is protected and its status cannot be changed.';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_prevent_protected_profile_changes on profiles;
create trigger trg_prevent_protected_profile_changes
  before update on profiles
  for each row
  execute function prevent_protected_profile_changes();

-- Note: this does NOT also lock the is_protected flag itself — only role and
-- status are guarded, per the request. If you want to prevent someone from
-- unprotecting the row first and then changing it, that's a follow-up.

-- 2) Audit log ----------------------------------------------------------------
create table if not exists audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references profiles(id),
  target_id uuid references profiles(id),
  action text not null,
  old_value text,
  new_value text,
  created_at timestamptz not null default now()
);

alter table audit_log enable row level security;

drop policy if exists "audit_log_admin_select" on audit_log;
create policy "audit_log_admin_select"
  on audit_log for select
  to authenticated
  using ( exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin') );

-- The app inserts audit rows directly from the client (from inside
-- updateUser/approveUser/rejectUser/saveAccessModal) right after each
-- underlying change succeeds, using the CALLING admin as actor_id — this
-- needs an INSERT policy, so "no policy for regular clients" here means "no
-- policy for non-admins", not "no policy at all". actor_id = auth.uid() stops
-- an admin from logging an action under someone else's name.
drop policy if exists "audit_log_admin_insert" on audit_log;
create policy "audit_log_admin_insert"
  on audit_log for insert
  to authenticated
  with check (
    exists (select 1 from profiles p where p.id = auth.uid() and p.role = 'admin')
    and actor_id = auth.uid()
  );

-- Deliberately no UPDATE or DELETE policy at all, for anyone (including
-- admins, via the app) — audit rows are append-only/immutable. Removing an
-- entry, if ever needed, would have to go through the Supabase dashboard
-- with service-role access, bypassing RLS entirely.
