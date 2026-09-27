-- In. database setup for Supabase.
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run again later: it only adds what is missing and refreshes the rules.
--
-- BEFORE RUNNING: put the email you will sign in with on the line below (inside the quotes).
-- That account can turn the sample classmates on and off for everyone.
-- You can add more admins later by running the same insert with another email.

create table if not exists public.admins (email text primary key);
insert into public.admins (email) values (lower('YOUR_EMAIL_HERE')) on conflict do nothing;

-- ---------------------------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------------------------

-- Everyone's runner card. Readable by every signed-in person (it's how friends find each other).
create table if not exists public.profiles (
  id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  handle text not null check (char_length(btrim(handle)) between 1 and 40),
  spot text not null check (char_length(spot) between 1 and 40),
  pace smallint not null check (pace between 240 and 960),
  travel text not null default 'walk' check (travel in ('jog', 'walk')),
  vis text not null default 'fof' check (vis in ('friends', 'fof', 'wharton')),
  updated_at timestamptz not null default now()
);

-- Names are first and last (older cards allowed 24 characters).
alter table public.profiles alter column travel set default 'walk';
alter table public.profiles drop constraint if exists profiles_handle_check;
alter table public.profiles add constraint profiles_handle_check check (char_length(btrim(handle)) between 1 and 40);

-- Where you live, roughly (nearest corner or door-to-trail miles). Private: only you can read it.
create table if not exists public.homes (
  id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  st smallint check (st between 1 and 99),
  cross_street text check (char_length(cross_street) <= 40),
  dist numeric(3, 1) check (dist between 0 and 5),
  updated_at timestamptz not null default now()
);

-- One row per pair of people, with the smaller id first.
create table if not exists public.friendships (
  a uuid not null references auth.users (id) on delete cascade,
  b uuid not null references auth.users (id) on delete cascade,
  from_id uuid not null,
  to_id uuid not null,
  status text not null check (status in ('pending', 'accepted', 'declined', 'removed')),
  at timestamptz not null default now(),
  primary key (a, b),
  check (a < b),
  check (from_id in (a, b) and to_id in (a, b) and from_id <> to_id)
);

create table if not exists public.runs (
  id text primary key default gen_random_uuid()::text check (char_length(id) between 8 and 64),
  host uuid default auth.uid() references auth.users (id) on delete cascade,
  date date not null,
  status text not null check (status in ('intention', 'locked', 'cancelled')),
  start smallint not null check (start between 0 and 1439),
  title text not null default '' check (char_length(title) <= 48),
  spot text not null check (char_length(spot) between 1 and 40),
  place text not null default '' check (char_length(place) <= 60),
  place_off numeric(3, 1) not null default 0 check (place_off between 0 and 5),
  place_id text not null default '' check (char_length(place_id) <= 40),
  finish text not null default '' check (char_length(finish) <= 60),
  finish_spot text not null default '' check (char_length(finish_spot) <= 40),
  finish_off numeric(3, 1) not null default 0 check (finish_off between 0 and 5),
  finish_id text not null default '' check (char_length(finish_id) <= 48),
  pace smallint not null check (pace between 240 and 960),
  dist numeric(4, 1) not null check (dist > 0 and dist <= 50),
  vis text not null check (vis in ('friends', 'fof', 'wharton')),
  note text not null default '' check (char_length(note) <= 90),
  samples_in text[] not null default '{}',
  created_at timestamptz not null default now(),
  locked_at timestamptz,
  touched_at timestamptz,
  left_by uuid references auth.users (id) on delete set null,
  left_at timestamptz
);
alter table public.runs add column if not exists touched_at timestamptz;
-- A host can drop out: the run then has no host (host is null) and remembers who left (left_by).
alter table public.runs alter column host drop not null;
alter table public.runs add column if not exists left_by uuid references auth.users (id) on delete set null;
alter table public.runs add column if not exists left_at timestamptz;
create index if not exists runs_date_idx on public.runs (date);

