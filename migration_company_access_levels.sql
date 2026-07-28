-- ============================================================================
-- Migration: company-first access levels (view/edit) and scope (all/specific)
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
--
-- Builds on migration_profile_companies.sql (the profile_companies table).
-- Assumes can_view(uuid) and can_edit(uuid, uuid) already exist in your
-- database per your current department-based RLS setup and are referenced
-- by policies on processes/subprocesses/steps/tasks/work_instructions.
--
-- THIS IS A BREAKING CHANGE to your permission model. Section 3 wipes every
-- existing RLS policy on processes/subprocesses/steps/tasks/work_instructions,
-- and section 5 replaces them with company/process-scoped equivalents — read
-- the comments there before running. Consider testing against a staging
-- project or a copy of your data first if you have one available.
-- ============================================================================

-- 1) profile_companies gains level + scope ------------------------------------
-- scope='all'      -> level applies to every process under that company.
-- scope='specific' -> level applies only to the processes listed in the new
--                      user_company_access_processes table for that row.
-- A user can now hold several rows for the same company at once (e.g. an
-- 'all'/'view' row plus a 'specific'/'edit' row for one process), so the old
-- one-row-per-(profile,company) constraint has to go.
alter table profile_companies add column if not exists level text;
alter table profile_companies add column if not exists scope text;

update profile_companies set scope = 'all' where scope is null;

update profile_companies pc
set level = case
  when pr.role in ('admin','process_owner') then 'edit'
  when pr.role = 'viewer' then 'view'
  else 'view'
end
from profiles pr
where pr.id = pc.profile_id and pc.level is null;

update profile_companies set level = 'view' where level is null;

alter table profile_companies
  alter column level set default 'view',
  alter column scope set default 'all',
  alter column level set not null,
  alter column scope set not null;

alter table profile_companies drop constraint if exists profile_companies_level_check;
alter table profile_companies add constraint profile_companies_level_check
  check (level in ('view','edit'));

alter table profile_companies drop constraint if exists profile_companies_scope_check;
alter table profile_companies add constraint profile_companies_scope_check
  check (scope in ('all','specific'));

-- Default-name guess for the UNIQUE(profile_id, company_id) constraint from
-- migration_profile_companies.sql — this is Postgres's actual default naming
-- convention for an inline table-level unique constraint with no explicit
-- name, so it should match as long as that table wasn't renamed since.
alter table profile_companies drop constraint if exists profile_companies_profile_id_company_id_key;

-- 2) Which processes a 'specific'-scope row covers ----------------------------
create table if not exists user_company_access_processes (
  id uuid primary key default gen_random_uuid(),
  user_company_access_id uuid not null references profile_companies(id) on delete cascade,
  process_id uuid not null references processes(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (user_company_access_id, process_id)
);

alter table user_company_access_processes enable row level security;

drop policy if exists "ucap_select_own" on user_company_access_processes;
create policy "ucap_select_own"
  on user_company_access_processes for select
  to authenticated
  using (
    exists (
      select 1 from profile_companies pc
      where pc.id = user_company_access_processes.user_company_access_id
        and pc.profile_id = auth.uid()
    )
  );
-- No INSERT/UPDATE/DELETE policy for `authenticated` on purpose — writes to
-- this table go through the same admin-only path as company assignment
-- already does (not a policy grant to regular clients).

-- 3) Drop every existing policy on the tables that call can_view/can_edit ----
-- This has to happen BEFORE the old function signatures are dropped: Postgres
-- tracks a dependency between a policy and any function its USING/WITH CHECK
-- expression calls, so `drop function can_view(uuid)` would fail outright
-- while any policy still references it. Dropping by exact name isn't
-- reliable here since I can't see your current policy names from this
-- editor — instead this dynamically drops EVERY existing policy on these 5
-- tables (whatever they're called), which also clears the dependency. If any
-- of these tables has a policy unrelated to view/edit scoping that you want
-- to keep, pull it out of this list and reapply it manually afterward.
do $$
declare
  pol record;
begin
  for pol in
    select schemaname, tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('processes','subprocesses','steps','tasks','work_instructions')
  loop
    execute format('drop policy if exists %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
  end loop;
end $$;

-- 4) can_view / can_edit — new (target_company, target_process) signatures ---
-- The old 1-arg can_view and 2-arg can_edit are dropped, not overloaded (safe
-- now that no policy references them). "edit" always implies "view", so
-- can_view doesn't filter by level at all: any matching row (regardless of
-- level) grants view.
drop function if exists can_view(uuid);
drop function if exists can_edit(uuid, uuid);

