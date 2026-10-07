-- Chat privacy fix: clients must NEVER see real sender UUIDs.
-- Real auth.uid() is mapped to an opaque per-user anon token in a private table
-- (no RLS policies => clients cannot read or write it). chat_messages.sender_id
-- now holds only the opaque token, so realtime + SELECT stay safe.
-- Inserts go through the send_chat_message() RPC (500-char + 3s anti-spam enforced
-- server-side). Run in Supabase Dashboard > SQL Editor. Safe to re-run.

CREATE TABLE IF NOT EXISTS public.chat_identities (
  user_id text PRIMARY KEY,
  anon_token text UNIQUE NOT NULL,
  created_at bigint NOT NULL DEFAULT ((extract(epoch from now()) * 1000)::bigint)
);
ALTER TABLE public.chat_identities ENABLE ROW LEVEL SECURITY;
-- intentionally NO policies: only SECURITY DEFINER functions touch this table

CREATE OR REPLACE FUNCTION public.send_chat_message(p_text text)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_tok text;
  v_last bigint;
  v_id bigint;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF char_length(p_text) < 1 OR char_length(p_text) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  SELECT anon_token INTO v_tok FROM public.chat_identities WHERE user_id = v_uid;
  IF v_tok IS NULL THEN
    v_tok := 'a' || substr(md5(v_uid || ':' || v_now::text || ':' || md5(random()::text)), 1, 15);
    INSERT INTO public.chat_identities(user_id, anon_token) VALUES (v_uid, v_tok);
  END IF;
  SELECT max(created_at) INTO v_last FROM public.chat_messages WHERE sender_id = v_tok;
  IF v_last IS NOT NULL AND v_now - v_last < 3000 THEN RAISE EXCEPTION 'slow down'; END IF;
  INSERT INTO public.chat_messages(sender_id, text, created_at)
  VALUES (v_tok, p_text, v_now) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.my_anon_token()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text; v_tok text;
BEGIN
  IF v_uid IS NULL THEN RETURN NULL; END IF;
  SELECT anon_token INTO v_tok FROM public.chat_identities WHERE user_id = v_uid;
  RETURN v_tok;
END; $$;

-- clients may no longer insert directly (RPC only); reads/deletes unchanged
DROP POLICY IF EXISTS chat_ins_own ON public.chat_messages;
