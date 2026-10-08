-- v6: admin can leave group (transfers adminship to oldest member, or deletes group if alone)
-- also adds rename_group for admins. All column refs qualified to avoid ambiguity.

CREATE OR REPLACE FUNCTION public.remove_group_member(p_group_id bigint, p_uid text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text; v_admin text; v_new_admin text; v_new_admin_name text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT g.admin_uid INTO v_admin FROM public.chat_groups g WHERE g.id = p_group_id;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'no group'; END IF;
  -- permission: admin can remove anyone; a member can only remove themselves (leave)
  IF v_uid <> v_admin AND v_uid <> p_uid THEN RAISE EXCEPTION 'not allowed'; END IF;
  IF p_uid = v_admin THEN
    -- admin is leaving: transfer adminship to oldest remaining member
    SELECT gm.user_uid INTO v_new_admin FROM public.group_members gm
    WHERE gm.group_id = p_group_id AND gm.user_uid <> v_admin AND gm.status = 'member'
    ORDER BY gm.created_at ASC LIMIT 1;
    IF v_new_admin IS NULL THEN
      -- admin is the only member: delete the whole group
      DELETE FROM public.group_messages WHERE group_id = p_group_id;
      DELETE FROM public.group_members WHERE group_id = p_group_id;
      DELETE FROM public.chat_groups WHERE id = p_group_id;
      RETURN;
    END IF;
    v_new_admin_name := public.display_name(v_new_admin);
    UPDATE public.chat_groups SET admin_uid = v_new_admin, admin_name = v_new_admin_name WHERE id = p_group_id;
  END IF;
  DELETE FROM public.group_members WHERE group_id = p_group_id AND user_uid = p_uid;
END; $$;

-- admin renames the group
CREATE OR REPLACE FUNCTION public.rename_group(p_group_id bigint, p_name text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text; v_admin text; v_clean text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT g.admin_uid INTO v_admin FROM public.chat_groups g WHERE g.id = p_group_id;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'no group'; END IF;
  IF v_uid <> v_admin THEN RAISE EXCEPTION 'only admin can rename'; END IF;
  v_clean := TRIM(COALESCE(p_name,''));
  IF char_length(v_clean) < 2 OR char_length(v_clean) > 40 THEN RAISE EXCEPTION 'bad group name'; END IF;
  UPDATE public.chat_groups SET name = v_clean WHERE id = p_group_id;
END; $$;
