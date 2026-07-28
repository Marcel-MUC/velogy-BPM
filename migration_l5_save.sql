-- ============================================================================
-- Migration: L5 (work instructions) Save / Edit toggle
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- ============================================================================

-- Tasks gain their own lock flag, mirroring l2_locked (processes), l3_locked
-- (subprocesses) and l4_locked (steps). No RLS changes needed: the app already
-- updates rows on `tasks` for existing actions (add/remove task, lock L4), so
-- the existing UPDATE policy already covers this new column.
alter table tasks add column if not exists l5_locked boolean not null default false;
