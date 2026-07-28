-- ============================================================================
-- Migration: Company + Mega-Cycle navigation
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Review each section before running — especially the RLS note at the bottom,
-- which depends on your current policies and this script cannot detect them.
-- ============================================================================

-- 1) New companies table -----------------------------------------------------
create table if not exists companies (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

alter table companies enable row level security;

-- Any approved/authenticated user can see the list of companies.
drop policy if exists "companies_select_authenticated" on companies;
create policy "companies_select_authenticated"
  on companies for select
  to authenticated
  using (true);

-- No direct INSERT/UPDATE/DELETE policy is added on purpose: company creation
-- goes through the create_company_with_processes() function below, which runs
-- as SECURITY DEFINER and enforces the admin check itself. Regular clients
-- cannot insert into companies directly.

-- Seed the one company that exists today so existing processes have a home.
insert into companies (name) values ('Velogy')
  on conflict (name) do nothing;

-- 2) Link processes to a company ---------------------------------------------
alter table processes add column if not exists company_id uuid references companies(id);

-- Backfill every existing process onto 'Velogy'.
update processes
set company_id = (select id from companies where name = 'Velogy')
where company_id is null;

alter table processes alter column company_id set not null;

-- Department is deferred, not removed: make sure it's optional going forward
-- (no-op if it was already nullable).
alter table processes alter column department_id drop not null;

-- Exactly one process per (company, mega-cycle name). Mega-cycle names are no
-- longer restricted to the 8 standards, so this is scoped per company, not global.
alter table processes drop constraint if exists processes_company_l1_name_key;
alter table processes add constraint processes_company_l1_name_key unique (company_id, l1_name);

-- 3) Atomic "create company + its mega-cycle processes" -----------------------
-- Wrapping both inserts in one PL/pgSQL function makes them succeed or fail
-- together — a partial failure can't leave a company with no processes or vice
-- versa. SECURITY DEFINER lets it bypass the (deliberately policy-less) insert
-- path on companies, but it re-checks the admin role itself before doing anything.
create or replace function create_company_with_processes(
  p_name text,
  p_process_names text[]
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_uid uuid := auth.uid();
  v_role text;
  v_name text;
begin
  select role into v_role from profiles where id = v_uid;
  if v_role is distinct from 'admin' then
    raise exception 'Only admins can create companies';
  end if;

  if p_name is null or trim(p_name) = '' then
    raise exception 'Company name is required';
  end if;

  insert into companies (name) values (trim(p_name)) returning id into v_company_id;

  foreach v_name in array p_process_names loop
    if trim(v_name) <> '' then
      insert into processes (l1_name, company_id, created_by, l1_locked, l2_locked)
      values (trim(v_name), v_company_id, v_uid, true, false);
    end if;
  end loop;

  return v_company_id;
end;
$$;

grant execute on function create_company_with_processes(text, text[]) to authenticated;

-- ============================================================================
-- IMPORTANT — review before/after running:
--
-- Adding one process to an existing company (the "⋯" company settings menu in
-- the app) and deleting a process both reuse the plain insert/delete calls that
-- already worked from the old "+ New Process" flow and the old dashboard's
-- admin delete button — so no new policy should be needed there, *provided*
-- your existing INSERT/DELETE policies on `processes` aren't themselves scoped
-- to a specific role you now want to change. The app only shows these actions
-- to admins, but that's a UI-level restriction, not a database one — if you
-- want it enforced at the database level too, tighten the INSERT/DELETE
-- policies on `processes` to require profiles.role = 'admin'.
--
-- Bigger caveat: if your current SELECT policy on `processes` (and the
-- subprocesses/steps/tasks/work_instructions it joins to) restricts visibility
-- by department_id (e.g. "department_id = caller's department, or admin"),
-- then any NEW process created through this flow has no department_id and
-- will only be visible to admins until one is assigned. Since department is
-- explicitly deferred for now, you likely want every approved user to see
-- every company/process regardless of department. If that's the case, update
-- your SELECT policy on `processes` (and cascade the same relaxation to its
-- child tables) to allow any row where the caller's profile status is
-- 'approved', instead of requiring a department match. This script does not
-- change that policy automatically because it doesn't know your current
-- policy names/definitions.
-- ============================================================================
