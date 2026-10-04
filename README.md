# TUM Notes Hub — Website

Public website for the TUM Notes Hub study-notes marketplace (Times University Multan).
Single-file static site (`index.html`) connected live to Supabase.

## Run locally
Just open `index.html` in a browser, or serve it:
```
python3 -m http.server 8000
```
then open http://localhost:8000

## Deploy (free)
- **Netlify:** drag & drop the folder at app.netlify.com/drop → then add your custom domain
- **Vercel:** `vercel` in this folder
- Any static host works (GitHub Pages, Cloudflare Pages, …)

## Features
- Home with search + featured notes
- Browse with filters (Free/Paid, department, subject, semester, max price) + sorting
- Note detail with star ratings, reviews, review form
- Sell form (submissions go to admin as `pending`)
- Admin panel (`Admin` in nav): email+password login for `is_admin` users,
  pending approvals, reported notes, all-notes management

## Backend
Supabase project `tum-notes-hub` (anon key embedded is the publishable key —
safe for client-side use; data access is governed by the table RLS policies).
