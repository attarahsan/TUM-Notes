-- ============================================================
-- TUM Notes Hub — RLS hardening migration
-- Replaces permissive anon_all/authenticated_all (USING true) with
-- ownership-scoped policies. Money moves via Edge Functions (service_role).
-- ============================================================

-- ---------- helper: admin check (SECURITY DEFINER avoids recursion) ----------
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS boolean LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.users WHERE uid = auth.uid()::text AND is_admin = true);
$$;

-- ============================================================
-- USERS
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.users;
DROP POLICY IF EXISTS authenticated_all ON public.users;

CREATE POLICY users_read ON public.users FOR SELECT TO authenticated
  USING (auth.uid()::text = uid OR public.is_admin());

CREATE POLICY users_insert ON public.users FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = uid);

CREATE POLICY users_update ON public.users FOR UPDATE TO authenticated
  USING (auth.uid()::text = uid OR public.is_admin())
  WITH CHECK (auth.uid()::text = uid OR public.is_admin());

-- Force safe defaults on signup (client cannot grant itself money/admin)
CREATE OR REPLACE FUNCTION public.users_signup_defaults()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.wallet := 30;
  NEW.total_earnings := 0;
  NEW.plan := 'free';
  NEW.note_limit := 25;
  NEW.plan_expires := 0;
  NEW.is_admin := false;
  NEW.role := 'user';
  NEW.admin_pass_hash := NULL;
  NEW.withdraw_pass_hash := NULL;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS users_signup_defaults_trg ON public.users;
CREATE TRIGGER users_signup_defaults_trg
  BEFORE INSERT ON public.users FOR EACH ROW
  EXECUTE FUNCTION public.users_signup_defaults();

-- Block money-column changes except via service_role (Edge Functions).
-- Allows the legit expiry auto-downgrade pattern (plan->free/25/0 when expired).
CREATE OR REPLACE FUNCTION public.protect_user_money()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('service_role', 'postgres') THEN RETURN NEW; END IF;
  IF (OLD.wallet IS DISTINCT FROM NEW.wallet
      OR OLD.total_earnings IS DISTINCT FROM NEW.total_earnings
      OR OLD.plan IS DISTINCT FROM NEW.plan
      OR OLD.note_limit IS DISTINCT FROM NEW.note_limit
      OR OLD.plan_expires IS DISTINCT FROM NEW.plan_expires
      OR OLD.is_admin IS DISTINCT FROM NEW.is_admin) THEN
    -- allow only the expiry auto-downgrade (nothing else may change)
    IF NOT (
      OLD.plan_expires < (EXTRACT(EPOCH FROM NOW()) * 1000)::bigint
      AND NEW.plan = 'free' AND NEW.note_limit = 25 AND NEW.plan_expires = 0
      AND OLD.wallet IS NOT DISTINCT FROM NEW.wallet
      AND OLD.total_earnings IS NOT DISTINCT FROM NEW.total_earnings
      AND OLD.is_admin IS NOT DISTINCT FROM NEW.is_admin
    ) THEN
      RAISE EXCEPTION 'money fields are managed server-side';
    END IF;
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS protect_user_money_trg ON public.users;
CREATE TRIGGER protect_user_money_trg
  BEFORE UPDATE ON public.users FOR EACH ROW
  EXECUTE FUNCTION public.protect_user_money();

-- ============================================================
-- ORDERS (money decisions via approve-order Edge Function only)
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.orders;
DROP POLICY IF EXISTS authenticated_all ON public.orders;

CREATE POLICY orders_read ON public.orders FOR SELECT TO authenticated
  USING (auth.uid()::text = buyer_id OR auth.uid()::text = seller_id OR public.is_admin());

CREATE POLICY orders_insert ON public.orders FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = buyer_id AND status = 'pending');
-- NO update/delete for clients.

-- ============================================================
-- WITHDRAWALS (via request-withdrawal / decide-withdrawal functions only)
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.withdrawals;
DROP POLICY IF EXISTS authenticated_all ON public.withdrawals;

CREATE POLICY withdrawals_read ON public.withdrawals FOR SELECT TO authenticated
  USING (auth.uid()::text = seller_id OR public.is_admin());
-- NO insert/update/delete for clients.

