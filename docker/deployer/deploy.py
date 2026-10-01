#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Deploy-Dienst der IT-Wissensdatenbank.

Fragt den Branch im Gitea-Repository regelmäßig ab (nur lesend, kein eingehender
Netzwerkzugriff, keine Shell-Befehle aus dem Netz). Bei einem neuen Commit:

  1. Commit-Stand exportieren (git archive)
  2. mkdocs build --strict in ein neues Release-Verzeichnis
  3. nur bei Erfolg: Redaktionsoberfläche (admin/) ergänzen und den Symlink
     /srv/site/current atomar auf das neue Release umstellen
  4. bei Fehler: Live-Version bleibt unverändert, Fehlerprotokoll unter /admin/build/

Aufruf:
  deploy.py            Dauerbetrieb (Polling)
  deploy.py --once     einmal prüfen/bauen und beenden (Exit-Code 1 bei Fehler)
  deploy.py --force    aktuellen Stand neu bauen, auch wenn er schon live ist
  deploy.py --list     Releases anzeigen
  deploy.py --rollback <release>   auf ein vorhandenes Release zurückschalten
"""
import base64
import datetime
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ENV = os.environ.get
GITEA_INTERNAL_URL = ENV("GITEA_INTERNAL_URL", "http://gitea:3000").rstrip("/")
GITEA_REPO = ENV("GITEA_REPO", "it-team/it-wiki")
BRANCH = ENV("GITEA_BRANCH", "main")
DEPLOY_USER = ENV("GITEA_DEPLOY_USER", "")
DEPLOY_TOKEN = ENV("GITEA_DEPLOY_TOKEN", "")
REMOTE = ENV("GIT_REMOTE_URL") or f"{GITEA_INTERNAL_URL}/{GITEA_REPO}.git"
POLL = int(ENV("POLL_INTERVAL", "30"))
KEEP = max(3, int(ENV("KEEP_RELEASES", "10")))
BUILD_TIMEOUT = int(ENV("BUILD_TIMEOUT", "600"))
COMMIT_STATUS = ENV("GITEA_COMMIT_STATUS", "false").lower() == "true"
PLACEHOLDERS = {
    "__WIKI_URL__": ENV("WIKI_URL", "").rstrip("/"),
    "__GITEA_URL__": ENV("GITEA_URL", "").rstrip("/"),
    "__GITEA_REPO__": GITEA_REPO,
    "__OAUTH_CLIENT_ID__": ENV("OAUTH_CLIENT_ID", ""),
}
DECAP_JS = ENV("DECAP_JS", "/opt/decap/decap-cms.js")
# Decap CMS verweigert die OAuth-Anmeldung über http:// (außer localhost). Für den Betrieb unter
# http://SERVER-IP:8080/admin/ wird diese eine Prüfung entfernt. Bei HTTPS: DECAP_HTTP_LOGIN=false.
DECAP_HTTP_LOGIN = ENV("DECAP_HTTP_LOGIN", "true").lower() == "true"
INSECURE_CHECK = re.compile(r'return"https:"!==document\.location\.protocol&&"localhost"!==document\.location\.hostname&&"127\.0\.0\.1"!==document\.location\.hostname')

SITE = ENV("SITE_DIR", "/srv/site")
WORK = ENV("WORK_DIR", "/work")
RELEASES = os.path.join(SITE, "releases")
STATUS = os.path.join(SITE, "_status")
LOGS = os.path.join(STATUS, "logs")
STATE_FILE = os.path.join(STATUS, "state.json")
MIRROR = os.path.join(WORK, "repo.git")


def now():
    return datetime.datetime.now().astimezone()


def say(msg):
    print(f"{now():%Y-%m-%d %H:%M:%S} {msg}", flush=True)


def git_env():
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0", HOME=WORK)
    if DEPLOY_USER and DEPLOY_TOKEN:
        cred = base64.b64encode(f"{DEPLOY_USER}:{DEPLOY_TOKEN}".encode()).decode()
        # Zugangsdaten als Header, nicht in URL/Argumenten (nicht in ps oder Logs sichtbar)
        env.update(GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="http.extraHeader",
                   GIT_CONFIG_VALUE_0=f"Authorization: Basic {cred}")
    return env


def git(*args, cwd=None, check=True, capture=True):
    r = subprocess.run(["git", *args], cwd=cwd, env=git_env(), text=True,
                       stdout=subprocess.PIPE if capture else None, stderr=subprocess.STDOUT, timeout=300)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {args[0]} fehlgeschlagen: {(r.stdout or '').strip()[-500:]}")
    return (r.stdout or "").strip()


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {"live": None, "history": []}


def save_state(state):
    os.makedirs(STATUS, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh, ensure_ascii=False, indent=1)
    os.replace(tmp, STATE_FILE)
    write_status_page(state)


def commit_status(sha, state, desc):
    if not COMMIT_STATUS or not DEPLOY_TOKEN:
        return
    url = f"{GITEA_INTERNAL_URL}/api/v1/repos/{GITEA_REPO}/statuses/{sha}"
    body = json.dumps({"state": state, "context": "wiki-build", "description": desc[:140],
                       "target_url": PLACEHOLDERS["__WIKI_URL__"] + "/admin/build/"}).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "Content-Type": "application/json", "Authorization": f"token {DEPLOY_TOKEN}"})
    try:
        urllib.request.urlopen(req, timeout=10).close()
    except (urllib.error.URLError, OSError) as exc:
        say(f"Hinweis: Commit-Status konnte nicht gesetzt werden ({exc})")


def remote_head():
    out = git("ls-remote", REMOTE, f"refs/heads/{BRANCH}")
    if not out:
        raise RuntimeError(f"Branch '{BRANCH}' nicht gefunden")
    return out.split()[0]


def fetch(sha):
    if not os.path.isdir(MIRROR):
        os.makedirs(WORK, exist_ok=True)
        git("init", "--bare", "-q", MIRROR)
    git("fetch", "-q", "--depth", "50", REMOTE, f"+refs/heads/{BRANCH}:refs/heads/{BRANCH}", cwd=MIRROR)
    git("cat-file", "-e", f"{sha}^{{commit}}", cwd=MIRROR)
    info = git("log", "-1", "--format=%an%x1f%s%x1f%cI", sha, cwd=MIRROR).split("\x1f")
    return {"author": info[0], "message": info[1], "date": info[2]}


def export(sha, dest):
    with tempfile.TemporaryFile() as tmp:
        r = subprocess.run(["git", "archive", "--format=tar", sha], cwd=MIRROR, env=git_env(), stdout=tmp, stderr=subprocess.PIPE)
        if r.returncode != 0:
            raise RuntimeError("git archive fehlgeschlagen: " + r.stderr.decode(errors="replace"))
        tmp.seek(0)
        with tarfile.open(fileobj=tmp) as tar:
            tar.extractall(dest, filter="data")


def add_admin(src_dir, release_dir):
    admin_src = os.path.join(src_dir, "admin")
    if not os.path.isdir(admin_src):
        return "kein admin/-Ordner im Repository"
    admin_dst = os.path.join(release_dir, "admin")
    if os.path.exists(admin_dst):
        shutil.rmtree(admin_dst)
    shutil.copytree(admin_src, admin_dst)
    cfg = os.path.join(admin_dst, "config.yml")
    if os.path.exists(cfg):
        text = open(cfg, encoding="utf-8").read()
        for key, value in PLACEHOLDERS.items():
            text = text.replace(key, value)
        open(cfg, "w", encoding="utf-8").write(text)
    hints = []
    if os.path.exists(DECAP_JS):
        js = open(DECAP_JS, encoding="utf-8").read()
        if DECAP_HTTP_LOGIN:
            js, n = INSECURE_CHECK.subn("return!1", js)
            if n == 0:
                hints.append("HTTP-Anmeldung konnte in decap-cms.js nicht freigeschaltet werden (andere Version?)")
        with open(os.path.join(admin_dst, "decap-cms.js"), "w", encoding="utf-8") as fh:
            fh.write(js)
    else:
        hints.append(f"{DECAP_JS} fehlt")
    missing = [k for k, v in PLACEHOLDERS.items() if not v]
    if missing:
        hints.append("Fehlende Werte in .env: " + ", ".join(missing))
    return "; ".join(hints)


def switch_live(release):
    link_tmp = os.path.join(SITE, ".current.tmp")
    if os.path.lexists(link_tmp):
        os.remove(link_tmp)
    os.symlink(os.path.join("releases", release), link_tmp)
    os.replace(link_tmp, os.path.join(SITE, "current"))  # atomar


def current_release():
    link = os.path.join(SITE, "current")
    return os.path.basename(os.readlink(link)) if os.path.islink(link) else None


def cleanup():
    live = current_release()
    rels = sorted(d for d in os.listdir(RELEASES) if not d.endswith(".partial"))
    for old in rels[:-KEEP]:
        if old != live:
            shutil.rmtree(os.path.join(RELEASES, old), ignore_errors=True)
    for d in os.listdir(RELEASES):
        if d.endswith(".partial"):
            shutil.rmtree(os.path.join(RELEASES, d), ignore_errors=True)
    logs = sorted(os.listdir(LOGS))
    for old in logs[:-50]:
        os.remove(os.path.join(LOGS, old))


def build(sha, state):
    os.makedirs(RELEASES, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    stamp = now().strftime("%Y%m%d-%H%M%S")
    release = f"{stamp}-{sha[:10]}"
    log_name = f"{release}.log"
    log_path = os.path.join(LOGS, log_name)
    entry = {"zeit": now().isoformat(timespec="seconds"), "commit": sha, "release": release, "log": log_name}
    commit_status(sha, "pending", "Wiki wird gebaut")
    started = time.time()
    with open(log_path, "w", encoding="utf-8") as logfh:
        def logline(text):
            logfh.write(text.rstrip() + "\n")
            logfh.flush()
        ok = False
        workdir = tempfile.mkdtemp(prefix="build-", dir=WORK)
        partial = os.path.join(RELEASES, release + ".partial")
        try:
            meta = fetch(sha)
            entry.update(meta)
            logline(f"Commit {sha}\nAutor: {meta['author']}\nNachricht: {meta['message']}\n")
            export(sha, workdir)
            cmd = ["mkdocs", "build", "--strict", "--clean", "-f", os.path.join(workdir, "mkdocs.yml"), "-d", partial]
            logline("$ mkdocs build --strict\n")
            r = subprocess.run(cmd, cwd=workdir, stdout=logfh, stderr=subprocess.STDOUT, timeout=BUILD_TIMEOUT,
                               env=dict(os.environ, NO_MKDOCS_2_WARNING="1"))
            if r.returncode != 0:
                raise RuntimeError(f"mkdocs build --strict ist fehlgeschlagen (Exit-Code {r.returncode})")
            if not os.path.exists(os.path.join(partial, "index.html")):
                raise RuntimeError("Build ohne index.html – Veröffentlichung abgebrochen")
            hint = add_admin(workdir, partial)
            if hint:
                logline("Hinweis: " + hint)
            os.rename(partial, os.path.join(RELEASES, release))
            switch_live(release)
            ok = True
            logline(f"\nERFOLG: Release {release} ist live.")
        except subprocess.TimeoutExpired:
            logline(f"\nFEHLER: Zeitlimit von {BUILD_TIMEOUT} s überschritten. Live-Version unverändert.")
            entry["fehler"] = "Zeitlimit überschritten"
        except Exception as exc:  # noqa: BLE001
            logline(f"\nFEHLER: {exc}\nDie bisherige Live-Version bleibt online.")
            entry["fehler"] = str(exc)
        finally:
            shutil.rmtree(workdir, ignore_errors=True)
            if os.path.exists(partial):
                shutil.rmtree(partial, ignore_errors=True)
    entry["ergebnis"] = "erfolgreich" if ok else "fehlgeschlagen"
    entry["dauer_s"] = round(time.time() - started, 1)
    state.setdefault("history", []).insert(0, entry)
    state["history"] = state["history"][:50]
    state["last_built"] = sha
    if ok:
        state["live"] = {"commit": sha, "release": release, "seit": entry["zeit"]}
    save_state(state)
    commit_status(sha, "success" if ok else "failure",
                  "Veröffentlicht" if ok else "Build fehlgeschlagen – alte Version bleibt online")
    try:
        cleanup()
    except OSError:
        pass
    say(f"Build {release}: {entry['ergebnis']}" + ("" if ok else f" – {entry.get('fehler')}"))
    return ok


def write_status_page(state):
    live = state.get("live") or {}
    rows = []
    for e in state.get("history", [])[:30]:
        cls = "ok" if e.get("ergebnis") == "erfolgreich" else "err"
        rows.append(
            f"<tr class='{cls}'><td>{html.escape(e.get('zeit', '')[:19].replace('T', ' '))}</td>"
            f"<td><code>{html.escape(e.get('commit', '')[:10])}</code></td>"
            f"<td>{html.escape(e.get('author', ''))}</td><td>{html.escape(e.get('message', ''))}</td>"
            f"<td>{html.escape(e.get('ergebnis', ''))}</td>"
            f"<td><a href='logs/{html.escape(e.get('log', ''))}'>Protokoll</a></td></tr>")
    page = f"""<!doctype html><html lang="de"><head><meta charset="utf-8"><meta name="robots" content="noindex">
