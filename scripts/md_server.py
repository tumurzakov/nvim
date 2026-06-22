#!/usr/bin/env python3
"""Tiny localhost HTTP server that serves a whole directory tree.

Every file under --root is reachable by its path:
  - markdown (.md/.markdown) is rendered to an HTML page that auto-reloads
    when the file changes on disk (the page polls /__mtime/<path>),
  - directories show a clickable listing (README.md is rendered inline if present),
  - any other file is served raw (so images referenced from markdown work).

Files are read from disk on every request, so the browser always reflects the
latest save. Binds to 127.0.0.1 only and refuses paths outside --root.

Markdown rendering: pandoc (preferred) -> python `markdown` module -> raw <pre>.
"""
import argparse
import html
import mimetypes
import os
import subprocess
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MD_EXTS = (".md", ".markdown", ".mdown", ".mkd")

CSS = """
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body {
  margin: 0;
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
  background: #ffffff; color: #1f2328;
}
@media (prefers-color-scheme: dark) {
  body { background: #0d1117; color: #e6edf3; }
  a { color: #4493f8; }
  code, pre { background: #161b22 !important; }
  pre { border-color: #30363d !important; }
  blockquote { color: #9198a1; border-color: #30363d !important; }
  table th, table td { border-color: #30363d !important; }
  hr { background: #30363d !important; }
}
article { max-width: 820px; margin: 0 auto; padding: 40px 24px 96px; }
a { color: #0969da; text-decoration: none; }
a:hover { text-decoration: underline; }
h1, h2, h3, h4 { margin-top: 1.6em; margin-bottom: .6em; line-height: 1.25; font-weight: 600; }
h1 { font-size: 1.9em; padding-bottom: .3em; border-bottom: 1px solid rgba(128,128,128,.3); }
h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid rgba(128,128,128,.2); }
p, ul, ol, blockquote, table, pre { margin: 0 0 1em; }
code {
  font: .88em ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;
  background: rgba(128,128,128,.16); padding: .2em .4em; border-radius: 6px;
}
pre {
  background: #f6f8fa; padding: 14px 16px; border-radius: 8px; overflow: auto;
  border: 1px solid rgba(128,128,128,.2);
}
pre code { background: none; padding: 0; }
blockquote { padding: 0 1em; color: #59636e; border-left: .25em solid rgba(128,128,128,.4); }
table { border-collapse: collapse; display: block; overflow: auto; }
table th, table td { border: 1px solid rgba(128,128,128,.4); padding: 6px 13px; }
table tr:nth-child(2n) { background: rgba(128,128,128,.08); }
img { max-width: 100%; }
hr { height: 1px; border: 0; background: rgba(128,128,128,.3); margin: 2em 0; }
ul.dir { list-style: none; padding-left: 0; }
ul.dir li { padding: 2px 0; }
ul.dir a { font: .95em ui-monospace, SFMono-Regular, Menlo, monospace; }
.crumbs { color: #59636e; margin: 0 0 1.5em; font-size: .9em; }
"""

# When `live` is truthy the page polls /__mtime/<relpath> and reloads on change.
PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{css}</style>
<script>
const LIVE = {live};
let last = null;
async function poll() {{
  if (!LIVE) return;
  try {{
    const r = await fetch({mtime_url}, {{cache: 'no-store'}});
    const t = await r.text();
    if (last !== null && t !== last) {{ location.reload(); return; }}
    last = t;
  }} catch (e) {{}}
  setTimeout(poll, 600);
}}
poll();
</script>
</head><body><article>{body}</article></body></html>"""


def render_markdown(path):
    try:
        out = subprocess.run(
            ["pandoc", "--from", "gfm", "--to", "html", path],
            capture_output=True, text=True, check=True,
        )
        return out.stdout
    except Exception:
        pass
    try:
        import markdown  # type: ignore
        with open(path, encoding="utf-8") as f:
            return markdown.markdown(
                f.read(), extensions=["fenced_code", "tables", "codehilite"]
            )
    except Exception:
        with open(path, encoding="utf-8") as f:
            return "<pre>" + html.escape(f.read()) + "</pre>"


def is_markdown(path):
    return path.lower().endswith(MD_EXTS)


def crumbs_html(relpath):
    """Breadcrumb links from the root down to `relpath`'s directory."""
    parts = [p for p in relpath.split("/") if p]
    links = ['<a href="/">root</a>']
    acc = ""
    for p in parts[:-1] if parts else []:
        acc += "/" + p
        links.append('<a href="{}/">{}</a>'.format(html.escape(acc), html.escape(p)))
    return '<div class="crumbs">' + " / ".join(links) + "</div>"


