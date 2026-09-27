-- Run once in Supabase > SQL Editor after deploying the notify edge function (supabase/functions/notify).
-- It calls the function every minute; the function sends whatever is due and does nothing otherwise.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;
select cron.unschedule(jobid) from cron.job where jobname = 'in-notify';
select cron.schedule('in-notify', '* * * * *', $$
  select net.http_post(
    url := 'https://diewnsccktlwnatpwwzx.supabase.co/functions/v1/notify',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb,
    timeout_milliseconds := 20000
  )
$$);
