-- TUM Notes Hub — admin activity panel migration (visits, sign-ins, sign-ups)
-- Run once in the Supabase SQL editor (project: tum-notes-hub).

CREATE TABLE IF NOT EXISTS public.activity_log (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text,                       -- auth uid (users.uid); NULL for guest visits
  name text NOT NULL DEFAULT '',
  email text NOT NULL DEFAULT '',
  event text NOT NULL,                -- 'visit' | 'signin' | 'signup'
  page text NOT NULL DEFAULT '',
  user_agent text NOT NULL DEFAULT '',
  created_at bigint NOT NULL DEFAULT ((extract(epoch from now()) * 1000))::bigint
);
CREATE INDEX IF NOT EXISTS activity_log_event_time ON public.activity_log (event, created_at DESC);
CREATE INDEX IF NOT EXISTS activity_log_user ON public.activity_log (user_id);

ALTER TABLE public.activity_log ENABLE ROW LEVEL SECURITY;

-- inserts: logged-in users log their own rows; guests log anonymous rows
DROP POLICY IF EXISTS act_ins_auth ON public.activity_log;
CREATE POLICY act_ins_auth ON public.activity_log FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = user_id OR user_id IS NULL);
DROP POLICY IF EXISTS act_ins_anon ON public.activity_log;
CREATE POLICY act_ins_anon ON public.activity_log FOR INSERT TO anon
  WITH CHECK (user_id IS NULL);

-- reads: admins only
DROP POLICY IF EXISTS act_read_admin ON public.activity_log;
CREATE POLICY act_read_admin ON public.activity_log FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM public.users u WHERE u.uid = auth.uid()::text AND u.is_admin = true));

-- explicit GRANTs: Supabase no longer auto-grants table privileges on new tables
GRANT SELECT, INSERT ON public.activity_log TO authenticated;
GRANT INSERT ON public.activity_log TO anon;

-- verification
SELECT tablename, policyname FROM pg_policies WHERE schemaname='public' AND tablename='activity_log' ORDER BY 1,2;