def dir_listing(abspath, relpath):
    """HTML body for a directory: breadcrumbs + entries, README.md rendered inline."""
    try:
        names = sorted(os.listdir(abspath), key=lambda n: (not os.path.isdir(os.path.join(abspath, n)), n.lower()))
    except OSError as e:
        return "<p>Cannot list directory: {}</p>".format(html.escape(str(e)))

    base = "/" + relpath.strip("/")
    if base != "/":
        base += "/"
    items = []
    if relpath.strip("/"):
        items.append('<li><a href="../">../</a></li>')
    readme = None
    for name in names:
        if name.startswith("."):
            continue
        full = os.path.join(abspath, name)
        href = html.escape(base + urllib.parse.quote(name))
        label = html.escape(name) + ("/" if os.path.isdir(full) else "")
        items.append('<li><a href="{}">{}</a></li>'.format(href, label))
        if readme is None and name.lower() == "readme.md":
            readme = full

    body = crumbs_html(relpath + "/x")  # treat dir as the "directory" of itself
    body += "<h1>{}</h1>".format(html.escape("/" + relpath.strip("/") if relpath.strip("/") else "root"))
    body += '<ul class="dir">' + "".join(items) + "</ul>"
    if readme:
        body += "<hr>" + render_markdown(readme)
    return body


def make_handler(root):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, format, *args):  # silence stderr access logs
            pass

        def _send(self, code, body, ctype="text/html; charset=utf-8"):
            data = body if isinstance(body, bytes) else body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            try:
                self.wfile.write(data)
            except BrokenPipeError:
                pass

        def _resolve(self, urlpath):
            """Map a URL path to an absolute path under root, or None if it escapes."""
            rel = urllib.parse.unquote(urlpath.split("?", 1)[0]).lstrip("/")
            abspath = os.path.realpath(os.path.join(root, rel))
            if abspath != root and not abspath.startswith(root + os.sep):
                return None, rel
            return abspath, rel

        def do_GET(self):
            path = urllib.parse.urlparse(self.path).path

            # mtime endpoint used by the live-reload poller: /__mtime/<relpath>
            if path.startswith("/__mtime/"):
                abspath, _ = self._resolve(path[len("/__mtime"):])
                try:
                    mt = os.path.getmtime(abspath) if abspath else 0
                except OSError:
                    mt = 0
                self._send(200, str(mt), "text/plain; charset=utf-8")
                return

            abspath, rel = self._resolve(path)
            if abspath is None:
                self._send(403, "<p>Forbidden</p>")
                return
            if not os.path.exists(abspath):
                self._send(404, "<p>Not found: {}</p>".format(html.escape("/" + rel)))
                return

            if os.path.isdir(abspath):
                page = PAGE.format(
                    title=html.escape("/" + rel.strip("/") or "root"),
                    css=CSS, live="false", mtime_url="''",
                    body=dir_listing(abspath, rel),
                )
                self._send(200, page)
                return

            if is_markdown(abspath):
                mtime_url = "'/__mtime/" + urllib.parse.quote(rel) + "'"
                page = PAGE.format(
                    title=html.escape(os.path.basename(abspath)),
                    css=CSS, live="true", mtime_url=mtime_url,
                    body=render_markdown(abspath),
                )
                self._send(200, page)
                return

            # any other file: serve raw (images, etc.)
            ctype = mimetypes.guess_type(abspath)[0] or "application/octet-stream"
            try:
                with open(abspath, "rb") as f:
                    self._send(200, f.read(), ctype)
            except OSError as e:
                self._send(500, "<p>{}</p>".format(html.escape(str(e))))

    return Handler


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--port", type=int, default=6419)
    ap.add_argument("--host", default="127.0.0.1")
    args = ap.parse_args()

    root = os.path.realpath(args.root)
    srv = ThreadingHTTPServer((args.host, args.port), make_handler(root))
    print("serving {} on http://{}:{}".format(root, args.host, args.port), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
