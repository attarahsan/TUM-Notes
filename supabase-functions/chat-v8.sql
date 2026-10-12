-- v8: add members to an existing group (admin only, invite = pending + notification)
-- Frontend: group info modal -> "Add members". Same invite flow as create_group.

CREATE OR REPLACE FUNCTION public.add_group_members(p_group_id bigint, p_usernames text[])
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_name text;
  v_admin text;
  v_gname text;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
  v_un text; v_target_uid text; v_target_name text;
  v_added bigint := 0;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT admin_uid, name INTO v_admin, v_gname FROM public.chat_groups WHERE id = p_group_id;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'group not found'; END IF;
  IF v_admin <> v_uid THEN RAISE EXCEPTION 'only admin can add members'; END IF;
  v_name := public.display_name(v_uid);
  IF p_usernames IS NOT NULL THEN
    FOREACH v_un IN ARRAY p_usernames LOOP
      v_un := TRIM(v_un);
      IF v_un = '' THEN CONTINUE; END IF;
      SELECT uid INTO v_target_uid FROM public.users WHERE lower(username) = lower(v_un);
      IF v_target_uid IS NULL OR v_target_uid = v_uid THEN CONTINUE; END IF;
      IF EXISTS (SELECT 1 FROM public.group_members WHERE group_id = p_group_id AND user_uid = v_target_uid) THEN CONTINUE; END IF;
      v_target_name := public.display_name(v_target_uid);
      INSERT INTO public.group_members(group_id, user_uid, user_name, status, invited_by, created_at)
      VALUES (p_group_id, v_target_uid, v_target_name, 'pending', v_uid, v_now);
      INSERT INTO public.notifications(user_id, title, body, link)
      VALUES (v_target_uid, '👥 Group invite',
              v_name || ' ne aapko "' || v_gname || '" group me add kiya hye. Approve karein to join ho jayenge.',
              'groupinvite:' || p_group_id);
      v_added := v_added + 1;
    END LOOP;
  END IF;
  RETURN v_added;
END; $$;

GRANT EXECUTE ON FUNCTION public.add_group_members(bigint, text[]) TO authenticated;
