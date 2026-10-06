# Notes Hub — Privacy-Friendly Visitor Counter (READY TO APPLY, not applied)
**Why:** user asked "website pr kitny visitors aye Hain" (2026-10-05 ~14:08 PKT). No analytics exist on the site. Assistant offered a simple counter; user hasn't answered yet. This patch makes that offer one decision: say "lagaaun" and it ships.
**Privacy:** counts visits only — NO name, email, IP, or device stored. Just timestamp + page path.

## Step 1 — SQL (run once in Supabase Dashboard → SQL Editor)

```sql
create table if not exists page_views (
  id uuid primary key default gen_random_uuid(),
  page text not null default '/',
  viewed_at timestamptz not null default now()
);

alter table page_views enable row level security;

-- anyone (even logged-out) may LOG a visit; nobody may read/update/delete via client
create policy page_views_anon_insert on page_views
  for insert to anon with check (true);

-- explicit GRANT: Supabase no longer auto-grants table privileges to anon on new tables
grant insert on page_views to anon;

-- admin reads counts from the dashboard Table Editor / SQL Editor directly
```

## Step 2 — index.html snippet (paste right after the `supabase.createClient(...)` line)

```js
// Simple visit counter: one row per browser session, no personal data.
try {
  if (!sessionStorage.getItem('tum_visit')) {
    sessionStorage.setItem('tum_visit', '1');
    supabase.from('page_views').insert({ page: location.pathname || '/' }).then(()=>{}, ()=>{});
  }
} catch (e) { /* counter must never break the site */ }
```

## Step 3 — Admin: daily counts (Supabase → SQL Editor)

```sql
select date(viewed_at) as day, count(*) as visits
from page_views
group by 1 order by 1 desc;
```

## Honest caveats (tell the user)
- Counts **visits**, not unique humans (same person, new tab session = 1; new browser = +1).
- Bots/crawlers inflate it slightly; ad-blockers may block the insert.
- Good enough for "roz kitne log aaye" — not for per-user identity (that was never asked for).
- Deploy path: edit `index.html` → push to GitHub → Netlify auto-deploys (same as all site updates).

## Apply checklist (for delivery, after user says yes)
1. Run the SQL in Supabase dashboard.
2. Patch `~/workspace/tum-notes-website/index.html`, commit + push.
3. Verify: open site in incognito, check one new row appears in `page_views`.