-- ============================================================
-- SUBSCRIPTIONS (activate via activate-plan function only)
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.subscriptions;

CREATE POLICY subs_read ON public.subscriptions FOR SELECT TO authenticated
  USING (auth.uid()::text = seller_id OR public.is_admin());

CREATE POLICY subs_insert ON public.subscriptions FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = seller_id AND status = 'pending');
-- NO update/delete for clients.

-- ============================================================
-- NOTES (public marketplace reads; status changes admin-only)
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.notes;
DROP POLICY IF EXISTS authenticated_all ON public.notes;

CREATE POLICY notes_read ON public.notes FOR SELECT
  USING (status = 'approved' OR auth.uid()::text = seller_id OR public.is_admin());

CREATE POLICY notes_insert ON public.notes FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = seller_id AND status = 'pending');

CREATE POLICY notes_update ON public.notes FOR UPDATE TO authenticated
  USING (auth.uid()::text = seller_id OR public.is_admin())
  WITH CHECK (auth.uid()::text = seller_id OR public.is_admin());

CREATE POLICY notes_delete ON public.notes FOR DELETE TO authenticated
  USING (auth.uid()::text = seller_id OR public.is_admin());

-- Only admins (or service_role) may change note status
CREATE OR REPLACE FUNCTION public.protect_note_status()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('service_role', 'postgres') THEN RETURN NEW; END IF;
  IF (OLD.status IS DISTINCT FROM NEW.status) AND NOT public.is_admin() THEN
    RAISE EXCEPTION 'only admin can change note status';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS protect_note_status_trg ON public.notes;
CREATE TRIGGER protect_note_status_trg
  BEFORE UPDATE ON public.notes FOR EACH ROW
  EXECUTE FUNCTION public.protect_note_status();

-- ============================================================
-- REVIEWS (rating recalculated by trigger; client must not touch notes.rating)
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.reviews;
DROP POLICY IF EXISTS authenticated_all ON public.reviews;

CREATE POLICY reviews_read ON public.reviews FOR SELECT USING (true);

CREATE POLICY reviews_insert ON public.reviews FOR INSERT TO authenticated
  WITH CHECK (auth.uid()::text = user_id);

CREATE POLICY reviews_update ON public.reviews FOR UPDATE TO authenticated
  USING (auth.uid()::text = user_id OR public.is_admin())
  WITH CHECK (auth.uid()::text = user_id OR public.is_admin());

CREATE POLICY reviews_delete ON public.reviews FOR DELETE TO authenticated
  USING (auth.uid()::text = user_id OR public.is_admin());

CREATE OR REPLACE FUNCTION public.recalc_note_rating()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  avg_r numeric; cnt int; nid bigint;
BEGIN
  nid := COALESCE(NEW.note_id, OLD.note_id);
  SELECT AVG(stars), COUNT(*) INTO avg_r, cnt FROM public.reviews WHERE note_id = nid;
  UPDATE public.notes
    SET rating = COALESCE(ROUND(avg_r * 10) / 10, 0),
        review_count = COALESCE(cnt, 0)
    WHERE note_id = nid;
  RETURN COALESCE(NEW, OLD);
END; $$;
DROP TRIGGER IF EXISTS recalc_note_rating_trg ON public.reviews;
CREATE TRIGGER recalc_note_rating_trg
  AFTER INSERT OR UPDATE OR DELETE ON public.reviews FOR EACH ROW
  EXECUTE FUNCTION public.recalc_note_rating();

-- ============================================================
-- REPORTS (table exists; lock down: admin reads, users can file)
-- ============================================================
DROP POLICY IF EXISTS anon_all ON public.reports;
DROP POLICY IF EXISTS authenticated_all ON public.reports;

CREATE POLICY reports_insert ON public.reports FOR INSERT TO authenticated
  WITH CHECK (true);

CREATE POLICY reports_admin ON public.reports FOR ALL TO authenticated
  USING (public.is_admin())
  WITH CHECK (public.is_admin());

-- ============================================================
-- VERIFICATION
-- ============================================================
SELECT tablename, policyname, roles, cmd
FROM pg_policies
WHERE schemaname = 'public'
  AND tablename IN ('users','orders','withdrawals','subscriptions','notes','reviews','reports')
ORDER BY tablename, policyname;
