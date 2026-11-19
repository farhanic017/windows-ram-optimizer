const http = require('http');
const fs = require('fs');
const path = require('path');
const { Core, getRAM, getMMA, isAdmin } = require('../optimizer');

const PORT = 8787;
const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>windows-ram-optimizer — 1.6GB one-click</title>
<style>
*{font-family:Inter,Segoe UI,system-ui,sans-serif}body{margin:0;background:#0a0f1e;color:#e6edf3;display:flex;min-height:100vh;align-items:center;justify-content:center}
.card{width:560px;background:#111827;border:1px solid #263248;border-radius:16px;padding:28px;box-shadow:0 20px 60px rgba(0,0,0,.5)}
h1{margin:0 0 6px;font-size:22px} p{color:#9aa8c3;margin:0 0 16px}
.stat{display:flex;gap:12px;margin:14px 0}.pill{flex:1;background:#0d182e;border:1px solid #1e2e4a;border-radius:10px;padding:12px;text-align:center}
.pill b{font-size:20px;display:block}.btn{width:100%;padding:14px;border:0;border-radius:10px;background:#3b82f6;color:#fff;font-weight:700;font-size:15px;cursor:pointer}
.btn:disabled{opacity:.5}.row{display:flex;gap:8px;margin-top:10px}.ghost{flex:1;padding:10px;border-radius:10px;border:1px solid #2a3a56;background:transparent;color:#9aa8c3;cursor:pointer}
.log{margin-top:14px;background:#0b1224;border:1px solid #1b2a45;border-radius:10px;padding:12px;height:160px;overflow:auto;font-family:Consolas,monospace;font-size:12px;white-space:pre-wrap}
a{color:#60a5fa}.badge{display:inline-block;padding:2px 8px;border-radius:999px;font-size:11px;font-weight:700;vertical-align:middle}
.ok{background:#12351f;color:#4ade80;border:1px solid #1f5135}.warn{background:#3a2a12;color:#fbbf24;border:1px solid #55401c}
</style></head><body><div class="card">
<h1>⚡ windows-ram-optimizer <span class="badge" id="adm" hidden></span></h1><p>ReviOS-grade — 4304MB → 1569MB on 8GB. One click, permanent (survives reboot).</p>
<div class="stat"><div class="pill"><span>Idle RAM</span><b id="ram">—</b><small id="ramd"></small></div><div class="pill"><span>Compression</span><b id="mma">—</b><small id="mmad"></small></div></div>
<label style="display:flex;gap:8px;align-items:center;margin:8px 0"><input type="checkbox" id="agg"> Aggressive (extra services Manual)</label>
<button class="btn" id="run">Fix now — 1.6GB idle (admin)</button>
<div class="row"><button class="ghost" id="status">Refresh status</button><button class="ghost" id="revert">Revert</button></div>
<div class="row"><button class="ghost" id="cam">CAM 50MB overlay</button><button class="ghost" id="purge">Purge now</button></div>
<div class="log" id="log">Ready. Click Fix now (run GUI as admin for services/registry).
</div>
<p style="margin-top:12px;font-size:12px;color:#6b7a9e">GitHub: <a href="https://github.com/farhanic017/windows-ram-optimizer">farhanic017/windows-ram-optimizer</a> • CLI: <code>npx windows-ram-optimizer</code></p>
</div>
<script>
async function j(u,o){const r=await fetch(u,{method:o&&o.method||'GET',headers:{'Content-Type':'application/json'},body:o&&o.body?JSON.stringify(o.body):undefined});return r.json()}
function say(m){const l=document.getElementById('log');l.textContent+=m+'\\n';l.scrollTop=l.scrollHeight}
async function refresh(){const s=await j('/api/status');document.getElementById('ram').textContent=s.ram.used+'MB';document.getElementById('ramd').textContent='/ '+s.ram.total+'MB';document.getElementById('mma').textContent=s.mma.MemoryCompression?'ON':'OFF';document.getElementById('mmad').textContent='PageCombining '+(s.mma.PageCombining?'ON':'OFF');
const a=document.getElementById('adm');a.hidden=false;a.textContent=s.admin?'ADMIN':'NOT ADMIN';a.className='badge '+(s.admin?'ok':'warn');}
document.getElementById('status').onclick=refresh;
document.getElementById('revert').onclick=async()=>{say('Reverting...');try{const r=await j('/api/revert',{method:'POST'});say(r.error?('Error: '+r.error):('Reverted: '+JSON.stringify(r)));}catch(e){say('Error: '+e);}refresh()};
document.getElementById('purge').onclick=async()=>{try{const r=await j('/api/purge',{method:'POST'});say(r.error?('Error: '+r.error):('Purge -> '+r.ramAfter.used+'MB'));}catch(e){say('Error: '+e);}refresh()};
document.getElementById('cam').onclick=async()=>{try{const r=await j('/api/cam',{method:'POST'});say(r.error?('Error: '+r.error):('CAM '+JSON.stringify(r)));}catch(e){say('Error: '+e);}};
document.getElementById('run').onclick=async()=>{
  const agg=document.getElementById('agg').checked;
  document.getElementById('run').disabled=true;say('Running (admin required)...');
  try{const r=await j('/api/fix',{method:'POST',body:{aggressive:agg}});if(r.error)throw new Error(r.error);say('Before '+r.ramBefore.used+'MB -> After '+r.ramAfter.used+'MB saved '+(r.ramBefore.used-r.ramAfter.used)+'MB');}
  catch(e){say('Error: '+e.message+' (run this GUI as Administrator)');}
  document.getElementById('run').disabled=false;refresh();
};
refresh();setInterval(refresh,4000);
</script></body></html>`;

// Local admin tool: never answer other hosts (DNS rebinding) and never allow other origins
// (the old `Access-Control-Allow-Origin: *` let any website in your browser drive these
// endpoints). The page is same-origin, so no CORS headers are needed at all.
function hostAllowed(req) {
  const h = (req.headers.host || '').split(':')[0].replace(/^\[|\]$/g, '').toLowerCase();
  return h === 'localhost' || h === '127.0.0.1' || h === '::1';
}
function deny(res) {
  res.writeHead(403, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'blocked: serve this GUI from http://localhost:8787 only' }));
}
function json(res, code, obj) {
  res.writeHead(code, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(obj));
}
function needAdmin(res) {
  if (isAdmin()) return true;
  json(res, 403, { error: 'Run the GUI as Administrator (right-click → Run as admin).' });
  return false;
}
function body(req, cb) {
  let b = ''; req.on('data', (c) => b += c); req.on('end', () => cb(b));
}

const server = http.createServer((req, res) => {
  if (!hostAllowed(req)) return deny(res);

  if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }
  if (req.url === '/' || req.url === '/index.html') { res.writeHead(200, { 'Content-Type': 'text/html' }); return res.end(html); }

  if (req.url === '/api/status') return json(res, 200, { ram: getRAM(), mma: getMMA(), admin: isAdmin() });

  if (req.url === '/api/fix' && req.method === 'POST') {
    return body(req, (b) => {
      try {
        if (!needAdmin(res)) return;
        const o = JSON.parse(b || '{}');
        const r = Core.runAll({ aggressive: !!o.aggressive, telemetry: o.telemetry !== false, camOverlay: o.cam !== false });
        json(res, 200, r);
      } catch (e) { json(res, 500, { error: e.message }); }
    });
  }
  if (req.url === '/api/revert' && req.method === 'POST') {
    if (!needAdmin(res)) return;
    try { json(res, 200, Core.revert()); } catch (e) { json(res, 500, { error: e.message }); }
    return;
  }
  if (req.url === '/api/purge' && req.method === 'POST') {
    if (!needAdmin(res)) return;
    try {
      const { execSync } = require('child_process');
      execSync('powershell -NoProfile -ExecutionPolicy Bypass -File "C:\\ProgramData\\ReviOS\\EmptyStandby.ps1"', { timeout: 60000 });
      json(res, 200, { ramAfter: getRAM() });
    } catch (e) { json(res, 500, { error: e.message }); }
    return;
  }
  if (req.url === '/api/cam' && req.method === 'POST') {
    if (!needAdmin(res)) return;
    try { json(res, 200, Core.fixCamOverlay()); } catch (e) { json(res, 500, { error: e.message }); }
    return;
  }
  res.writeHead(404); res.end('not found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`GUI at http://localhost:${PORT}  (run as admin to Fix)`);
  const { exec } = require('child_process');
  exec(`start "" "http://localhost:${PORT}"`);
});