create table if not exists public.joins (
  run_id text not null references public.runs (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  date date not null,
  at timestamptz not null default now(),
  kind text not null default 'in' check (kind in ('in', 'maybe')),
  primary key (run_id, user_id)
);
-- "I'm in" or "Maybe".
alter table public.joins add column if not exists kind text not null default 'in';
alter table public.joins drop constraint if exists joins_kind_check;
alter table public.joins add constraint joins_kind_check check (kind in ('in', 'maybe'));
create index if not exists joins_date_idx on public.joins (date);

-- Chat on each run. Anyone who can see the run can read and post.
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  run_id text not null references public.runs (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  at timestamptz not null default now()
);
create index if not exists messages_run_idx on public.messages (run_id, at);

-- One row of app-wide settings.
create table if not exists public.app_config (
  id text primary key default 'app' check (id = 'app'),
  samples boolean not null default true,
  updated_at timestamptz not null default now()
);
insert into public.app_config (id) values ('app') on conflict do nothing;

-- ---------------------------------------------------------------------------------------------
-- Helpers the rules use. They run with the owner's rights so the rules can look across tables
-- without looping back on themselves. Anyone signed in can also call them directly, so each one
-- only answers questions about the person asking (auth.uid()) and says no to everything else.
-- ---------------------------------------------------------------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from admins where email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;

create or replace function public.are_friends(x uuid, y uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() in (x, y) and exists (
    select 1 from friendships f
    where f.status = 'accepted' and f.a = least(x, y) and f.b = greatest(x, y)
  );
$$;

create or replace function public.share_a_friend(x uuid, y uuid) returns boolean
language sql stable security definer set search_path = public as $$
  with fx as (
    select case when a = x then b else a end as f from friendships where status = 'accepted' and (a = x or b = x)
  ), fy as (
    select case when a = y then b else a end as f from friendships where status = 'accepted' and (a = y or b = y)
  )
  select auth.uid() in (x, y) and exists (select 1 from fx join fy using (f));
$$;

-- Who can see a run: its host, anyone going, everyone for All Wharton runs, the host's friends,
-- and for friends-of-friends runs anyone who shares a friend with the host.
-- It works from the run's own columns, so it also answers for a run that is being posted right now.
create or replace function public.can_see_run(p_host uuid, p_vis text, p_run text, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user = auth.uid() and (
    p_host = p_user
    or p_vis = 'wharton'
    or are_friends(p_host, p_user)
    or (p_vis = 'fof' and share_a_friend(p_host, p_user))
    or exists (select 1 from joins j where j.run_id = p_run and j.user_id = p_user)
  );
$$;

-- The same question for a run that already exists, by id (the rules for joins and chat use this).
-- A run whose host dropped out keeps the audience it had: friends of the person who hosted it.
create or replace function public.run_visible(p_run text, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select p_user = auth.uid() and exists (select 1 from runs r where r.id = p_run and can_see_run(coalesce(r.host, r.left_by), r.vis, r.id, p_user));
$$;

-- Friend requests move one way: only the person asked can accept or decline.
create or replace function public.friendship_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then return new; end if;  -- the SQL editor and service role can fix anything
  if tg_op = 'UPDATE' and (new.a <> old.a or new.b <> old.b) then
    raise exception 'friendship pair cannot change';
  end if;
  if new.status = 'pending' and new.from_id <> me then
    raise exception 'only the person asking can send a request';
  end if;
  if new.status = 'accepted' then
    if tg_op = 'INSERT' then raise exception 'a request has to be accepted by the other person'; end if;
    if old.status <> 'accepted' and not (old.status = 'pending' and old.to_id = me) then
      raise exception 'only the person asked can accept';
    end if;
  end if;
  if new.status = 'declined' and tg_op = 'UPDATE' and old.to_id <> me then
    raise exception 'only the person asked can decline';
  end if;
  return new;
end $$;

drop trigger if exists friendship_guard on public.friendships;
create trigger friendship_guard before insert or update on public.friendships
  for each row execute function public.friendship_guard();

-- Hosts own their runs: the host only changes through step_down and take_over below.
create or replace function public.run_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.host is distinct from old.host
     and coalesce(current_setting('in.host_change', true), '') <> 'on' then
    raise exception 'the host cannot change';
  end if;
  return new;
end $$;

drop trigger if exists run_guard on public.runs;
create trigger run_guard before update on public.runs for each row execute function public.run_guard();

-- The host drops out. The run stays up with no host, and remembers who left.
create or replace function public.step_down(p_run text) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform set_config('in.host_change', 'on', true);
  update runs set left_by = host, left_at = now(), host = null
    where id = p_run and host = auth.uid() and status <> 'cancelled';
  if not found then raise exception 'only the host can drop out as host' using errcode = '42501'; end if;
end $$;

-- Anyone who can see a run with no host can take it over. They stop being a joiner and become the host.
create or replace function public.take_over(p_run text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'sign in first' using errcode = '42501'; end if;
  perform set_config('in.host_change', 'on', true);
  update runs r set host = auth.uid()
    where r.id = p_run and r.host is null and r.status <> 'cancelled'
      and can_see_run(r.left_by, r.vis, r.id, auth.uid());
  if not found then raise exception 'this run already has a host' using errcode = '42501'; end if;
  delete from joins where run_id = p_run and user_id = auth.uid();
end $$;

-- When someone joins or drops out, touch the run so everyone who can see it gets a live update.
-- Joins themselves aren't broadcast: Supabase sends deletes to every listener, and who left which run is private.
create or replace function public.touch_run() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update runs set touched_at = now() where id = new.run_id;
  elsif tg_op = 'DELETE' then
    update runs set touched_at = now() where id = old.run_id;
  else
    update runs set touched_at = now() where id in (old.run_id, new.run_id);
  end if;
  return null;
end $$;

drop trigger if exists touch_run on public.joins;
create trigger touch_run after insert or update or delete on public.joins
  for each row execute function public.touch_run();

-- ---------------------------------------------------------------------------------------------
-- Access rules (row level security). Signed-out visitors see nothing.
-- ---------------------------------------------------------------------------------------------

alter table public.admins enable row level security;
alter table public.profiles enable row level security;
alter table public.homes enable row level security;
alter table public.friendships enable row level security;
alter table public.runs enable row level security;
alter table public.joins enable row level security;
alter table public.app_config enable row level security;
alter table public.messages enable row level security;

-- Start from nothing (Supabase's defaults grant everything, including TRUNCATE, which skips these rules),
-- then allow exactly what the app uses.
grant usage on schema public to authenticated;
revoke all on public.admins, public.profiles, public.homes, public.friendships, public.runs, public.joins, public.app_config, public.messages from anon, authenticated;
grant select, insert, update, delete on public.profiles, public.homes, public.friendships, public.runs, public.joins to authenticated;
grant select, update on public.app_config to authenticated;
grant select, insert, delete on public.messages to authenticated;
revoke execute on function public.is_admin(), public.are_friends(uuid, uuid), public.share_a_friend(uuid, uuid), public.can_see_run(uuid, text, text, uuid), public.run_visible(text, uuid), public.step_down(text), public.take_over(text) from public, anon;
grant execute on function public.is_admin(), public.are_friends(uuid, uuid), public.share_a_friend(uuid, uuid), public.can_see_run(uuid, text, text, uuid), public.run_visible(text, uuid), public.step_down(text), public.take_over(text) to authenticated;

drop policy if exists profiles_read on public.profiles;
drop policy if exists profiles_insert on public.profiles;
drop policy if exists profiles_update on public.profiles;
drop policy if exists profiles_delete on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (true);
create policy profiles_insert on public.profiles for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
create policy profiles_delete on public.profiles for delete to authenticated using (id = auth.uid());

drop policy if exists homes_own on public.homes;
create policy homes_own on public.homes for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists friendships_read on public.friendships;
drop policy if exists friendships_insert on public.friendships;
drop policy if exists friendships_update on public.friendships;
drop policy if exists friendships_delete on public.friendships;
-- Accepted friendships are visible to everyone (that's how friends of friends work);
-- pending, declined and removed ones only to the two people involved.
create policy friendships_read on public.friendships for select to authenticated
  using (status = 'accepted' or auth.uid() in (a, b));
create policy friendships_insert on public.friendships for insert to authenticated
  with check (auth.uid() in (a, b));
create policy friendships_update on public.friendships for update to authenticated
  using (auth.uid() in (a, b)) with check (auth.uid() in (a, b));
create policy friendships_delete on public.friendships for delete to authenticated
  using (auth.uid() in (a, b));

drop policy if exists runs_read on public.runs;
drop policy if exists runs_insert on public.runs;
drop policy if exists runs_update on public.runs;
drop policy if exists runs_delete on public.runs;
create policy runs_read on public.runs for select to authenticated using (public.can_see_run(coalesce(host, left_by), vis, id, auth.uid()));
create policy runs_insert on public.runs for insert to authenticated with check (host = auth.uid());
create policy runs_update on public.runs for update to authenticated using (host = auth.uid()) with check (host = auth.uid());
create policy runs_delete on public.runs for delete to authenticated using (host = auth.uid());

drop policy if exists joins_read on public.joins;
drop policy if exists joins_insert on public.joins;
drop policy if exists joins_update on public.joins;
drop policy if exists joins_delete on public.joins;
create policy joins_read on public.joins for select to authenticated using (public.run_visible(run_id, auth.uid()));
create policy joins_insert on public.joins for insert to authenticated
  with check (user_id = auth.uid() and public.run_visible(run_id, auth.uid()));
create policy joins_update on public.joins for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid() and public.run_visible(run_id, auth.uid()));
create policy joins_delete on public.joins for delete to authenticated using (user_id = auth.uid());

drop policy if exists messages_read on public.messages;
drop policy if exists messages_insert on public.messages;
drop policy if exists messages_delete on public.messages;
create policy messages_read on public.messages for select to authenticated using (public.run_visible(run_id, auth.uid()));
create policy messages_insert on public.messages for insert to authenticated
  with check (user_id = auth.uid() and public.run_visible(run_id, auth.uid()));
create policy messages_delete on public.messages for delete to authenticated using (user_id = auth.uid());

drop policy if exists config_read on public.app_config;
drop policy if exists config_update on public.app_config;
create policy config_read on public.app_config for select to authenticated using (true);
create policy config_update on public.app_config for update to authenticated using (public.is_admin()) with check (public.is_admin());

-- ---------------------------------------------------------------------------------------------
-- Live updates: tell Supabase Realtime to broadcast changes to these tables. Joins are left out
-- on purpose (see touch_run above), and the app never deletes friend requests, it marks them removed.
-- ---------------------------------------------------------------------------------------------

do $$
declare t text;
begin
  foreach t in array array['profiles', 'friendships', 'runs', 'app_config', 'messages'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when duplicate_object then null;  -- already added
    end;
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------
-- Optional: only let certain email domains sign up. Uncomment, set the domain, and run.
-- ---------------------------------------------------------------------------------------------
-- create or replace function public.only_allowed_emails() returns trigger
-- language plpgsql security definer set search_path = public as $$
-- begin
--   if lower(new.email) not like '%@wharton.upenn.edu' then
--     raise exception 'Sign-ups are limited to Wharton email addresses';
--   end if;
--   return new;
-- end $$;
-- drop trigger if exists only_allowed_emails on auth.users;
-- create trigger only_allowed_emails before insert on auth.users
--   for each row execute function public.only_allowed_emails();