create or replace function can_view(target_company uuid, target_process uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_row record;
begin
  select (role = 'admin') into v_is_admin from profiles where id = v_uid;
  if v_is_admin then
    return true;
  end if;

  for v_row in
    select id, scope from profile_companies
    where profile_id = v_uid and company_id = target_company
  loop
    if v_row.scope = 'all' then
      return true;
    end if;
    if v_row.scope = 'specific' and target_process is not null then
      if exists (
        select 1 from user_company_access_processes ucap
        where ucap.user_company_access_id = v_row.id
          and ucap.process_id = target_process
      ) then
        return true;
      end if;
    end if;
  end loop;

  return false;
end;
$$;

create or replace function can_edit(target_company uuid, target_process uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_is_admin boolean;
  v_row record;
begin
  select (role = 'admin') into v_is_admin from profiles where id = v_uid;
  if v_is_admin then
    return true;
  end if;

  for v_row in
    select id, scope from profile_companies
    where profile_id = v_uid and company_id = target_company and level = 'edit'
  loop
    if v_row.scope = 'all' then
      return true;
    end if;
    if v_row.scope = 'specific' and target_process is not null then
      if exists (
        select 1 from user_company_access_processes ucap
        where ucap.user_company_access_id = v_row.id
          and ucap.process_id = target_process
      ) then
        return true;
      end if;
    end if;
  end loop;

  return false;
end;
$$;

grant execute on function can_view(uuid, uuid) to authenticated;
grant execute on function can_edit(uuid, uuid) to authenticated;

-- 5) New policies on processes and everything under it, using the new
--    (target_company, target_process) functions from section 4.
-- processes: target_process = its own id, target_company = its own company_id.
create policy "processes_select_scoped"
  on processes for select to authenticated
  using ( can_view(processes.company_id, processes.id) );

create policy "processes_write_scoped"
  on processes for all to authenticated
  using ( can_edit(processes.company_id, processes.id) )
  with check ( can_edit(processes.company_id, processes.id) );

-- subprocesses: process_id -> processes.
create policy "subprocesses_select_scoped"
  on subprocesses for select to authenticated
  using ( exists (
    select 1 from processes pr
    where pr.id = subprocesses.process_id
      and can_view(pr.company_id, pr.id)
  ) );

create policy "subprocesses_write_scoped"
  on subprocesses for all to authenticated
  using ( exists (
    select 1 from processes pr
    where pr.id = subprocesses.process_id
      and can_edit(pr.company_id, pr.id)
  ) )
  with check ( exists (
    select 1 from processes pr
    where pr.id = subprocesses.process_id
      and can_edit(pr.company_id, pr.id)
  ) );

-- steps: subprocess_id -> subprocesses -> processes.
create policy "steps_select_scoped"
  on steps for select to authenticated
  using ( exists (
    select 1 from subprocesses sp
    join processes pr on pr.id = sp.process_id
    where sp.id = steps.subprocess_id
      and can_view(pr.company_id, pr.id)
  ) );

create policy "steps_write_scoped"
  on steps for all to authenticated
  using ( exists (
    select 1 from subprocesses sp
    join processes pr on pr.id = sp.process_id
    where sp.id = steps.subprocess_id
      and can_edit(pr.company_id, pr.id)
  ) )
  with check ( exists (
    select 1 from subprocesses sp
    join processes pr on pr.id = sp.process_id
    where sp.id = steps.subprocess_id
      and can_edit(pr.company_id, pr.id)
  ) );

-- tasks: step_id -> steps -> subprocesses -> processes.
create policy "tasks_select_scoped"
  on tasks for select to authenticated
  using ( exists (
    select 1 from steps st
    join subprocesses sp on sp.id = st.subprocess_id
    join processes pr on pr.id = sp.process_id
    where st.id = tasks.step_id
      and can_view(pr.company_id, pr.id)
  ) );

create policy "tasks_write_scoped"
  on tasks for all to authenticated
  using ( exists (
    select 1 from steps st
    join subprocesses sp on sp.id = st.subprocess_id
    join processes pr on pr.id = sp.process_id
    where st.id = tasks.step_id
      and can_edit(pr.company_id, pr.id)
  ) )
  with check ( exists (
    select 1 from steps st
    join subprocesses sp on sp.id = st.subprocess_id
    join processes pr on pr.id = sp.process_id
    where st.id = tasks.step_id
      and can_edit(pr.company_id, pr.id)
  ) );

-- work_instructions: task_id -> tasks -> steps -> subprocesses -> processes.
create policy "work_instructions_select_scoped"
  on work_instructions for select to authenticated
  using ( exists (
    select 1 from tasks tk
    join steps st on st.id = tk.step_id
    join subprocesses sp on sp.id = st.subprocess_id
    join processes pr on pr.id = sp.process_id
    where tk.id = work_instructions.task_id
      and can_view(pr.company_id, pr.id)
  ) );

create policy "work_instructions_write_scoped"
  on work_instructions for all to authenticated
  using ( exists (
    select 1 from tasks tk
    join steps st on st.id = tk.step_id
    join subprocesses sp on sp.id = st.subprocess_id
    join processes pr on pr.id = sp.process_id
    where tk.id = work_instructions.task_id
      and can_edit(pr.company_id, pr.id)
  ) )
  with check ( exists (
    select 1 from tasks tk
    join steps st on st.id = tk.step_id
    join subprocesses sp on sp.id = st.subprocess_id
    join processes pr on pr.id = sp.process_id
    where tk.id = work_instructions.task_id
      and can_edit(pr.company_id, pr.id)
  ) );

-- ============================================================================
-- Deliberately out of scope (per instructions) — no UI changes here:
--
-- There is still no way for an admin to create a scope='specific' grant (no
-- mega-cycle picker in the approval/Users tab). The company multi-select
-- already in index.html keeps working exactly as before and keeps creating
-- scope='all' rows (via the default set in section 1) — it never touches
-- level or scope explicitly, and 'view'/'all' vs the role-based backfill only
-- affects pre-existing rows, not new ones created by that UI. If you want
-- new admin-created assignments to default to 'edit' instead of 'view'
-- (matching how department-based access worked before), that's a follow-up
-- decision for the approval flow, not something this migration decides.
--
-- Everything needed for a future "assign to specific mega-cycles" UI already
-- exists: user_company_access_processes plus the scope column on
-- profile_companies. That UI can be built purely as a front-end change
-- against these tables without another migration.
-- ============================================================================
