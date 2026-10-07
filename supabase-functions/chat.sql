-- Anonymous realtime chat (TUM Notes Hub)
-- Run ONCE in Supabase Dashboard > SQL Editor. Safe to re-run.
CREATE TABLE IF NOT EXISTS public.chat_messages (
  id bigserial PRIMARY KEY,
  sender_id text NOT NULL,
  text text NOT NULL CHECK (char_length(text) BETWEEN 1 AND 500),
  created_at bigint NOT NULL DEFAULT ((extract(epoch from now()) * 1000)::bigint)
);
ALTER TABLE public.chat_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS chat_read_auth ON public.chat_messages;
CREATE POLICY chat_read_auth ON public.chat_messages
  FOR SELECT TO authenticated USING (true);
DROP POLICY IF EXISTS chat_ins_own ON public.chat_messages;
CREATE POLICY chat_ins_own ON public.chat_messages
  FOR INSERT TO authenticated WITH CHECK (sender_id = auth.uid()::text);
DROP POLICY IF EXISTS chat_del_admin ON public.chat_messages;
CREATE POLICY chat_del_admin ON public.chat_messages
  FOR DELETE TO authenticated USING (
    EXISTS (SELECT 1 FROM public.users WHERE users.uid = auth.uid()::text AND users.is_admin = true)
  );
-- realtime feed for the chat UI
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND tablename = 'chat_messages'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.chat_messages;
  END IF;
END $$;
