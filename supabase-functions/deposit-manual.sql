-- Manual deposit support: proof screenshot + method tracking
ALTER TABLE public.deposits ADD COLUMN IF NOT EXISTS payment_proof_url TEXT;
ALTER TABLE public.deposits ADD COLUMN IF NOT EXISTS method TEXT NOT NULL DEFAULT 'cashmaal' CHECK (method IN ('cashmaal','manual'));
ALTER TABLE public.deposits ADD COLUMN IF NOT EXISTS user_name TEXT;
ALTER TABLE public.deposits ADD COLUMN IF NOT EXISTS user_email TEXT;

-- allow 'rejected' status for manual deposits
ALTER TABLE public.deposits DROP CONSTRAINT IF EXISTS deposits_status_check;
ALTER TABLE public.deposits ADD CONSTRAINT deposits_status_check CHECK (status IN ('pending','completed','failed','rejected'));
