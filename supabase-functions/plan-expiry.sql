-- Per-subscription 30-day expiry (stacked plans)
-- Run ONCE in Supabase Dashboard > SQL Editor. Safe to re-run.
-- Har plan apni activation date se 30 din chalega; naye plan se purana khatam nahi hoga.
ALTER TABLE public.subscriptions ADD COLUMN IF NOT EXISTS expires_at bigint;
-- backfill: pehle se approved subscriptions ke liye request date + 30 din (andaaza)
UPDATE public.subscriptions
SET expires_at = timestamp + 2592000000
WHERE status = 'approved' AND expires_at IS NULL;
