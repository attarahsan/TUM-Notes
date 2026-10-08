-- Chat v3: usernames, voice messages, private notes, group chats, auto-moderation.
-- Run in Supabase Dashboard > SQL Editor. Safe to re-run.

-- ============ 1. USERNAMES ============
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS username text;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'users_username_lower_idx') THEN
    CREATE UNIQUE INDEX users_username_lower_idx ON public.users (lower(username));
  END IF;
END $$;

-- display name helper: username if set, else name, else 'User'
CREATE OR REPLACE FUNCTION public.display_name(p_uid text)
RETURNS text LANGUAGE sql STABLE SET search_path = public AS $$
  SELECT COALESCE(NULLIF(TRIM(COALESCE(username,'')), ''), NULLIF(TRIM(COALESCE(name,'')), ''), 'User')
  FROM public.users WHERE uid = p_uid;
$$;

CREATE OR REPLACE FUNCTION public.set_username(p_username text)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_un text := TRIM(COALESCE(p_username,''));
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF v_un !~ '^[A-Za-z0-9_]{3,20}$' THEN RAISE EXCEPTION 'bad username'; END IF;
  IF EXISTS (SELECT 1 FROM public.users WHERE lower(username) = lower(v_un) AND uid <> v_uid) THEN
    RAISE EXCEPTION 'username taken';
  END IF;
  UPDATE public.users SET username = v_un WHERE uid = v_uid;
  -- refresh chat display names for this user
  UPDATE public.chat_messages SET sender_name = v_un WHERE sender_id = v_uid;
  UPDATE public.private_messages SET sender_name = v_un WHERE sender_uid = v_uid;
  UPDATE public.group_messages SET sender_name = v_un WHERE sender_uid = v_uid;
  RETURN v_un;
END; $$;

-- ============ 2. VOICE MESSAGES ============
ALTER TABLE public.chat_messages ADD COLUMN IF NOT EXISTS voice_url text;
ALTER TABLE public.private_messages ADD COLUMN IF NOT EXISTS voice_url text;

-- chat-voice storage bucket (public read, authenticated write)
INSERT INTO storage.buckets (id, name, public)
VALUES ('chat-voice', 'chat-voice', true)
ON CONFLICT (id) DO NOTHING;

DROP POLICY IF EXISTS cv_read ON storage.objects;
CREATE POLICY cv_read ON storage.objects FOR SELECT USING (bucket_id = 'chat-voice');
DROP POLICY IF EXISTS cv_insert ON storage.objects;
CREATE POLICY cv_insert ON storage.objects FOR INSERT WITH CHECK (bucket_id = 'chat-voice' AND auth.role() = 'authenticated');
DROP POLICY IF EXISTS cv_delete ON storage.objects;
CREATE POLICY cv_delete ON storage.objects FOR DELETE USING (bucket_id = 'chat-voice' AND auth.role() = 'authenticated');

-- ============ 3. BAD-WORD AUTO-MODERATION ============
CREATE TABLE IF NOT EXISTS public.banned_words (word text PRIMARY KEY);
INSERT INTO public.banned_words(word) VALUES
('fuck'),('fucking'),('fucker'),('shit'),('bitch'),('bitches'),('asshole'),('dick'),('pussy'),
('bastard'),('whore'),('slut'),('porn'),('sexy'),('nude'),('lodu'),('lodo'),('chutiya'),('chutia'),
('bhosdike'),('bhosdi'),('madarchod'),('madar chod'),('behenchod'),('behen chod'),('gandu'),('gaandu'),
('randi'),('kutti'),('kutta'),('harami'),('haramzada'),('kanjar'),('kanjri'),('tatti'),('peshab'),
('lund'),('choot'),('phudi'),('gaand'),('tatte'),('khotay'),('ullu ka'),('nangi')
ON CONFLICT (word) DO NOTHING;

CREATE OR REPLACE FUNCTION public.reject_bad_language()
RETURNS trigger LANGUAGE plpgsql SET search_path = public AS $$
DECLARE v_w text;
BEGIN
  IF NEW.text IS NULL OR NEW.text = '' THEN RETURN NEW; END IF;
  SELECT word INTO v_w FROM public.banned_words
  WHERE NEW.text ~* ('\m' || regexp_replace(word, '([^a-zA-Z0-9])', '\\\1', 'g') || '\M')
  LIMIT 1;
  IF v_w IS NOT NULL THEN RAISE EXCEPTION 'inappropriate language'; END IF;
  RETURN NEW;
END; $$;

