// HTML template for stats page
// format args: uptime_secs, uptime_str, jetstream_endpoint, posts_checked (x2),
//              matches_found (x2), posts_created (x2), cooldowns_hit (x2),
//              blocks_respected (x2), errors (x2), bufos_loaded (x2), top_section

pub const html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>bufo-bot stats</title>
    \\<link rel="icon" href="https://all-the.bufo.zone/bufo-offers-chart-with-upwards-trend.png">
    \\<style>
    \\  body {{
    \\    font-family: 'SF Mono', 'Monaco', 'Inconsolata', 'Fira Mono', 'Droid Sans Mono', 'Source Code Pro', monospace;
    \\    max-width: 600px;
    \\    margin: 40px auto;
    \\    padding: 20px;
    \\    background: #1a1a2e;
    \\    color: #eee;
    \\    font-size: 14px;
    \\  }}
    \\  h1 {{ color: #7bed9f; margin-bottom: 30px; }}
    \\  .stat {{
    \\    display: flex;
    \\    justify-content: space-between;
    \\    padding: 12px 0;
    \\    border-bottom: 1px solid #333;
    \\  }}
    \\  .stat-label {{ color: #aaa; }}
    \\  .stat-value {{ font-weight: bold; }}
    \\  .excluded {{
    \\    margin-top: 20px;
    \\    padding: 12px 0;
    \\    color: #666;
    \\    font-size: 0.9em;
    \\  }}
    \\  .excluded-label {{ color: #666; }}
    \\  .excluded-value {{ color: #888; }}
    \\  h2 {{ color: #7bed9f; margin-top: 40px; font-size: 1.2em; }}
    \\  .bufo-grid {{
    \\    display: flex;
    \\    flex-wrap: wrap;
    \\    gap: 8px;
    \\    justify-content: flex-start;
    \\    align-items: flex-start;
    \\    margin-top: 16px;
    \\  }}
    \\  .bufo-card {{
    \\    position: relative;
    \\    border-radius: 8px;
    \\    overflow: hidden;
    \\    background: #252542;
    \\    transition: transform 0.2s;
    \\    cursor: pointer;
    \\  }}
    \\  .bufo-card:hover {{
    \\    transform: scale(1.1);
    \\    z-index: 10;
    \\  }}
    \\  .bufo-card img {{
    \\    width: 100%;
    \\    height: 100%;
    \\    object-fit: cover;
    \\  }}
    \\  .bufo-count {{
    \\    position: absolute;
    \\    bottom: 4px;
    \\    right: 4px;
    \\    background: rgba(0,0,0,0.7);
    \\    color: #7bed9f;
    \\    padding: 2px 6px;
    \\    border-radius: 4px;
    \\    font-size: 11px;
    \\  }}
    \\  .no-bufos {{ color: #666; text-align: center; }}
    \\  .footer {{
    \\    margin-top: 40px;
    \\    padding-top: 20px;
    \\    border-top: 1px solid #333;
    \\    color: #666;
    \\    font-size: 0.9em;
    \\  }}
    \\  a {{ color: #7bed9f; }}
    \\  .links {{ color: #666; margin-bottom: 30px; font-size: 0.9em; }}
    \\  .modal {{
    \\    display: none;
    \\    position: fixed;
    \\    top: 0; left: 0; right: 0; bottom: 0;
    \\    background: rgba(0,0,0,0.8);
    \\    z-index: 100;
    \\    justify-content: center;
    \\    align-items: center;
    \\  }}
    \\  .modal.show {{ display: flex; }}
    \\  .modal-content {{
    \\    background: #252542;
    \\    padding: 20px;
    \\    border-radius: 8px;
    \\    width: 90vw;
    \\    max-width: 600px;
    \\    height: 85vh;
    \\    display: flex;
    \\    flex-direction: column;
    \\  }}
    \\  .modal-content h3 {{ margin-top: 0; color: #7bed9f; }}
    \\  .modal-content .close {{ cursor: pointer; float: right; font-size: 20px; }}
    \\  .modal-content .no-posts {{ color: #666; text-align: center; padding: 20px; }}
    \\  .embed-wrap {{ flex: 1; overflow: hidden; }}
    \\  .embed-wrap iframe {{ border: none; width: 100%; height: 100%; border-radius: 8px; }}
    \\  .nav {{ display: flex; justify-content: space-between; align-items: center; margin-top: 10px; gap: 10px; }}
    \\  .nav button {{ background: #7bed9f; color: #1a1a2e; border: none; padding: 6px 12px; border-radius: 4px; cursor: pointer; }}
    \\  .nav button:disabled {{ opacity: 0.3; cursor: default; }}
    \\  .nav span {{ color: #aaa; font-size: 12px; }}
    \\  .lookup {{ margin-top: 30px; padding: 20px 0; border-top: 1px solid #333; }}
    \\  .lookup h2 {{ margin-top: 0; }}
    \\  .lookup-form {{ display: flex; gap: 8px; }}
    \\  .lookup-input-wrap {{ position: relative; flex: 1; }}
    \\  .lookup-form input {{
    \\    width: 100%; box-sizing: border-box; background: #252542; border: 1px solid #444; color: #eee;
    \\    padding: 8px 12px; border-radius: 4px; font-family: inherit; font-size: 14px;
    \\  }}
    \\  .lookup-form input::placeholder {{ color: #666; }}
    \\  .lookup-form input:focus {{ outline: none; border-color: #7bed9f; }}
    \\  .ac-results {{
    \\    display: none; position: absolute; top: 100%; left: 0; right: 0;
    \\    background: #252542; border: 1px solid #444; border-top: none;
    \\    border-radius: 0 0 4px 4px; max-height: 240px; overflow-y: auto; z-index: 50;
    \\  }}
    \\  .ac-results.show {{ display: block; }}
    \\  .ac-item {{
    \\    display: flex; align-items: center; gap: 8px; padding: 8px 12px;
    \\    cursor: pointer; border: none; background: none; color: #eee;
    \\    width: 100%; font-family: inherit; font-size: 13px; text-align: left;
    \\  }}
    \\  .ac-item:hover {{ background: #333; }}
    \\  .ac-avatar {{
    \\    width: 28px; height: 28px; border-radius: 50%; object-fit: cover; flex-shrink: 0;
    \\  }}
    \\  .ac-placeholder {{
    \\    width: 28px; height: 28px; border-radius: 50%; background: #444;
    \\    display: flex; align-items: center; justify-content: center;
    \\    color: #888; font-size: 12px; flex-shrink: 0;
    \\  }}
    \\  .ac-info {{ min-width: 0; }}
    \\  .ac-name {{ color: #eee; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }}
    \\  .ac-handle {{ color: #666; font-size: 12px; }}
    \\  #lookup-btn {{
    \\    background: #7bed9f; color: #1a1a2e; border: none; padding: 8px 16px;
    \\    border-radius: 4px; cursor: pointer; font-family: inherit; font-weight: bold;
    \\  }}
    \\  #lookup-btn:disabled {{ opacity: 0.5; cursor: default; }}
    \\  .lookup-status {{ color: #aaa; margin-top: 12px; font-size: 13px; display: none; }}
    \\  .lookup-count {{ color: #7bed9f; font-weight: bold; margin-top: 12px; }}
    \\  .lookup-grid {{
    \\    display: flex; flex-wrap: wrap; gap: 8px; margin-top: 10px;
    \\  }}
    \\  .lookup-card {{
    \\    position: relative; width: 80px; height: 80px; border-radius: 6px;
    \\    overflow: hidden; background: #252542; cursor: pointer; transition: transform 0.2s;
    \\  }}
    \\  .lookup-card:hover {{ transform: scale(1.1); z-index: 10; }}
    \\  .lookup-card img {{ width: 100%; height: 100%; object-fit: cover; }}
    \\  .lookup-card .lc-idx {{
    \\    position: absolute; bottom: 2px; right: 4px; font-size: 10px;
    \\    color: #7bed9f; background: rgba(0,0,0,0.7); padding: 1px 4px; border-radius: 3px;
    \\  }}
    \\</style>
    \\</head>
    \\<body>
    \\<h1>bufo-bot stats</h1>
    \\<div class="links">
    \\  <a href="https://find-bufo.com">find-bufo.com</a> ·
    \\  <a href="https://bsky.app/profile/find-bufo.com">@find-bufo.com</a> ·
    \\  <a href="https://tangled.org/zzstoatzz.io/find-bufo">source</a>
    \\</div>
    \\
    \\<div class="stat">
    \\  <span class="stat-label">uptime</span>
    \\  <span class="stat-value" id="uptime" data-seconds="{}">{s}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">jetstream</span>
    \\  <span class="stat-value">{s}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">posts checked</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">matches found</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">bufos posted</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">cooldowns hit</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">blocks respected</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">errors</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\<div class="stat">
    \\  <span class="stat-label">bufos available</span>
    \\  <span class="stat-value" data-num="{}">{}</span>
    \\</div>
    \\
    \\<div class="excluded">
    \\  <span class="excluded-label">excluded</span>
    \\  <span class="excluded-value">posts with nsfw <a href="https://docs.bsky.app/docs/advanced-guides/moderation#labels">labels</a> or keywords</span>
    \\</div>
    \\
    \\<div class="lookup">
    \\  <h2>user lookup</h2>
    \\  <div class="lookup-form">
    \\    <div class="lookup-input-wrap">
    \\      <input type="text" id="lookup-input" placeholder="handle (e.g. jay.bsky.team)" autocomplete="off"
    \\        oninput="onLookupInput()" onkeydown="onLookupKey(event)"
    \\        onfocus="if(acActors.length)document.getElementById('ac-results').classList.add('show')">
    \\      <div id="ac-results" class="ac-results"></div>
    \\    </div>
    \\    <button id="lookup-btn" onclick="lookupUser()">search</button>
    \\  </div>
    \\  <div id="lookup-status" class="lookup-status"></div>
    \\  <div id="lookup-results"></div>
    \\</div>
    \\
    \\<h2>matched bufos</h2>
    \\<div class="bufo-grid">
    \\{s}
    \\</div>
    \\
    \\<div class="footer">
    \\  <a href="https://find-bufo.com">find-bufo.com</a> ·
    \\  <a href="https://bsky.app/profile/find-bufo.com">@find-bufo.com</a> ·
    \\  <a href="https://tangled.org/zzstoatzz.io/find-bufo">source</a>
    \\</div>
    \\<div id="modal" class="modal" onclick="if(event.target===this)closeModal()">
    \\  <div class="modal-content">
    \\    <span class="close" onclick="closeModal()">&times;</span>
    \\    <h3 id="modal-title">posts</h3>
    \\    <div id="embed-wrap" class="embed-wrap"></div>
    \\    <div id="nav" class="nav" style="display:none">
    \\      <button onclick="showEmbed(-1)">&larr;</button>
    \\      <span id="nav-info"></span>
    \\      <button onclick="showEmbed(1)">&rarr;</button>
    \\    </div>
    \\  </div>
    \\</div>
    \\<script>
    \\(function() {{
    \\  document.querySelectorAll('[data-num]').forEach(el => {{
    \\    el.textContent = parseInt(el.dataset.num).toLocaleString();
    \\  }});
    \\  const uptimeEl = document.getElementById('uptime');
    \\  let secs = parseInt(uptimeEl.dataset.seconds);
    \\  function fmt(s) {{
    \\    const d = Math.floor(s / 86400);
    \\    const h = Math.floor((s % 86400) / 3600);
    \\    const m = Math.floor((s % 3600) / 60);
    \\    const sec = s % 60;
    \\    if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
    \\    if (h > 0) return h + 'h ' + m + 'm ' + sec + 's';
    \\    if (m > 0) return m + 'm ' + sec + 's';
    \\    return sec + 's';
    \\  }}
    \\  setInterval(() => {{ secs++; uptimeEl.textContent = fmt(secs); }}, 1000);
    \\}})();
    \\let posts = [], idx = 0;
    \\async function showPosts(el) {{
    \\  const name = el.dataset.name;
    \\  document.getElementById('modal-title').textContent = name;
    \\  document.getElementById('embed-wrap').innerHTML = '<p class="no-posts">loading...</p>';
    \\  document.getElementById('nav').style.display = 'none';
    \\  document.getElementById('modal').classList.add('show');
    \\  try {{
    \\    const r = await fetch('https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=find-bufo.com&limit=100');
    \\    const data = await r.json();
    \\    const search = name.replace('bufo-','').replace(/-/g,' ');
    \\    posts = data.feed.filter(p => {{
    \\      const embed = p.post.embed;
    \\      if (!embed) return false;
    \\      const img = embed.images?.[0] || embed.media?.images?.[0];
    \\      if (img?.alt?.includes(search)) return true;
    \\      if (embed.alt?.includes(search)) return true;
    \\      if (embed.media?.alt?.includes(search)) return true;
    \\      return false;
    \\    }});
    \\    idx = 0;
    \\    if (posts.length === 0) {{
    \\      document.getElementById('embed-wrap').innerHTML = '<p class="no-posts">no posts found</p>';
    \\    }} else {{
    \\      showEmbed(0);
    \\    }}
    \\  }} catch(e) {{
    \\    document.getElementById('embed-wrap').innerHTML = '<p class="no-posts">failed to load</p>';
    \\  }}
    \\}}
    \\function showEmbed(d) {{
    \\  idx = Math.max(0, Math.min(posts.length - 1, idx + d));
    \\  const uri = posts[idx].post.uri.replace('at://','');
    \\  document.getElementById('embed-wrap').innerHTML = '<iframe src="https://embed.bsky.app/embed/' + uri + '"></iframe>';
    \\  document.getElementById('nav').style.display = 'flex';
    \\  document.getElementById('nav-info').textContent = (idx + 1) + ' of ' + posts.length;
    \\  document.querySelectorAll('.nav button')[0].disabled = idx === 0;
    \\  document.querySelectorAll('.nav button')[1].disabled = idx === posts.length - 1;
    \\}}
    \\function closeModal() {{
    \\  document.getElementById('modal').classList.remove('show');
    \\}}
    \\let acTimer = null, acActors = [], acIdx = -1;
    \\function onLookupInput() {{
    \\  if (acTimer) clearTimeout(acTimer);
    \\  const q = document.getElementById('lookup-input').value.trim().replace(/^@/, '');
    \\  if (q.length < 2) {{ hideAc(); return; }}
    \\  acTimer = setTimeout(() => fetchAc(q), 300);
    \\}}
    \\async function fetchAc(q) {{
    \\  try {{
    \\    const r = await fetch('https://public.api.bsky.app/xrpc/app.bsky.actor.searchActorsTypeahead?q=' + encodeURIComponent(q) + '&limit=8');
    \\    if (!r.ok) return;
    \\    const data = await r.json();
    \\    acActors = data.actors || [];
    \\    acIdx = -1;
    \\    renderAc();
    \\  }} catch(e) {{}}
    \\}}
    \\function renderAc() {{
    \\  const el = document.getElementById('ac-results');
    \\  if (acActors.length === 0) {{ hideAc(); return; }}
    \\  el.innerHTML = acActors.map((a, i) =>
    \\    '<button type="button" class="ac-item' + (i === acIdx ? '" style="background:#333' : '') + '" onmousedown="selectAc(' + i + ')">' +
    \\    (a.avatar ? '<img class="ac-avatar" src="' + a.avatar + '">' : '<div class="ac-placeholder">' + (a.handle[0] || '?') + '</div>') +
    \\    '<div class="ac-info"><div class="ac-name">' + esc(a.displayName || a.handle) + '</div>' +
    \\    '<div class="ac-handle">@' + esc(a.handle) + '</div></div></button>'
    \\  ).join('');
    \\  el.classList.add('show');
    \\}}
    \\function esc(s) {{ const d = document.createElement('div'); d.textContent = s; return d.innerHTML; }}
    \\function selectAc(i) {{
    \\  const a = acActors[i];
    \\  if (!a) return;
    \\  document.getElementById('lookup-input').value = a.handle;
    \\  hideAc();
    \\  lookupUser();
    \\}}
    \\function hideAc() {{
    \\  acActors = []; acIdx = -1;
    \\  document.getElementById('ac-results').classList.remove('show');
    \\}}
    \\function onLookupKey(e) {{
    \\  const el = document.getElementById('ac-results');
    \\  if (e.key === 'Escape') {{ hideAc(); return; }}
    \\  if (!el.classList.contains('show') || acActors.length === 0) {{
    \\    if (e.key === 'Enter') lookupUser();
    \\    return;
    \\  }}
    \\  if (e.key === 'ArrowDown') {{ e.preventDefault(); acIdx = Math.min(acIdx + 1, acActors.length - 1); renderAc(); }}
    \\  else if (e.key === 'ArrowUp') {{ e.preventDefault(); acIdx = Math.max(acIdx - 1, -1); renderAc(); }}
    \\  else if (e.key === 'Enter') {{ e.preventDefault(); if (acIdx >= 0) selectAc(acIdx); else {{ hideAc(); lookupUser(); }} }}
    \\}}
    \\document.addEventListener('click', e => {{ if (!e.target.closest('.lookup-input-wrap')) hideAc(); }});
    \\let lookupResults = [];
    \\async function lookupUser() {{
    \\  const input = document.getElementById('lookup-input');
    \\  const handle = input.value.trim().replace(/^@/, '');
    \\  if (!handle) return;
    \\  const btn = document.getElementById('lookup-btn');
    \\  const status = document.getElementById('lookup-status');
    \\  const results = document.getElementById('lookup-results');
    \\  btn.disabled = true;
    \\  results.innerHTML = '';
    \\  status.textContent = 'resolving handle...';
    \\  status.style.display = 'block';
    \\  try {{
    \\    const res = await fetch('https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=' + encodeURIComponent(handle));
    \\    if (!res.ok) {{ status.textContent = 'user not found'; btn.disabled = false; return; }}
    \\    const {{ did }} = await res.json();
    \\    const prefix = 'at://' + did + '/';
    \\    let cursor = undefined;
    \\    let found = [];
    \\    let checked = 0;
    \\    while (true) {{
    \\      let url = 'https://public.api.bsky.app/xrpc/app.bsky.feed.getAuthorFeed?actor=find-bufo.com&limit=100';
    \\      if (cursor) url += '&cursor=' + encodeURIComponent(cursor);
    \\      const r = await fetch(url);
    \\      if (!r.ok) break;
    \\      const data = await r.json();
    \\      if (!data.feed || data.feed.length === 0) break;
    \\      checked += data.feed.length;
    \\      status.textContent = 'checking posts... (' + checked + '/?)';
    \\      for (const item of data.feed) {{
    \\        const embed = item.post.embed;
    \\        if (!embed) continue;
    \\        const uri = embed.record?.record?.uri || embed.record?.uri || '';
    \\        if (uri.startsWith(prefix)) found.push(item);
    \\      }}
    \\      cursor = data.cursor;
    \\      if (!cursor) break;
    \\    }}
    \\    if (found.length === 0) {{
    \\      status.textContent = 'no bufo quotes found for @' + handle;
    \\      btn.disabled = false;
    \\      return;
    \\    }}
    \\    status.style.display = 'none';
    \\    lookupResults = found;
    \\    let html = '<div class="lookup-count">' + found.length + ' bufo quote' + (found.length === 1 ? '' : 's') + ' for @' + esc(handle) + '</div>';
    \\    html += '<div class="lookup-grid">';
    \\    found.forEach((item, i) => {{
    \\      const embed = item.post.embed;
    \\      const img = embed?.images?.[0] || embed?.media?.images?.[0];
    \\      const thumb = img?.thumb || img?.fullsize || '';
    \\      const alt = img?.alt || '';
    \\      html += '<div class="lookup-card" onclick="openLookup(' + i + ')" title="' + esc(alt) + '">';
    \\      if (thumb) html += '<img src="' + thumb + '" alt="' + esc(alt) + '">';
    \\      html += '<span class="lc-idx">' + (i + 1) + '</span></div>';
    \\    }});
    \\    html += '</div>';
    \\    results.innerHTML = html;
    \\  }} catch(e) {{
    \\    status.textContent = 'error: ' + e.message;
    \\  }}
    \\  btn.disabled = false;
    \\}}
    \\function openLookup(i) {{
    \\  posts = lookupResults;
    \\  idx = i;
    \\  document.getElementById('modal-title').textContent = 'bufo quotes';
    \\  document.getElementById('modal').classList.add('show');
    \\  showEmbed(0);
    \\}}
    \\</script>
    \\</body>
    \\</html>
;