<meta http-equiv="refresh" content="30"><title>Build-Status – IT-Wissensdatenbank</title>
<style>body{{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:2rem;color:#222}}table{{border-collapse:collapse;width:100%}}
td,th{{border-bottom:1px solid #ddd;padding:.4rem .6rem;text-align:left;font-size:.9rem}}tr.ok td:nth-child(5){{color:#1b7f3b;font-weight:600}}
tr.err td:nth-child(5){{color:#c62828;font-weight:600}}code{{background:#f3f3f3;padding:0 .3em}}</style></head><body>
<h1>Build-Status</h1>
<p>Live: Commit <code>{html.escape(str(live.get('commit', '–'))[:10])}</code> seit {html.escape(str(live.get('seit', '–'))[:19].replace('T', ' '))}
 · <a href="../">zur Redaktion</a> · <a href="../../">zum Wiki</a></p>
<p>Nur erfolgreiche Builds werden veröffentlicht. Bei Fehlern bleibt die vorherige Version online; die Ursache steht im Protokoll.</p>
<table><tr><th>Zeit</th><th>Commit</th><th>Autor</th><th>Änderung</th><th>Ergebnis</th><th></th></tr>
{''.join(rows) or '<tr><td colspan=6>Noch keine Builds.</td></tr>'}</table></body></html>"""
    tmp = os.path.join(STATUS, ".index.html.tmp")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(page)
    os.replace(tmp, os.path.join(STATUS, "index.html"))


def check_once(force=False):
    state = load_state()
    sha = remote_head()
    live = (state.get("live") or {}).get("commit")
    if not force and state.get("rollback_head"):
        if sha == state["rollback_head"]:
            return True  # Rollback aktiv – erst ein neuer Commit wird wieder veröffentlicht
        state.pop("rollback_head", None)
    if not force:
        if sha == live and current_release():
            return True
        if sha == state.get("last_built") and sha != live:
            return False  # dieser Stand ist bereits fehlgeschlagen – auf neuen Commit warten
    say(f"Neuer Stand {sha[:10]} – baue Wiki")
    return build(sha, state)


def main(argv):
    os.makedirs(WORK, exist_ok=True)
    os.makedirs(RELEASES, exist_ok=True)
    os.makedirs(LOGS, exist_ok=True)
    if not os.path.exists(os.path.join(STATUS, "index.html")):
        write_status_page(load_state())
    if "--list" in argv:
        live = current_release()
        for r in sorted(os.listdir(RELEASES)):
            print(("* " if r == live else "  ") + r)
        return 0
    if "--rollback" in argv:
        target = argv[argv.index("--rollback") + 1]
        if not os.path.isdir(os.path.join(RELEASES, target)):
            print(f"Release {target} nicht gefunden (siehe --list)")
            return 2
        switch_live(target)
        state = load_state()
        state["live"] = {"commit": target.split("-")[-1], "release": target, "seit": now().isoformat(timespec="seconds"),
                         "rollback": True}
        try:
            state["rollback_head"] = remote_head()
        except Exception:  # noqa: BLE001
            state["rollback_head"] = state.get("last_built")
        save_state(state)
        say(f"Rollback: {target} ist live. Erst der nächste neue Commit in Gitea wird wieder automatisch veröffentlicht.")
        return 0
    if "--once" in argv or "--force" in argv:
        try:
            return 0 if check_once(force="--force" in argv) else 1
        except Exception as exc:  # noqa: BLE001
            say(f"FEHLER: {exc}")
            return 1
    say(f"Deploy-Dienst gestartet: {REMOTE} ({BRANCH}), Intervall {POLL} s")
    while True:
        try:
            check_once()
        except Exception as exc:  # noqa: BLE001
            say(f"Abfrage fehlgeschlagen: {exc}")
        time.sleep(POLL)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
