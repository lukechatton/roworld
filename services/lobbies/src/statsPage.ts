// GET /stats: a self-contained page (no external files) fed by /stats/events (or /stats.json).
// On top: everyone online right now as one big number, split by what they are doing (2026-10-05: the
// total player count, shown clearly). Under it: players per public match (docs/lobby-service.md "Stats").
// Since 2026-10-11 the page has no "goal of 50 humans" line and calls everyone "players", not
// "humans".
export const STATS_PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Rofront live</title>
<style>
:root { --bg: #0e1116; --panel: #161b22; --line: #262d36; --text: #e6edf3; --dim: #8b949e; --accent: #f5a524; --good: #3fb950; --bar: #388bfd; --max: #a371f7; }
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 14px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1040px; margin: 0 auto; padding: 24px 16px 48px; }
h1 { font-size: 20px; margin: 0 0 4px; }
.sub { color: var(--dim); margin: 0 0 20px; }
.cards { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-bottom: 16px; }
.card, .panel { background: var(--panel); border: 1px solid var(--line); border-radius: 10px; padding: 14px 16px; }
.card .k { color: var(--dim); font-size: 12px; text-transform: uppercase; letter-spacing: .06em; }
.card .v { font-size: 28px; font-weight: 700; margin-top: 2px; font-variant-numeric: tabular-nums; }
.card .n { color: var(--dim); font-size: 12px; }
.panel { margin-bottom: 16px; }
.panel h2 { font-size: 14px; margin: 0 0 10px; }
.hero { background: var(--panel); border: 1px solid var(--line); border-radius: 12px; padding: 18px 20px 16px; margin-bottom: 12px; }
.hero .k { color: var(--dim); font-size: 13px; text-transform: uppercase; letter-spacing: .08em; }
.hero .total { font-size: clamp(56px, 13vw, 96px); line-height: 1.02; font-weight: 800; font-variant-numeric: tabular-nums; letter-spacing: -.02em; }
.hero .total small { font-size: 18px; font-weight: 600; color: var(--dim); letter-spacing: 0; margin-left: 10px; }
.hero .n { color: var(--dim); font-size: 13px; margin-top: 8px; }
.split { display: flex; height: 14px; border-radius: 7px; overflow: hidden; background: var(--line); margin-top: 12px; }
.split > div { height: 100%; min-width: 0; transition: width .6s ease; }
.card .p { color: var(--dim); font-size: 14px; font-weight: 600; margin-left: 6px; }
.card .dot { display: inline-block; width: 9px; height: 9px; border-radius: 2px; margin-right: 6px; vertical-align: 0; }
.sect { font-size: 16px; margin: 22px 0 4px; }
.right { float: right; color: var(--dim); font-weight: 400; font-size: 12px; }
.legend { color: var(--dim); font-size: 12px; margin-left: 8px; font-weight: 400; }
.legend i { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin: 0 4px 0 10px; vertical-align: -1px; }
svg { width: 100%; height: auto; display: block; }
svg text { fill: var(--dim); font-size: 10px; }
table { width: 100%; border-collapse: collapse; font-variant-numeric: tabular-nums; }
th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid var(--line); }
th { color: var(--dim); font-weight: 500; font-size: 12px; }
.bands { display: grid; grid-template-columns: 56px 1fr 48px; gap: 6px 10px; align-items: center; }
.bands .b { height: 14px; background: var(--bar); border-radius: 3px; }
.err { color: #f85149; }
.live { display: inline-flex; align-items: center; gap: 6px; font-size: 12px; color: var(--dim); margin-left: 8px; }
.live i { width: 8px; height: 8px; border-radius: 50%; background: #8b949e; }
.live.on i { background: var(--good); box-shadow: 0 0 0 0 rgba(63,185,80,.6); animation: pulse 2s infinite; }
.live.on { color: var(--good); }
@keyframes pulse { 0% { box-shadow: 0 0 0 0 rgba(63,185,80,.6); } 70% { box-shadow: 0 0 0 7px rgba(63,185,80,0); } 100% { box-shadow: 0 0 0 0 rgba(63,185,80,0); } }
.lobbies { display: grid; grid-template-columns: 1fr auto auto; gap: 6px 14px; font-variant-numeric: tabular-nums; }
.lobbies .m { font-weight: 600; }
.lobbies .d { color: var(--dim); }
@keyframes flash { from { background: rgba(245,165,36,.25); } to { background: transparent; } }
tr.new td { animation: flash 2.5s ease-out; }
</style>
</head>
<body>
<main>
<h1>Rofront live <span class="live" id="live"><i></i><span>Connecting…</span></span></h1>
<p class="sub"><span id="upd"></span></p>
<div class="hero">
<div class="k">Players online now</div>
<div class="total" id="total">–</div>
<div class="split" id="split"></div>
<div class="n" id="totalnote"></div>
</div>
<div class="cards" id="nowcards"></div>
<div class="panel"><h2>Players over the last 24 hours<span class="right" id="range24"></span><span class="legend"><i style="background:#f5a524"></i>solo<i style="background:#388bfd"></i>public match<i style="background:#3fb950"></i>waiting in a lobby<i style="background:#484f58"></i>title screen</span></h2><div id="players"></div></div>
<h1 class="sect">Players per public match</h1>
<p class="sub">How many players each public match started with (bots fill the rest).</p>
<div class="panel"><h2>Open lobbies</h2><div class="lobbies" id="open"></div></div>
<div class="cards" id="cards"></div>
<div class="panel"><h2>Last 30 days, by day (UTC)<span class="legend"><i style="background:var(--bar)"></i>average<i style="background:var(--max)"></i>best match</span></h2><div id="daily"></div></div>
<div class="panel"><h2>Last 48 hours, by hour<span class="legend"><i style="background:var(--bar)"></i>average<i style="background:var(--max)"></i>best match</span></h2><div id="hourly"></div></div>
<div class="panel"><h2>Last 24 hours: matches by players at start</h2><div class="bands" id="bands"></div></div>
<div class="panel"><h2>Latest matches</h2><table><thead><tr><th>Started</th><th>Map</th><th>Players</th><th>Slots</th></tr></thead><tbody id="recent"></tbody></table></div>
</main>
<script>
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
const plural = (n, w) => n + " " + w + (n === 1 ? "" : "es");
let last = null, gotAt = 0, lastRecent = null;
function card(k, s, note) {
  return '<div class="card"><div class="k">' + k + '</div><div class="v">' + (s.matches ? s.avg : "–") + '</div>' +
    '<div class="n">avg players · ' + plural(s.matches, "match") + ' · best ' + s.max + (note || "") + '</div></div>';
}
const COLORS = { solo: "#f5a524", playing: "#388bfd", waiting: "#3fb950", title: "#484f58" };
const num = (v) => Number(v || 0).toLocaleString();
// One part of the players online: its count, its share of the total, a note.
function part(key, k, v, total, n) {
  const pct = total > 0 ? Math.round((v / total) * 100) : 0;
  return '<div class="card"><div class="k"><i class="dot" style="background:' + COLORS[key] + '"></i>' + k + '</div><div class="v">' + num(v) +
    '<span class="p">' + pct + '%</span></div><div class="n">' + n + '</div></div>';
}
function chart(rows, fmt) {
  const W = 1000, H = 190, L = 28, B = 22, T = 8;
  // (the axis up to the best match, rounded up to a gridline)
  const top = Math.max(10, Math.ceil(Math.max(0, ...rows.map((r) => r.max)) / 10) * 10);
  const y = (v) => T + (H - T - B) * (1 - v / top);
  const bw = (W - L) / rows.length;
  let g = "";
  for (let v = 0; v <= top; v += 10) {
    g += '<line x1="' + L + '" x2="' + W + '" y1="' + y(v) + '" y2="' + y(v) + '" stroke="#262d36"/>';
    g += '<text x="' + (L - 4) + '" y="' + (y(v) + 3) + '" text-anchor="end">' + v + '</text>';
  }
  rows.forEach((r, i) => {
    const x = L + i * bw;
    if (r.matches) {
      g += '<rect x="' + (x + bw * 0.15) + '" y="' + y(r.avg) + '" width="' + bw * 0.7 + '" height="' + (y(0) - y(r.avg)) + '" fill="#388bfd" rx="2"><title>' + esc(fmt(r.t)) + ': avg ' + r.avg + ', best ' + r.max + ', ' + plural(r.matches, "match") + '</title></rect>';
      g += '<rect x="' + (x + bw * 0.15) + '" y="' + (y(r.max) - 1) + '" width="' + bw * 0.7 + '" height="2" fill="#a371f7"/>';
    }
    if (i % Math.ceil(rows.length / 10) === 0) g += '<text x="' + (x + bw / 2) + '" y="' + (H - 6) + '" text-anchor="middle">' + esc(fmt(r.t)) + '</text>';
  });
  return '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img">' + g + '</svg>';
}
function stacked(rows) {
  const W = 1000, H = 190, L = 34, B = 22, T = 8;
  const keys = [["solo", "#f5a524"], ["playing", "#388bfd"], ["waiting", "#3fb950"], ["title", "#484f58"]];
  const top = Math.max(10, ...rows.map((r) => r.solo + r.playing + r.waiting + r.title));
  const step = Math.pow(10, Math.floor(Math.log10(top))) / (top / Math.pow(10, Math.floor(Math.log10(top))) < 3 ? 2 : 1);
  const y = (v) => T + (H - T - B) * (1 - v / top);
  const t0 = rows[0].t, t1 = Date.now() / 1000, span = Math.max(1, t1 - t0);
  const bw = Math.max(2, (W - L) / 96);
  let g = "";
  for (let v = 0; v <= top; v += step) {
    g += '<line x1="' + L + '" x2="' + W + '" y1="' + y(v) + '" y2="' + y(v) + '" stroke="#262d36"/><text x="' + (L - 4) + '" y="' + (y(v) + 3) + '" text-anchor="end">' + v + '</text>';
  }
  rows.forEach((r, i) => {
    const x = L + ((r.t - t0) / span) * (W - L - bw);
    let base = 0;
    for (const [k, c] of keys) {
      const v = r[k];
      if (v > 0) g += '<rect x="' + x + '" y="' + y(base + v) + '" width="' + (bw - 1) + '" height="' + (y(base) - y(base + v)) + '" fill="' + c + '"><title>' +
        esc(new Date(r.t * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })) + ': ' + (r.solo + r.playing + r.waiting + r.title) + ' players (solo ' + r.solo + ', public ' + r.playing + ', waiting ' + r.waiting + ', title ' + r.title + ')</title></rect>';
      base += v;
    }
    if (i % Math.ceil(rows.length / 8) === 0) g += '<text x="' + (x + bw / 2) + '" y="' + (H - 6) + '" text-anchor="middle">' + esc(new Date(r.t * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })) + '</text>';
  });
  return '<svg viewBox="0 0 ' + W + ' ' + H + '" role="img">' + g + '</svg>';
}
const sumOf = (r) => (r.solo || 0) + (r.playing || 0) + (r.waiting || 0) + (r.title || 0);
const mmss = (s) => { s = Math.max(0, Math.round(s)); return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0"); };
function tick() {
  if (!last) return;
  const since = (Date.now() - gotAt) / 1000;
  const n = last.now || { open: [] };
  const rows = n.open.filter((l) => l.startsIn - since > 0);
  document.getElementById("open").innerHTML = rows.map((l) =>
    '<div class="m">' + esc(l.map) + '</div><div>' + l.players + ' / ' + l.max + ' players</div><div class="d">starts in ' + mmss(l.startsIn - since) + '</div>').join("") ||
    '<div class="d">No open lobbies.</div>';
  document.getElementById("upd").textContent = "Updated " + (since < 2 ? "just now" : Math.round(since) + " s ago") + ".";
}
function render(s) {
  last = s; gotAt = Date.now();
  const n = s.now || { waiting: 0, playing: 0, running: 0, open: [] };
  // everyone online: one number, and what they are doing
  const total = sumOf(n);
  document.getElementById("total").innerHTML = num(total) + '<small>' + (total === 1 ? "player" : "players") + '</small>';
  document.title = num(total) + " online · Rofront";
  document.getElementById("split").innerHTML = ["solo", "playing", "waiting", "title"].map((k) =>
    '<div title="' + k + ': ' + num(n[k]) + '" style="background:' + COLORS[k] + ';width:' + (total > 0 ? ((n[k] || 0) / total) * 100 : 0) + '%"></div>').join("");
  const day24 = s.players24h || [];
  const totals = day24.map(sumOf);
  const peak = totals.length ? Math.max(...totals) : 0;
  const avg24 = totals.length ? Math.round(totals.reduce((a, b) => a + b, 0) / totals.length) : 0;
  const peakAt = totals.length ? day24[totals.indexOf(peak)].t : 0;
  const clock = (t) => new Date(t * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
  const range = totals.length ? "peak " + num(peak) + " at " + clock(peakAt) + " · average " + num(avg24) + " · low " + num(Math.min(...totals)) : "";
  document.getElementById("totalnote").textContent = totals.length ? "Last 24 hours: " + range + "." : "";
  document.getElementById("range24").textContent = range;
  document.getElementById("nowcards").innerHTML =
    part("solo", "Playing solo", n.solo || 0, total, "Relaxed " + (n.soloEasy || 0) + " · Standard " + (n.soloMedium || 0) + " · Brutal " + (n.soloHard || 0)) +
    part("playing", "Playing public", n.playing || 0, total, "players in " + plural(n.running, "match") + " running") +
    part("waiting", "Waiting in lobbies", n.waiting || 0, total, "players in " + n.open.length + " open " + (n.open.length === 1 ? "lobby" : "lobbies")) +
    part("title", "On the title screen", n.title || 0, total, "across " + (n.hubs || 0) + " lobby " + ((n.hubs || 0) === 1 ? "server" : "servers"));
  document.getElementById("players").innerHTML = day24.length ? stacked(day24) :
    '<div class="d" style="color:var(--dim)">Collecting: a point every minute from now on.</div>';
  document.getElementById("cards").innerHTML =
    card("Last hour", s.lastHour) + card("Last 24 hours", s.last24h, " · median " + s.last24h.median) +
    card("Last 7 days", s.last7d) +
    '<div class="card"><div class="k">Best match ever</div><div class="v">' + (s.best ? s.best.humans : "–") + '</div><div class="n">' +
    (s.best ? esc(s.best.map) + " · " + new Date(s.best.t * 1000).toLocaleString() : "no matches yet") + '</div></div>';
  const day = (t) => new Date(t * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", timeZone: "UTC" });
  const hour = (t) => new Date(t * 1000).toLocaleTimeString(undefined, { hour: "numeric" });
  document.getElementById("daily").innerHTML = chart(s.daily, day);
  document.getElementById("hourly").innerHTML = chart(s.hourly, hour);
  const most = Math.max(1, ...Object.values(s.bands24h));
  document.getElementById("bands").innerHTML = Object.entries(s.bands24h).map(([k, c]) =>
    '<div>' + k + '</div><div><div class="b" style="width:' + (c / most) * 100 + '%"></div></div><div>' + c + '</div>').join("");
  const newest = s.recent[0] ? s.recent[0].t : null;
  const fresh = lastRecent !== null && newest !== null && newest > lastRecent ? lastRecent : null;
  lastRecent = newest;
  document.getElementById("recent").innerHTML = s.recent.map((m) =>
    '<tr' + (fresh !== null && m.t > fresh ? ' class="new"' : '') + '><td>' + new Date(m.t * 1000).toLocaleString() + '</td><td>' + esc(m.map) + '</td><td>' + m.humans + '</td><td>' + m.max + '</td></tr>').join("") ||
    '<tr><td colspan="4">No public matches started yet.</td></tr>';
  tick();
}
function status(on, text) {
  const el = document.getElementById("live");
  el.className = "live" + (on ? " on" : "");
  el.lastElementChild.textContent = text;
}
async function poll() {
  try {
    const r = await fetch("/stats.json", { cache: "no-store" });
    // (signed out: the cookie ran out or the password changed)
    if (r.status === 401) { location.href = "/login?next=%2Fstats"; return; }
    render(await r.json());
  }
  catch (e) { document.getElementById("upd").innerHTML = '<span class="err">Could not load the stats (' + esc(e.message) + ').</span>'; }
}
let es = null, fallback = null;
function connect() {
  if (!window.EventSource) { status(false, "Refreshing every 5 s"); poll(); setInterval(poll, 5000); return; }
  es = new EventSource("/stats/events");
  es.onopen = () => { status(true, "Live"); if (fallback) { clearInterval(fallback); fallback = null; } };
  es.onmessage = (ev) => { try { render(JSON.parse(ev.data)); } catch (e) {} };
  es.onerror = () => {
    status(false, "Reconnecting…");
    if (!fallback) { poll(); fallback = setInterval(poll, 5000); }
  };
}
connect();
setInterval(tick, 1000);
</script>
</body>
</html>
`;
