const http = require('http');
const fs = require('fs');
const path = require('path');
const { Core, getRAM, getMMA, isAdmin } = require('../optimizer');

const PORT = 8787;
const html = `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>win-ram-optimizer — 1.6GB one-click</title>
<style>
*{font-family:Inter,Segoe UI,system-ui,sans-serif}body{margin:0;background:#0a0f1e;color:#e6edf3;display:flex;min-height:100vh;align-items:center;justify-content:center}
.card{width:560px;background:#111827;border:1px solid #263248;border-radius:16px;padding:28px;box-shadow:0 20px 60px rgba(0,0,0,.5)}
h1{margin:0 0 6px;font-size:22px} p{color:#9aa8c3;margin:0 0 16px}
.stat{display:flex;gap:12px;margin:14px 0}.pill{flex:1;background:#0d182e;border:1px solid #1e2e4a;border-radius:10px;padding:12px;text-align:center}
.pill b{font-size:20px;display:block}.btn{width:100%;padding:14px;border:0;border-radius:10px;background:#3b82f6;color:#fff;font-weight:700;font-size:15px;cursor:pointer}
.btn:disabled{opacity:.5}.row{display:flex;gap:8px;margin-top:10px}.ghost{flex:1;padding:10px;border-radius:10px;border:1px solid #2a3a56;background:transparent;color:#9aa8c3;cursor:pointer}
.log{margin-top:14px;background:#0b1224;border:1px solid #1b2a45;border-radius:10px;padding:12px;height:160px;overflow:auto;font-family:Consolas,monospace;font-size:12px;white-space:pre-wrap}
a{color:#60a5fa}
</style></head><body><div class="card">
<h1>⚡ win-ram-optimizer</h1><p>ReviOS-grade — 4304MB → 1569MB on 8GB. One click, permanent (survives reboot).</p>
<div class="stat"><div class="pill"><span>Idle RAM</span><b id="ram">—</b><small id="ramd"></small></div><div class="pill"><span>Compression</span><b id="mma">—</b><small id="mmad"></small></div></div>
<label style="display:flex;gap:8px;align-items:center;margin:8px 0"><input type="checkbox" id="agg"> Aggressive (extra services Manual)</label>
<button class="btn" id="run">Fix now — 1.6GB idle (admin)</button>
<div class="row"><button class="ghost" id="status">Refresh status</button><button class="ghost" id="revert">Revert</button></div>
<div class="row"><button class="ghost" id="cam">CAM 50MB overlay</button><button class="ghost" id="purge">Purge now</button></div>
<div class="log" id="log">Ready. Click Fix now (run GUI as admin for services/registry).\n</div>
<p style="margin-top:12px;font-size:12px;color:#6b7a9e">GitHub: <a href="https://github.com/yourname/win-ram-optimizer">yourname/win-ram-optimizer</a> • CLI: <code>npx win-ram-optimizer</code></p>
</div>
<script>
async function j(u,o){const r=await fetch(u,{method:o&&o.method||'GET',headers:{'Content-Type':'application/json'},body:o&&o.body?JSON.stringify(o.body):undefined});return r.json()}
async function refresh(){const s=await j('/api/status');document.getElementById('ram').textContent=s.ram.used+'MB';document.getElementById('ramd').textContent='/ '+s.ram.total+'MB';document.getElementById('mma').textContent=s.mma.MemoryCompression?'ON':'OFF';document.getElementById('mmad').textContent='PageCombining '+(s.mma.PageCombining?'ON':'OFF')}
document.getElementById('status').onclick=refresh;
document.getElementById('revert').onclick=async()=>{document.getElementById('log').textContent+='Reverting...\\n';const r=await j('/api/revert',{method:'POST'});document.getElementById('log').textContent+=JSON.stringify(r)+'\\n';refresh()};
document.getElementById('purge').onclick=async()=>{const r=await j('/api/purge',{method:'POST'});document.getElementById('log').textContent+= 'Purge '+r.ramAfter.used+'MB\\n';refresh()};
document.getElementById('cam').onclick=async()=>{const r=await j('/api/cam',{method:'POST'});document.getElementById('log').textContent+= 'CAM '+JSON.stringify(r)+'\\n'};
document.getElementById('run').onclick=async()=>{
  const agg=document.getElementById('agg').checked;
  document.getElementById('run').disabled=true;const l=document.getElementById('log');l.textContent+='Running (admin required)...\\n';
  try{const r=await j('/api/fix',{method:'POST',body:{aggressive:agg}});l.textContent+= 'Before '+r.ramBefore.used+'MB -> After '+r.ramAfter.used+'MB saved '+(r.ramBefore.used-r.ramAfter.used)+'MB\\n';}
  catch(e){l.textContent+='Error: '+e+' (run as admin)\\n';}
  document.getElementById('run').disabled=false;refresh();
};
refresh();setInterval(refresh,4000);
</script></body></html>`;

