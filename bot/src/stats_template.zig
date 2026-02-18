// HTML template for stats page
// format args: uptime_secs, uptime_str, posts_checked (x2), matches_found (x2),
//              posts_created (x2), cooldowns_hit (x2), blocks_respected (x2),
//              errors (x2), bufos_loaded (x2), top_section

pub const html =
    \\<!DOCTYPE html>
    \\<html>
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>bufo-bot stats</title>
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
    \\</script>
    \\</body>
    \\</html>
;
