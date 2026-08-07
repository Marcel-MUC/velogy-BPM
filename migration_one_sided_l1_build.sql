-- ============================================================================
-- Migration: allow one-sided mega-cycles to be drilled into the build tool.
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- Requires migration_target_build.sql to already be applied.
--
-- Previously a root-level target_items/build_completions row
-- (parent_target_item_id is null) required BOTH l1_process_a_id and
-- l1_process_b_id to be set, since every root scope started from a matched
-- L1 pair. Now a root scope can also start from a mega-cycle that only
-- exists in one company, so only one of the two needs to be set — both
-- still can't be null at once, since that's not a valid root scope.
-- ============================================================================

alter table target_items drop constraint if exists target_items_root_check;
alter table target_items add constraint target_items_root_check check (
  (parent_target_item_id is not null and l1_process_a_id is null and l1_process_b_id is null)
  or (parent_target_item_id is null and (l1_process_a_id is not null or l1_process_b_id is not null))
);

alter table build_completions drop constraint if exists build_completions_root_check;
alter table build_completions add constraint build_completions_root_check check (
  (parent_target_item_id is not null and l1_process_a_id is null and l1_process_b_id is null)
  or (parent_target_item_id is null and (l1_process_a_id is not null or l1_process_b_id is not null))
);
