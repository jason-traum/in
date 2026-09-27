# In.

Plan tomorrow's run with friends on the Schuylkill River Trail. See who's going, say I'm in, and get a leave-by time from your door.

Live at **https://jason-traum.github.io/in/**

## How it's put together

- `index.html` is the whole app (Preact, no build step).
- `config.js` points it at the Supabase project. The publishable key in it is meant to be public.
- `supabase.sql` is the database: tables, privacy rules, and live-update settings. Paste it into Supabase > SQL Editor and run it (put the admin email on line 10 first). It's safe to rerun after changes.
- GitHub Pages serves this repo's `main` branch, so pushing a change updates the site in a minute or two.

## What's private

- Your nearest corner is readable only by you.
- Runner cards (name, trail spot, pace) and who's friends with whom are visible to signed-in people, since that's how Friends of friends works. Emails aren't shown.
- Runs follow their setting (Friends, Friends of friends, All Wharton), and people who joined a run can always see it.
- Signed-out visitors see only the sign-in screen.
