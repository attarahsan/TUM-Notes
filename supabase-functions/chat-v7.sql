-- v7: drop duplicate (old) function overloads that cause PGRST203
-- "Could not choose the best candidate function" on send_chat_message / send_private_message.
-- Old migrations created shorter versions; v3 added longer ones via CREATE OR REPLACE
-- which does NOT replace a different signature -> both overloads survived.
-- Keep only the newest (longest) signatures.

DROP FUNCTION IF EXISTS public.send_chat_message(text);
DROP FUNCTION IF EXISTS public.send_private_message(text, text);

-- verify no other stale overloads remain for the group sender
-- (send_group_message with fewer params would break the same way)
DROP FUNCTION IF EXISTS public.send_group_message(bigint, text);

-- display_name: never return NULL (no users row -> 'User' instead of NULL,
-- which broke create_group's NOT NULL admin_name for edge-case users)
CREATE OR REPLACE FUNCTION public.display_name(p_uid text)
RETURNS text LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(NULLIF(TRIM(COALESCE(u.username,'')), ''),
                  NULLIF(TRIM(COALESCE(u.name,'')), ''),
                  'User')
  FROM (SELECT 1) AS dummy
  LEFT JOIN public.users u ON u.uid = p_uid;
$$;