const server = http.createServer(async (req,res)=>{
  res.setHeader('Access-Control-Allow-Origin','*'); res.setHeader('Access-Control-Allow-Methods','GET,POST,OPTIONS'); res.setHeader('Access-Control-Allow-Headers','Content-Type');
  if (req.method==='OPTIONS') { res.writeHead(204); return res.end(); }
  if (req.url==='/' || req.url==='/index.html') { res.writeHead(200,{'Content-Type':'text/html'}); return res.end(html); }
  if (req.url==='/api/status') {
    res.writeHead(200,{'Content-Type':'application/json'}); return res.end(JSON.stringify({ ram:getRAM(), mma:getMMA(), admin:isAdmin() }));
  }
  if (req.url==='/api/fix' && req.method==='POST') {
    let b=''; req.on('data',c=>b+=c); req.on('end',()=>{ try{
      const o=JSON.parse(b||'{}');
      if(!isAdmin()) { res.writeHead(403,{'Content-Type':'application/json'}); return res.end(JSON.stringify({error:'Run GUI as Administrator'})); }
      const r=Core.runAll({ aggressive:!!o.aggressive }); res.writeHead(200,{'Content-Type':'application/json'}); res.end(JSON.stringify(r));
    }catch(e){ res.writeHead(500,{'Content-Type':'application/json'}); res.end(JSON.stringify({error:e.message})) }});
    return;
  }
  if (req.url==='/api/revert' && req.method==='POST') { try{ Core.revert(); res.writeHead(200,{'Content-Type':'application/json'}); res.end(JSON.stringify({ok:true})); }catch(e){ res.writeHead(500,{'Content-Type':'application/json'}); res.end(JSON.stringify({error:e.message})); } return; }
  if (req.url==='/api/purge' && req.method==='POST') { try{ const {execSync}=require('child_process'); execSync('powershell -NoProfile -ExecutionPolicy Bypass -File "C:\\ProgramData\\ReviOS\\EmptyStandby.ps1"'); const r=getRAM(); res.writeHead(200,{'Content-Type':'application/json'}); res.end(JSON.stringify({ramAfter:r})); }catch(e){ res.writeHead(500,{'Content-Type':'application/json'}); res.end(JSON.stringify({error:e.message})); } return; }
  if (req.url==='/api/cam' && req.method==='POST') { try{ const r=Core.fixCamOverlay(); res.writeHead(200,{'Content-Type':'application/json'}); res.end(JSON.stringify(r)); }catch(e){ res.writeHead(500,{'Content-Type':'application/json'}); res.end(JSON.stringify({error:e.message})); } return; }
  res.writeHead(404); res.end('not found');
});
server.listen(PORT, ()=> {
  console.log(`GUI at http://localhost:${PORT}  (run as admin to Fix)`);
  const { exec } = require('child_process');
  const url=`http://localhost:${PORT}`;
  exec(`start "" "${url}"`);
});