DROP TRIGGER IF EXISTS trg_chat_badlang ON public.chat_messages;
CREATE TRIGGER trg_chat_badlang BEFORE INSERT ON public.chat_messages
FOR EACH ROW EXECUTE FUNCTION public.reject_bad_language();
DROP TRIGGER IF EXISTS trg_pm_badlang ON public.private_messages;
CREATE TRIGGER trg_pm_badlang BEFORE INSERT ON public.private_messages
FOR EACH ROW EXECUTE FUNCTION public.reject_bad_language();

-- sender names now use username; voice_url supported
CREATE OR REPLACE FUNCTION public.send_chat_message(p_text text, p_voice_url text DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_name text;
  v_last bigint;
  v_id bigint;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF (p_text IS NULL OR p_text = '') AND (p_voice_url IS NULL OR p_voice_url = '') THEN RAISE EXCEPTION 'empty'; END IF;
  IF char_length(COALESCE(p_text,'')) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  v_name := public.display_name(v_uid);
  SELECT max(created_at) INTO v_last FROM public.chat_messages WHERE sender_id = v_uid;
  IF v_last IS NOT NULL AND v_now - v_last < 3000 THEN RAISE EXCEPTION 'slow down'; END IF;
  INSERT INTO public.chat_messages(sender_id, sender_name, text, voice_url, created_at)
  VALUES (v_uid, v_name, COALESCE(p_text,''), NULLIF(p_voice_url,''), v_now) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.send_private_message(p_to_uid text, p_text text, p_voice_url text DEFAULT NULL, p_note_id bigint DEFAULT NULL)
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
  IF (p_text IS NULL OR p_text = '') AND (p_voice_url IS NULL OR p_voice_url = '') AND p_note_id IS NULL THEN RAISE EXCEPTION 'empty'; END IF;
  IF char_length(COALESCE(p_text,'')) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  v_name := public.display_name(v_uid);
  SELECT max(created_at) INTO v_last FROM public.private_messages WHERE sender_uid = v_uid;
  IF v_last IS NOT NULL AND v_now - v_last < 2000 THEN RAISE EXCEPTION 'slow down'; END IF;
  INSERT INTO public.private_messages(sender_uid, receiver_uid, sender_name, text, voice_url, note_id, created_at)
  VALUES (v_uid, p_to_uid, v_name, COALESCE(p_text,''), NULLIF(p_voice_url,''), p_note_id, v_now) RETURNING id INTO v_id;
  RETURN v_id;
END; $$;

ALTER TABLE public.private_messages ADD COLUMN IF NOT EXISTS note_id bigint;

-- ============ 4. PRIVATE NOTES (chat-only selling) ============
ALTER TABLE public.notes ADD COLUMN IF NOT EXISTS visibility text NOT NULL DEFAULT 'public';

CREATE OR REPLACE FUNCTION public.can_view_private_note(p_note_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RETURN false; END IF;
  IF EXISTS (SELECT 1 FROM public.notes WHERE note_id = p_note_id AND seller_id = v_uid) THEN RETURN true; END IF;
  IF EXISTS (SELECT 1 FROM public.private_messages
             WHERE note_id = p_note_id AND (sender_uid = v_uid OR receiver_uid = v_uid)) THEN RETURN true; END IF;
  IF EXISTS (SELECT 1 FROM public.group_messages gm
             JOIN public.group_members gmem ON gmem.group_id = gm.group_id
             WHERE gm.note_id = p_note_id AND gmem.user_uid = v_uid AND gmem.status = 'member') THEN RETURN true; END IF;
  RETURN false;
END; $$;

-- private notes are invisible to the public; only seller / admin / chat participants can read
DROP POLICY IF EXISTS notes_read ON public.notes;
CREATE POLICY notes_read ON public.notes FOR SELECT USING (
  (status = 'approved' AND visibility = 'public')
  OR public.is_admin()
  OR public.can_view_private_note(note_id)
);
-- sellers may insert a private note directly as approved (skips public moderation queue)
DROP POLICY IF EXISTS notes_insert ON public.notes;
CREATE POLICY notes_insert ON public.notes FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = seller_id AND (status = 'pending' OR (status = 'approved' AND visibility = 'private')));

CREATE OR REPLACE FUNCTION public.publish_note(p_note_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  UPDATE public.notes SET visibility = 'public', status = 'pending'
  WHERE note_id = p_note_id AND seller_id = v_uid AND visibility = 'private';
END; $$;

-- ============ 5. GROUP CHATS ============
CREATE TABLE IF NOT EXISTS public.chat_groups (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name text NOT NULL,
  admin_uid text NOT NULL,
  admin_name text NOT NULL DEFAULT '',
  created_at bigint NOT NULL
);
CREATE TABLE IF NOT EXISTS public.group_members (
  group_id bigint NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  user_uid text NOT NULL,
  user_name text NOT NULL DEFAULT '',
  status text NOT NULL DEFAULT 'pending',
  invited_by text,
  last_read_at bigint NOT NULL DEFAULT 0,
  created_at bigint NOT NULL,
  PRIMARY KEY (group_id, user_uid)
);
CREATE TABLE IF NOT EXISTS public.group_messages (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  group_id bigint NOT NULL REFERENCES public.chat_groups(id) ON DELETE CASCADE,
  sender_uid text NOT NULL,
  sender_name text NOT NULL DEFAULT '',
  text text NOT NULL DEFAULT '',
  voice_url text,
  note_id bigint,
  created_at bigint NOT NULL
);
CREATE INDEX IF NOT EXISTS gm_group_idx ON public.group_messages(group_id, created_at DESC);

ALTER TABLE public.chat_groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;
-- no direct client policies: all writes through RPCs; reads scoped below
DROP POLICY IF EXISTS cg_read ON public.chat_groups;
CREATE POLICY cg_read ON public.chat_groups FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.group_members m WHERE m.group_id = id AND m.user_uid = auth.uid()::text AND m.status = 'member')
);
DROP POLICY IF EXISTS gmem_read ON public.group_members;
CREATE POLICY gmem_read ON public.group_members FOR SELECT USING (
  user_uid = auth.uid()::text OR
  EXISTS (SELECT 1 FROM public.group_members m2 WHERE m2.group_id = group_members.group_id AND m2.user_uid = auth.uid()::text AND m2.status = 'member')
);
DROP POLICY IF EXISTS gmsg_read ON public.group_messages;
CREATE POLICY gmsg_read ON public.group_messages FOR SELECT USING (
  EXISTS (SELECT 1 FROM public.group_members m WHERE m.group_id = group_messages.group_id AND m.user_uid = auth.uid()::text AND m.status = 'member')
);

