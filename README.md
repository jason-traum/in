# In.

Plan tomorrow's run with friends, on the Schuylkill River Trail or anywhere in Philly. See who's going, say I'm in, and get a leave-by time from your door.

Live at **https://jason-traum.github.io/in/**

## How it's put together

- `index.html` is the whole app (Preact, no build step).
- `config.js` points it at the Supabase project. The publishable key in it is meant to be public.
- `supabase.sql` is the database: tables, privacy rules, and live-update settings. Paste it into Supabase > SQL Editor and run it (put the admin email on line 10 first). It's safe to rerun after changes.
- GitHub Pages serves this repo's `main` branch, so pushing a change updates the site in a minute or two.
- `sw.js` shows notifications. `supabase/functions/notify` is the Supabase edge function that sends them (deploy it with JWT verification off), and `notify_cron.sql` runs it every minute.

## What's private

- Where you live is readable only by you. It's your phone's location rounded to about a block (if you tap Use my location), or the corner you picked.
- Runner cards (name, trail spot, pace) and who's friends with whom are visible to signed-in people, since that's how Friends of friends works. Emails aren't shown.
- Runs follow their setting (Friends, Friends of friends, All Wharton), and people who joined a run (or said maybe) can always see it.
- A run's chat is visible to everyone who can see that run.
- Signed-out visitors see only the sign-in screen.

## Notifications

People turn them on from the card on the Runs tab or the switch on their runner card. On iPhone that only works from the Home Screen app. They get one when someone joins or messages about their run, when a run they're in changes, is confirmed or cancelled, or loses its host, when someone sends or accepts a friend request, at 8 PM the night before a run, at 9 PM to confirm a proposed run, and 30 minutes before a run.

## Beta

- Up to three famous names (Ben Franklin, Jalen Hurts, LeBron James, Will Smith, and friends) say they're in on All Wharton runs, shown with their full names. They're always marked Bot, never post runs, never count as people, and switch off by themselves once 20 people have runner cards. The admin can switch them off sooner from the runner card.
- On a phone, tap I'm in or Maybe on any run. Once you've answered, tap your answer to switch it, and tap Chat to talk it over.
- If a host drops out, the run stays up with a note, and anyone who can see it can take over as host.
- Leave and home times assume you walk to and from runs at 20:00/mi, unless your runner card says you jog. Past 2.5 miles (Valley Green, FDR Park) they count a ride instead.
- Distances count city blocks on the street grid and miles along the trail. Street positions come from the US Census geocoder.
- Runs can start on the trail, at a spot in the neighborhood, at a park or another trail (Penn Park, Clark Park, the Delaware River Trail, the Wissahickon), or anywhere the host pins.
