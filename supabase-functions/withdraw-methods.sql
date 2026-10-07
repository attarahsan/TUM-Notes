-- Withdraw method support (Easypaisa / JazzCash / Meezan Bank / HBL / UBL)
-- Run ONCE in Supabase Dashboard > SQL Editor BEFORE redeploying the
-- request-withdrawal Edge Function. Safe to run: ADD COLUMN IF NOT EXISTS.
ALTER TABLE public.withdrawals ADD COLUMN IF NOT EXISTS method text;
ALTER TABLE public.withdrawals ADD COLUMN IF NOT EXISTS account_title text;
ALTER TABLE public.withdrawals ADD COLUMN IF NOT EXISTS account_number text;
