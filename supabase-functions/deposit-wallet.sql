-- Deposit wallet split: deposited money (buyable) vs earned money (withdraw-only)
-- Run in Supabase SQL editor.

-- 1. Deposit balance on users
ALTER TABLE public.users ADD COLUMN IF NOT EXISTS deposit_balance NUMERIC NOT NULL DEFAULT 0;

-- 2. Deposits ledger (CashMaal top-ups)
CREATE TABLE IF NOT EXISTS public.deposits (
  deposit_id        BIGSERIAL PRIMARY KEY,
  user_id           TEXT NOT NULL,
  amount            NUMERIC NOT NULL CHECK (amount > 0),
  status            TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','completed','failed')),
  cashmaal_txn_id   TEXT,
  cashmaal_order_id TEXT,
  created_at        BIGINT NOT NULL DEFAULT (EXTRACT(EPOCH FROM NOW())::BIGINT * 1000),
  completed_at      BIGINT
);
CREATE INDEX IF NOT EXISTS deposits_user_idx ON public.deposits (user_id);
CREATE INDEX IF NOT EXISTS deposits_status_idx ON public.deposits (status);

-- 3. RLS: users see only their own deposits; inserts only via service_role (webhook)
ALTER TABLE public.deposits ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS deposits_read_own ON public.deposits;
CREATE POLICY deposits_read_own ON public.deposits FOR SELECT TO authenticated
  USING (auth.uid()::text = user_id OR public.is_admin());
-- No INSERT/UPDATE/DELETE policies for clients: only service_role (Edge Functions) writes.

-- 4. Guard: deposit_balance can only be changed by service_role, never by clients
CREATE OR REPLACE FUNCTION public.protect_balances()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF current_user IN ('service_role', 'postgres') THEN RETURN NEW; END IF;
  IF (OLD.wallet IS DISTINCT FROM NEW.wallet) OR
     (OLD.deposit_balance IS DISTINCT FROM NEW.deposit_balance) OR
     (OLD.total_earnings IS DISTINCT FROM NEW.total_earnings) THEN
    RAISE EXCEPTION 'balances are server-managed';
  END IF;
  RETURN NEW;
END; $$;
DROP TRIGGER IF EXISTS protect_balances_trg ON public.users;
CREATE TRIGGER protect_balances_trg
  BEFORE UPDATE ON public.users FOR EACH ROW
  EXECUTE FUNCTION public.protect_balances();
