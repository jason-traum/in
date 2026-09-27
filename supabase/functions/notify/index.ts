// In. notifications. Called every minute by pg_cron (see notify_cron.sql). It sends what the database
// queued in public.outbox (RSVPs, chat, run changes, friend requests) and the scheduled reminders:
// 8 PM the night before a run, 9 PM to confirm a proposed run, and 30 minutes before a run.
// It only ever reads the database, so calling it by hand just sends whatever is due.
import { createClient } from "npm:@supabase/supabase-js@2";
import * as webpush from "jsr:@negrel/webpush@0.5.0";

const APP_URL = Deno.env.get("IN_APP_URL") ?? "https://jason-traum.github.io/in/";
const CONTACT = Deno.env.get("IN_CONTACT") ?? "mailto:jasontraum8@gmail.com";
const TZ = "America/New_York";
// Tests can pin the clock; in production this is just the current time.
const nowMs = () => Number(Deno.env.get("IN_TEST_NOW_MS")) || Date.now();
const db = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false } });

const SPOTS: Record<string, string> = {
  "grays-ferry": "Grays Ferry Crescent", christian: "Christian St", south: "South St Bridge", locust: "Locust St",
  walnut: "Walnut St Bridge", chestnut: "Chestnut St Bridge", market: "Market St", paines: "Paine's Park",
  "art-museum": "the Art Museum", boathouse: "Boathouse Row", girard: "Girard Ave Bridge",
  strawberry: "Strawberry Mansion Bridge", falls: "Falls Bridge", manayunk: "Manayunk",
};
type Run = { id: string; host: string | null; date: string; status: string; start: number; title: string; spot: string; place: string };
type Note = { title: string; body: string; url: string; tag: string };

