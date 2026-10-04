# TUM Notes Hub — Website

Professional, realtime student marketplace for study notes (Times University Multan).
Single-file static site (`index.html`) connected live to Supabase, with Supabase
Realtime subscriptions — new notes, approvals and reviews appear instantly with
toast notifications and a "Live" indicator in the header.

## Deploy on Netlify (free)

**Option A — drag & drop (fastest, no GitHub needed):**
1. Go to https://app.netlify.com/drop
2. Drag this whole folder onto the page
3. Done — you get a live URL like `https://tum-notes-hub.netlify.app`
4. Change the site name: Site settings → Change site name

**Option B — from GitHub (auto-deploys on every push):**
1. Netlify → Add new site → Import an existing project → GitHub
2. Select the `TUM-Notes` repository
3. Build settings: no build command, publish directory `.` (already in `netlify.toml`)
4. Deploy — every `git push` redeploys automatically

**Custom domain:** Site settings → Domain management → Add custom domain,
then point your domain's DNS to Netlify (they show the exact records).

## Enable Realtime in Supabase (one-time)
In Supabase dashboard → SQL Editor, run:
```sql
ALTER PUBLICATION supabase_realtime ADD TABLE public.notes, public.reviews;
```

## Features
- Home: live stats, search, departments, top-rated + fresh uploads
- Browse: Free/Paid, department, subject, semester, max-price filters + 4 sort orders (saved)
- Note detail: ratings, downloads, reviews, review form, file link
- Sell: submissions go to admin as `pending`
- Admin panel: email+password login for `is_admin` users; Pending / Reported / All tabs

## Run locally
```
python3 -m http.server 8000
```
→ http://localhost:8000