DROP TRIGGER IF EXISTS trg_gmsg_badlang ON public.group_messages;
CREATE TRIGGER trg_gmsg_badlang BEFORE INSERT ON public.group_messages
FOR EACH ROW EXECUTE FUNCTION public.reject_bad_language();

-- create group + invite members by username (each gets a notification)
CREATE OR REPLACE FUNCTION public.create_group(p_name text, p_usernames text[])
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_name text;
  v_gid bigint;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
  v_un text; v_target_uid text; v_target_name text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF char_length(TRIM(COALESCE(p_name,''))) < 2 OR char_length(p_name) > 40 THEN RAISE EXCEPTION 'bad group name'; END IF;
  v_name := public.display_name(v_uid);
  INSERT INTO public.chat_groups(name, admin_uid, admin_name, created_at)
  VALUES (TRIM(p_name), v_uid, v_name, v_now) RETURNING id INTO v_gid;
  INSERT INTO public.group_members(group_id, user_uid, user_name, status, invited_by, last_read_at, created_at)
  VALUES (v_gid, v_uid, v_name, 'member', v_uid, v_now, v_now);
  IF p_usernames IS NOT NULL THEN
    FOREACH v_un IN ARRAY p_usernames LOOP
      v_un := TRIM(v_un);
      IF v_un = '' THEN CONTINUE; END IF;
      SELECT uid INTO v_target_uid FROM public.users WHERE lower(username) = lower(v_un);
      IF v_target_uid IS NULL OR v_target_uid = v_uid THEN CONTINUE; END IF;
      IF EXISTS (SELECT 1 FROM public.group_members WHERE group_id = v_gid AND user_uid = v_target_uid) THEN CONTINUE; END IF;
      v_target_name := public.display_name(v_target_uid);
      INSERT INTO public.group_members(group_id, user_uid, user_name, status, invited_by, created_at)
      VALUES (v_gid, v_target_uid, v_target_name, 'pending', v_uid, v_now);
      INSERT INTO public.notifications(user_id, title, body, link)
      VALUES (v_target_uid, '👥 Group invite',
              v_name || ' ne aapko "' || TRIM(p_name) || '" group me add kiya hye. Approve karein to join ho jayenge.',
              'groupinvite:' || v_gid);
    END LOOP;
  END IF;
  RETURN v_gid;
END; $$;