// ----- time in Philadelphia -----
function nyParts(d = new Date(nowMs())) {
  const p = Object.fromEntries(new Intl.DateTimeFormat("en-CA", { timeZone: TZ, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" })
    .formatToParts(d).map((x) => [x.type, x.value]));
  return { date: `${p.year}-${p.month}-${p.day}`, min: Number(p.hour) * 60 + Number(p.minute) };
}
const addDays = (k: string, n: number) => { const d = new Date(k + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };
// The moment a run starts, as epoch ms (the date and minutes are Philadelphia time).
function startMs(r: Run) {
  const guess = Date.parse(r.date + "T00:00:00Z") + r.start * 60000;
  const p = nyParts(new Date(guess));
  const shown = Date.parse(p.date + "T00:00:00Z") + p.min * 60000;
  return guess + (guess - shown);
}
const clock = (m: number) => { const h = Math.floor(m / 60) % 24; return `${h % 12 || 12}:${String(m % 60).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`; };
function dayWord(k: string) {
  const today = nyParts().date;
  if (k === today) return "today";
  if (k === addDays(today, 1)) return "tomorrow";
  return new Date(k + "T12:00:00Z").toLocaleDateString("en-US", { weekday: "long", timeZone: "UTC" });
}
const where = (r: Run) => (r.place ? r.place.split(",")[0] : SPOTS[r.spot] ?? "the trail");
const when = (r: Run) => `${dayWord(r.date)} at ${clock(r.start)}`;
const runUrl = (r: Run) => `${APP_URL}?run=${encodeURIComponent(r.id)}`;

// ----- people -----
const names = new Map<string, string>();
async function nameOf(id: string | null) {
  if (!id) return "Someone";
  if (!names.has(id)) {
    const { data } = await db.from("profiles").select("handle").eq("id", id).maybeSingle();
    const w = String(data?.handle ?? "Someone").trim().split(/\s+/);
    names.set(id, w.length > 1 ? `${w[0]} ${w[w.length - 1][0]}.` : w[0]);
  }
  return names.get(id)!;
}
async function getRun(id: string | null): Promise<Run | null> {
  if (!id) return null;
  const { data } = await db.from("runs").select("id,host,date,status,start,title,spot,place").eq("id", id).maybeSingle();
  return data as Run | null;
}
async function joiners(runId: string, kinds: string[]) {
  const { data } = await db.from("joins").select("user_id,kind").eq("run_id", runId);
  return (data ?? []).filter((j) => kinds.includes(j.kind)).map((j) => j.user_id as string);
}
const isPast = (r: Run) => startMs(r) < nowMs() - 60 * 60000;

// ----- sending -----
let server: webpush.ApplicationServer | null = null;
async function appServer() {
  if (server) return server;
  let { data: row } = await db.from("push_keys").select("public,jwk").eq("id", 1).maybeSingle();
  if (!row) {
    const keys = await webpush.generateVapidKeys({ extractable: true });
    const made = { id: 1, public: await webpush.exportApplicationServerKey(keys), jwk: await webpush.exportVapidKeys(keys) };
    await db.from("push_keys").upsert(made, { onConflict: "id", ignoreDuplicates: true });
    ({ data: row } = await db.from("push_keys").select("public,jwk").eq("id", 1).maybeSingle());
  }
  const { data: cfg } = await db.from("app_config").select("vapid_public").eq("id", "app").maybeSingle();
  if (cfg && cfg.vapid_public !== row!.public) await db.from("app_config").update({ vapid_public: row!.public }).eq("id", "app");
  server = await webpush.ApplicationServer.new({ contactInformation: CONTACT, vapidKeys: await webpush.importVapidKeys(row!.jwk) });
  return server;
}
let sent = 0;
async function send(userIds: (string | null)[], note: Note) {
  const ids = [...new Set(userIds.filter(Boolean))] as string[];
  if (!ids.length) return;
  const { data: subs } = await db.from("push_subs").select("endpoint,p256dh,auth").in("user_id", ids);
  if (!subs?.length) return;
  const as = await appServer();
  const payload = JSON.stringify(note);
  await Promise.all(subs.map(async (s) => {
    try {
      await as.subscribe({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }).pushTextMessage(payload, { ttl: 6 * 3600, urgency: webpush.Urgency.High });
      sent++;
    } catch (e) {
      const status = (e as { response?: Response }).response?.status;
      if (status === 404 || status === 410) await db.from("push_subs").delete().eq("endpoint", s.endpoint);
      else console.error("push failed", status ?? String(e));
    }
  }));
}

// ----- things that happened -----
async function handle(ev: { kind: string; run_id: string | null; user_id: string | null; target: string | null; ref: string | null }) {
  const who = await nameOf(ev.user_id);
  if (ev.kind === "freq") return send([ev.target], { title: `${who} sent you a friend request`, body: "Open In. to accept.", url: `${APP_URL}?tab=friends`, tag: `friend-${ev.user_id}` });
  if (ev.kind === "faccept") return send([ev.target], { title: `${who} accepted your friend request`, body: "Their runs can show up on your board now.", url: `${APP_URL}?tab=friends`, tag: `friend-${ev.user_id}` });
  const r = await getRun(ev.run_id);
  if (!r || isPast(r)) return;
  if (ev.kind === "join") {
    if (r.status === "cancelled" || !r.host || r.host === ev.user_id) return;
    const going = ev.ref === "maybe" ? "is a maybe for" : r.status === "intention" ? "would be in for" : "is in for";
    return send([r.host], { title: `${who} ${going} ${r.title}`, body: `${when(r)} · ${where(r)}`, url: runUrl(r), tag: `join-${r.id}-${ev.user_id}` });
  }
  if (ev.kind === "msg") {
    if (r.status === "cancelled") return;
    const { data: m } = await db.from("messages").select("body").eq("id", ev.ref).maybeSingle();
    if (!m) return;
    const to = [r.host, ...(await joiners(r.id, ["in"]))].filter((id) => id !== ev.user_id);
    const body = m.body.length > 160 ? m.body.slice(0, 157) + "…" : m.body;
    return send(to, { title: `${who} · ${r.title}`, body, url: runUrl(r) + "&tab=chat", tag: `chat-${r.id}` });
  }
  const everyone = (await joiners(r.id, ["in", "maybe"])).filter((id) => id !== ev.user_id);
  if (ev.kind === "cancel") return send(everyone, { title: `${r.title} is cancelled`, body: `${who} cancelled the run ${when(r)}.`, url: runUrl(r), tag: `run-${r.id}` });
  if (ev.kind === "confirm") return send(everyone, { title: `${r.title} is confirmed`, body: `${when(r)} at ${where(r)}.`, url: runUrl(r), tag: `run-${r.id}` });
  if (ev.kind === "change") return send(everyone, { title: `${r.title} changed`, body: `Now ${when(r)} at ${where(r)}.`, url: runUrl(r), tag: `run-${r.id}` });
  if (ev.kind === "hostleft") return send(await joiners(r.id, ["in"]), { title: `${who} dropped out as host`, body: `${r.title} is still on. Open In. to take over.`, url: runUrl(r), tag: `run-${r.id}` });
}

// ----- reminders -----
async function reminders() {
  const now = nyParts(), tmr = addDays(now.date, 1);
  const { data } = await db.from("runs").select("id,host,date,status,start,title,spot,place").in("date", [now.date, tmr]).neq("status", "cancelled");
  const runs = (data ?? []) as Run[];
  const plan: { key: string; to: string; note: Note }[] = [];
  for (const r of runs) {
    if (!r.host && r.status !== "locked") continue;
    const inIds = r.status === "locked" ? [r.host, ...(await joiners(r.id, ["in"]))].filter(Boolean) as string[] : [];
    // 8 PM the night before (or as soon as a run is confirmed after that)
    if (r.date === tmr && r.status === "locked" && now.min >= 20 * 60) {
      for (const u of inIds) plan.push({ key: `eve:${r.id}:${u}`, to: u, note: { title: `Tomorrow: ${r.title} at ${clock(r.start)}`, body: `${where(r)}. Open In. for your leave-by time.`, url: runUrl(r), tag: `remind-${r.id}` } });
    }
    // 9 PM: confirm your proposed run by 10
    if (r.date === tmr && r.status === "intention" && r.host && now.min >= 21 * 60 && now.min < 22 * 60) {
      plan.push({ key: `conf:${r.id}`, to: r.host, note: { title: `Confirm ${r.title} by 10 PM`, body: "Proposed runs that aren't confirmed by 10 PM are dropped.", url: runUrl(r), tag: `remind-${r.id}` } });
    }
    // 30 minutes before
    const left = startMs(r) - nowMs();
    if (r.status === "locked" && left > 0 && left <= 31 * 60000) {
      for (const u of inIds) plan.push({ key: `soon:${r.id}:${u}`, to: u, note: { title: `${r.title} starts at ${clock(r.start)}`, body: `${where(r)}. See you there.`, url: runUrl(r), tag: `remind-${r.id}` } });
    }
  }
  if (!plan.length) return;
  const { data: fresh } = await db.rpc("claim_keys", { p_keys: plan.map((p) => p.key) });
  const ok = new Set((fresh ?? []) as string[]);
  for (const p of plan) if (ok.has(p.key)) await send([p.to], p.note);
}

Deno.serve(async () => {
  sent = 0;
  try {
    await appServer();
    const { data: events, error } = await db.rpc("claim_outbox");
    if (error) throw error;
    for (const ev of events ?? []) { try { await handle(ev); } catch (e) { console.error("event", ev.id, e); } }
    await reminders();
    return Response.json({ ok: true, events: events?.length ?? 0, sent });
  } catch (e) {
    console.error(e);
    return Response.json({ ok: false, error: String(e) }, { status: 500 });
  }
});
