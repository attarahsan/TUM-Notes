-- Chat v4: fix infinite recursion in group RLS policies.
-- The gmem_read policy queried group_members inside its own USING clause -> recursion.
-- Fix: SECURITY DEFINER helper bypasses RLS, so policies no longer self-reference.
-- Run in Supabase Dashboard > SQL Editor. Safe to re-run.

CREATE OR REPLACE FUNCTION public.is_group_member(p_group_id bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.group_members
    WHERE group_id = p_group_id AND user_uid = auth.uid()::text AND status = 'member'
  );
$$;

DROP POLICY IF EXISTS cg_read ON public.chat_groups;
CREATE POLICY cg_read ON public.chat_groups FOR SELECT
  USING (public.is_group_member(id));

DROP POLICY IF EXISTS gmem_read ON public.group_members;
CREATE POLICY gmem_read ON public.group_members FOR SELECT
  USING (user_uid = auth.uid()::text OR public.is_group_member(group_id));

DROP POLICY IF EXISTS gmsg_read ON public.group_messages;
CREATE POLICY gmsg_read ON public.group_messages FOR SELECT
  USING (public.is_group_member(group_id));
