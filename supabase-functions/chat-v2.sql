-- Chat v2: real usernames (anonymous removed) + private 1-on-1 messages.
-- Run in Supabase Dashboard > SQL Editor. Safe to re-run.

-- 1. Group chat now stores the sender's real name
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS sender_name text;

-- send_chat_message: sender_id = real auth uid, sender_name = users.name
CREATE OR REPLACE FUNCTION public.send_chat_message(p_text text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_name text;
  v_last bigint;
  v_id bigint;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF char_length(p_text) < 1 OR char_length(p_text) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  SELECT name INTO v_name FROM public.users WHERE uid = v_uid;
  v_name := COALESCE(NULLIF(TRIM(COALESCE(v_name,'')), ''), 'User');
  SELECT max(created_at) INTO v_last FROM public.chat_messages WHERE sender_id = v_uid;
  IF v_last IS NOT NULL AND v_now - v_last < 3000 THEN RAISE EXCEPTION 'slow down'; END IF;
  INSERT INTO public.chat_messages(sender_id, sender_name, text, created_at)
  VALUES (v_uid, v_name, p_text, v_now) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

-- 2. Private 1-on-1 messages (WhatsApp-style)
CREATE TABLE IF NOT EXISTS public.private_messages (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sender_uid text NOT NULL,
  receiver_uid text NOT NULL,
  sender_name text NOT NULL DEFAULT '',
  text text NOT NULL,
  created_at bigint NOT NULL,
  read_at bigint
);
CREATE INDEX IF NOT EXISTS pm_participants_idx ON public.private_messages(sender_uid, receiver_uid, created_at DESC);
ALTER TABLE public.private_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS pm_select ON public.private_messages;
CREATE POLICY pm_select ON public.private_messages FOR SELECT USING (
  auth.uid()::text = sender_uid OR auth.uid()::text = receiver_uid
);
-- no INSERT/UPDATE/DELETE policies: writes go only through SECURITY DEFINER RPCs below

CREATE OR REPLACE FUNCTION public.send_private_message(p_to_uid text, p_text text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_name text;
  v_last bigint;
  v_id bigint;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF p_to_uid IS NULL OR p_to_uid = v_uid THEN RAISE EXCEPTION 'bad recipient'; END IF;
  IF char_length(p_text) < 1 OR char_length(p_text) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  SELECT name INTO v_name FROM public.users WHERE uid = v_uid;
  v_name := COALESCE(NULLIF(TRIM(COALESCE(v_name,'')), ''), 'User');
  SELECT max(created_at) INTO v_last FROM public.private_messages WHERE sender_uid = v_uid;
  IF v_last IS NOT NULL AND v_now - v_last < 2000 THEN RAISE EXCEPTION 'slow down'; END IF;
  INSERT INTO public.private_messages(sender_uid, receiver_uid, sender_name, text, created_at)
  VALUES (v_uid, p_to_uid, v_name, p_text, v_now) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

-- conversation list for the logged-in user
CREATE OR REPLACE FUNCTION public.my_conversations()
RETURNS TABLE(partner_uid text, partner_name text, last_text text, last_at bigint, unread_count bigint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  RETURN QUERY
  WITH mine AS (
    SELECT
      CASE WHEN sender_uid = v_uid THEN receiver_uid ELSE sender_uid END AS p_uid,
      text, created_at,
      CASE WHEN receiver_uid = v_uid AND read_at IS NULL THEN 1 ELSE 0 END AS is_unread
    FROM public.private_messages
    WHERE sender_uid = v_uid OR receiver_uid = v_uid
  ),
  ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY p_uid ORDER BY created_at DESC) AS rn FROM mine
  )
  SELECT r.p_uid,
         COALESCE(NULLIF(TRIM(COALESCE(u.name,'')), ''), 'User'),
         r.text, r.created_at,
         (SELECT COUNT(*) FROM mine m2 WHERE m2.p_uid = r.p_uid AND m2.is_unread = 1)
  FROM ranked r
  LEFT JOIN public.users u ON u.uid = r.p_uid
  WHERE r.rn = 1
  ORDER BY r.created_at DESC;
END; $$;

-- mark a thread as read
CREATE OR REPLACE FUNCTION public.mark_chat_read(p_partner_uid text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  UPDATE public.private_messages
  SET read_at = ((extract(epoch from now()) * 1000)::bigint)
  WHERE receiver_uid = v_uid AND sender_uid = p_partner_uid AND read_at IS NULL;
END; $$;

-- realtime for private messages
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.private_messages;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