-- accept / decline a group invite
CREATE OR REPLACE FUNCTION public.respond_group_invite(p_group_id bigint, p_accept boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  IF p_accept THEN
    UPDATE public.group_members SET status = 'member', last_read_at = ((extract(epoch from now()) * 1000)::bigint)
    WHERE group_id = p_group_id AND user_uid = v_uid AND status = 'pending';
  ELSE
    DELETE FROM public.group_members WHERE group_id = p_group_id AND user_uid = v_uid AND status = 'pending';
  END IF;
  -- mark related invite notifications read
  UPDATE public.notifications SET is_read = true
  WHERE user_id = v_uid AND link = 'groupinvite:' || p_group_id AND is_read = false;
END; $$;

-- my groups with last message + unread
CREATE OR REPLACE FUNCTION public.my_groups()
RETURNS TABLE(group_id bigint, group_name text, admin_name text, is_admin boolean,
              last_text text, last_sender text, last_at bigint, unread_count bigint,
              member_count bigint, pending_invite boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  RETURN QUERY
  SELECT g.id, g.name, g.admin_name, (g.admin_uid = v_uid),
         lm.text, lm.sender_name, lm.created_at,
         (SELECT COUNT(*) FROM public.group_messages gm2
           WHERE gm2.group_id = g.id AND gm2.created_at > m.last_read_at AND gm2.sender_uid <> v_uid),
         (SELECT COUNT(*) FROM public.group_members mm WHERE mm.group_id = g.id AND mm.status = 'member'),
         (m.status = 'pending')
  FROM public.chat_groups g
  JOIN public.group_members m ON m.group_id = g.id AND m.user_uid = v_uid
  LEFT JOIN LATERAL (
    SELECT gm.text, gm.sender_name, gm.created_at FROM public.group_messages gm
    WHERE gm.group_id = g.id ORDER BY gm.created_at DESC LIMIT 1
  ) lm ON true
  ORDER BY COALESCE(lm.created_at, g.created_at) DESC;
END; $$;

-- group members list
CREATE OR REPLACE FUNCTION public.group_member_list(p_group_id bigint)
RETURNS TABLE(user_uid text, user_name text, status text, is_admin boolean)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text; v_admin text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.group_members WHERE group_id = p_group_id AND user_uid = v_uid AND status = 'member') THEN
    RAISE EXCEPTION 'not a member';
  END IF;
  SELECT admin_uid INTO v_admin FROM public.chat_groups WHERE id = p_group_id;
  RETURN QUERY SELECT mm.user_uid, mm.user_name, mm.status, (mm.user_uid = v_admin)
  FROM public.group_members mm WHERE mm.group_id = p_group_id ORDER BY mm.created_at;
END; $$;

-- send to group
CREATE OR REPLACE FUNCTION public.send_group_message(p_group_id bigint, p_text text, p_voice_url text DEFAULT NULL, p_note_id bigint DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid text := auth.uid()::text;
  v_name text;
  v_last bigint;
  v_id bigint;
  v_now bigint := ((extract(epoch from now()) * 1000)::bigint);
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.group_members WHERE group_id = p_group_id AND user_uid = v_uid AND status = 'member') THEN
    RAISE EXCEPTION 'not a member';
  END IF;
  IF (p_text IS NULL OR p_text = '') AND (p_voice_url IS NULL OR p_voice_url = '') AND p_note_id IS NULL THEN RAISE EXCEPTION 'empty'; END IF;
  IF char_length(COALESCE(p_text,'')) > 500 THEN RAISE EXCEPTION 'bad length'; END IF;
  v_name := public.display_name(v_uid);
  SELECT max(created_at) INTO v_last FROM public.group_messages WHERE sender_uid = v_uid AND group_id = p_group_id;
  IF v_last IS NOT NULL AND v_now - v_last < 2000 THEN RAISE EXCEPTION 'slow down'; END IF;
  INSERT INTO public.group_messages(group_id, sender_uid, sender_name, text, voice_url, note_id, created_at)
  VALUES (p_group_id, v_uid, v_name, COALESCE(p_text,''), NULLIF(p_voice_url,''), p_note_id, v_now) RETURNING id INTO v_id;
  UPDATE public.group_members SET last_read_at = v_now WHERE group_id = p_group_id AND user_uid = v_uid;
  RETURN v_id;
END; $$;

CREATE OR REPLACE FUNCTION public.mark_group_read(p_group_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text;
BEGIN
  IF v_uid IS NULL THEN RETURN; END IF;
  UPDATE public.group_members SET last_read_at = ((extract(epoch from now()) * 1000)::bigint)
  WHERE group_id = p_group_id AND user_uid = v_uid;
END; $$;

-- admin removes a member (or member leaves)
CREATE OR REPLACE FUNCTION public.remove_group_member(p_group_id bigint, p_uid text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_uid text := auth.uid()::text; v_admin text;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'not authenticated'; END IF;
  SELECT admin_uid INTO v_admin FROM public.chat_groups WHERE id = p_group_id;
  IF v_admin IS NULL THEN RAISE EXCEPTION 'no group'; END IF;
  IF p_uid = v_admin THEN RAISE EXCEPTION 'cannot remove admin'; END IF;
  IF v_uid <> v_admin AND v_uid <> p_uid THEN RAISE EXCEPTION 'not allowed'; END IF;
  DELETE FROM public.group_members WHERE group_id = p_group_id AND user_uid = p_uid;
END; $$;

-- realtime for groups
DO $$ BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;
