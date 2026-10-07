-- Welcome bonus 30 -> 20 (targeted re-apply of the signup-defaults trigger).
-- Run in Supabase Dashboard > SQL Editor. Safe to re-run.
CREATE OR REPLACE FUNCTION public.users_signup_defaults()
RETURNS trigger LANGUAGE plpgsql AS $$
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
  RETURN NEW;
END; $$;
