-- TUM Notes Hub — feature pack migration (wishlist, referrals, views, notifications)

-- ---------- wishlist ----------
CREATE TABLE IF NOT EXISTS public.wishlist (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text NOT NULL,
  note_id bigint NOT NULL,
  created_at bigint NOT NULL DEFAULT ((extract(epoch from now()) * 1000))::bigint,
  UNIQUE(user_id, note_id)
);
ALTER TABLE public.wishlist ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS wishlist_all ON public.wishlist;
CREATE POLICY wishlist_all ON public.wishlist FOR ALL TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);
-- explicit GRANTs: Supabase no longer auto-grants table privileges to anon/authenticated on new tables
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wishlist TO authenticated;

-- ---------- notifications ----------
CREATE TABLE IF NOT EXISTS public.notifications (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id text NOT NULL,
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  link text NOT NULL DEFAULT '',
  is_read boolean NOT NULL DEFAULT false,
  created_at bigint NOT NULL DEFAULT ((extract(epoch from now()) * 1000))::bigint
);
ALTER TABLE public.notifications ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS notif_read ON public.notifications;
DROP POLICY IF EXISTS notif_insert ON public.notifications;
DROP POLICY IF EXISTS notif_update ON public.notifications;
CREATE POLICY notif_read ON public.notifications FOR SELECT TO authenticated
  USING (auth.uid()::text = user_id);
CREATE POLICY notif_insert ON public.notifications FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = user_id);
CREATE POLICY notif_update ON public.notifications FOR UPDATE TO authenticated
  USING (auth.uid()::text = user_id)
  WITH CHECK (auth.uid()::text = user_id);
-- explicit GRANTs: Supabase no longer auto-grants table privileges to anon/authenticated on new tables
GRANT SELECT, INSERT, UPDATE ON public.notifications TO authenticated;

-- ---------- users: referral columns ----------
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS referral_code text;
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS referred_by text;

-- backfill referral codes for existing users
UPDATE public.users
SET referral_code = 'TUM-' || upper(substr(md5(uid || 'tum'), 1, 6))
WHERE referral_code IS NULL;

-- ---------- notes: views ----------
ALTER TABLE public.notes ADD COLUMN IF NOT EXISTS views integer NOT NULL DEFAULT 0;

-- ---------- signup trigger: NO cash referral bonus anymore ----------
-- Referral program (2026-10-08): referrer earns 10% of the referred user's future
-- note sales (taken from the admin's 30% share: seller 70 / admin 20 / referrer 10).
-- Signup only records who referred whom; no Rs 20 is paid here.
CREATE OR REPLACE FUNCTION public.users_signup_defaults()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  ref_uid text;
  ref_code text;
BEGIN
  NEW.wallet := 20;
  NEW.total_earnings := 0;
  NEW.plan := 'free';
  NEW.note_limit := 25;
  NEW.plan_expires := 0;
  NEW.is_admin := false;
  NEW.role := 'user';
  NEW.admin_pass_hash := NULL;
  NEW.withdraw_pass_hash := NULL;
  NEW.referral_code := 'TUM-' || upper(substr(md5(NEW.uid || extract(epoch from now())::text), 1, 6));
  IF NEW.referred_by IS NOT NULL AND NEW.referred_by <> '' THEN
    SELECT u.uid, u.referral_code INTO ref_uid, ref_code
    FROM public.users u WHERE u.referral_code = NEW.referred_by LIMIT 1;
    IF ref_uid IS NOT NULL AND ref_uid <> NEW.uid THEN
      NEW.referred_by := ref_code; -- record only; 10% commission comes from their sales
    ELSE
      NEW.referred_by := NULL;
    END IF;
  END IF;
  RETURN NEW;
END; $$;

-- verification
SELECT tablename, policyname FROM pg_policies WHERE schemaname='public' AND tablename IN ('wishlist','notifications') ORDER BY 1,2;
SELECT count(*) AS users_with_code FROM public.users WHERE referral_code IS NOT NULL;
