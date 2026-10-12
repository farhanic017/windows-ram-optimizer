# FixMMAgent.ps1 — keep memory compression + page combining on after boot (repo parity)
try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
try { Enable-MMAgent -PageCombining    -ErrorAction SilentlyContinue } catch {}
