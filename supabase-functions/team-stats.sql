-- ============================================================
-- team-stats.sql — referral dashboard RPC
-- Run once in the Supabase SQL Editor (project: tum-notes-hub).
-- Returns the signed-in user's referral count, lifetime referral
-- earnings, approved team-driven sales, and their team member list.
-- SECURITY DEFINER so a referrer can see ONLY their own team
-- (users/orders RLS otherwise hides other users' rows).
-- ============================================================

CREATE OR REPLACE FUNCTION public.my_team_stats()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  me_uid  text;
  my_code text;
  out     jsonb;
BEGIN
  me_uid := auth.uid()::text;
  IF me_uid IS NULL THEN
    RAISE EXCEPTION 'not signed in';
  END IF;

  SELECT referral_code INTO my_code
  FROM public.users
  WHERE uid = me_uid;

  IF my_code IS NULL THEN
    RETURN jsonb_build_object(
      'count', 0, 'earnings', 0, 'sales', 0, 'team', '[]'::jsonb
    );
  END IF;

  SELECT jsonb_build_object(
    'count',
      (SELECT count(*) FROM public.users WHERE referred_by = my_code),
    'earnings',
      COALESCE((SELECT sum(referrer_cut)
                FROM public.orders
                WHERE referrer_uid = me_uid AND status = 'approved'), 0),
    'sales',
      (SELECT count(*)
       FROM public.orders
       WHERE referrer_uid = me_uid AND status = 'approved'),
    'team',
      COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object(
            'name',   u.name,
            'joined', u.created_at,
            'sales',  COALESCE(s.cnt, 0)
          )
          ORDER BY u.created_at DESC
        )
        FROM public.users u
        LEFT JOIN (
          SELECT seller_id, count(*) AS cnt
          FROM public.orders
          WHERE status = 'approved'
          GROUP BY seller_id
        ) s ON s.seller_id = u.uid
        WHERE u.referred_by = my_code
      ), '[]'::jsonb)
  ) INTO out;

  RETURN out;
END;
$$;

GRANT EXECUTE ON FUNCTION public.my_team_stats() TO authenticated;
