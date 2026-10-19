-- Chat message editing (Pro Notes)
-- Run ONCE in Supabase Dashboard > SQL Editor. Safe to re-run.
-- Adds edited_at tracking + SECURITY DEFINER RPCs so users can edit their OWN messages.

-- 1) edited_at columns
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS edited_at bigint;
ALTER TABLE public.private_messages ADD COLUMN IF NOT EXISTS edited_at bigint;
ALTER TABLE public.group_messages ADD COLUMN IF NOT EXISTS edited_at bigint;

-- 2) Edit own public chat message
CREATE OR REPLACE FUNCTION public.edit_chat_message(p_id bigint, p_text text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF char_length(p_text) < 1 OR char_length(p_text) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  UPDATE public.chat_messages SET text = p_text, edited_at = ((extract(epoch from now()) * 1000)::bigint)
    WHERE id = p_id AND sender_id = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'not your message'; END IF;
  RETURN true;
END $$;

-- 3) Edit own private message
CREATE OR REPLACE FUNCTION public.edit_private_message(p_id bigint, p_text text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF char_length(p_text) < 1 OR char_length(p_text) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  UPDATE public.private_messages SET text = p_text, edited_at = ((extract(epoch from now()) * 1000)::bigint)
    WHERE id = p_id AND sender_uid = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'not your message'; END IF;
  RETURN true;
END $$;

-- 4) Edit own group message
CREATE OR REPLACE FUNCTION public.edit_group_message(p_id bigint, p_text text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF char_length(p_text) < 1 OR char_length(p_text) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  UPDATE public.group_messages SET text = p_text, edited_at = ((extract(epoch from now()) * 1000)::bigint)
    WHERE id = p_id AND sender_uid = v_uid;
  IF NOT FOUND THEN RAISE EXCEPTION 'not your message'; END IF;
  RETURN true;
END $$;
