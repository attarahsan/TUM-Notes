-- Fix: group_member_list had PL/pgSQL variable/column ambiguity
-- (RETURNS TABLE columns user_uid/status clashed with unqualified references
--  in the membership check -> 'column reference ... is ambiguous').
-- Every column reference is now table-qualified.

CREATE OR REPLACE FUNCTION public.group_member_list(p_group_id bigint)
RETURNS TABLE(user_uid text, user_name text, status text, is_admin boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text; v_admin text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.group_members gm
    WHERE gm.group_id = p_group_id AND gm.user_uid = v_uid AND gm.status = 'member'
  ) THEN
    RAISE EXCEPTION 'not a member';
  END IF;
  SELECT g.admin_uid INTO v_admin FROM public.chat_groups g WHERE g.id = p_group_id;
  RETURN QUERY
    SELECT gm2.user_uid, gm2.user_name, gm2.status, (gm2.user_uid = v_admin)
    FROM public.group_members gm2
    WHERE gm2.group_id = p_group_id
    ORDER BY gm2.created_at;
END; $$;
