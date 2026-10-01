# -*- coding: utf-8 -*-
"""
MkDocs-Hook für die Browser-Redaktion (Decap CMS).

1. Navigation: Seiten, die nicht in der festen `nav:` aus mkdocs.yml stehen
   (z. B. neue Beiträge aus Decap CMS), werden automatisch im passenden Bereich
   ergänzt. Die bestehende Navigation bleibt unverändert; neue Einträge werden
   nur angehängt. Autoren müssen mkdocs.yml nie bearbeiten.

2. Darstellung: Seiten mit `vorlage: anleitung|troubleshooting|runbook|standard`
   im Frontmatter werden beim Build aus den Formularfeldern zu einer
   einheitlichen Markdown-Seite (H1, Steckbrief, H2-Abschnitte) zusammengesetzt.

3. Listen: Der Platzhalter `<!-- cms:liste -->` (oder mit Überschrift
   `<!-- cms:liste titel="…" -->`, erscheint nur bei vorhandenen Beiträgen) wird durch
   eine Tabelle der Editor-Beiträge im selben Ordner ersetzt.

4. Kategorien und eigene Inhaltstypen: Beide werden in der Redaktion gepflegt
   (Dateien unter cms/kategorien/ und cms/inhaltstypen/). Anleitungen werden in
   der Navigation nach Kategorie gruppiert. Beiträge eigener Inhaltstypen
   (docs/inhalte/, `vorlage: beitrag`) erhalten je Inhaltstyp einen eigenen
   Navigationsbereich mit automatisch erzeugter Übersichtsseite.

Alle anderen Seiten werden nicht verändert.
"""
import datetime
import logging
import os
import posixpath
import re

import yaml
from mkdocs.plugins import event_priority
from mkdocs.structure.files import File
from mkdocs.utils.meta import get_data

log = logging.getLogger("mkdocs.hooks.wiki_cms")

VORLAGEN = {
    "anleitung": "Anleitung",
    "troubleshooting": "Troubleshooting",
    "runbook": "Runbook",
    "standard": "Standard",
    "beitrag": "Beitrag",
}
STANDARD_BEREICH = {"troubleshooting": "Troubleshooting", "runbook": "Runbooks", "standard": "Standards"}

# eigene Inhaltstypen
INHALTE_ORDNER = "inhalte"            # docs/inhalte/<slug>.md
UEBERSICHT_ORDNER = "inhaltstypen"    # erzeugte Übersichtsseiten: inhaltstypen/<typ>.md
OHNE_KATEGORIE = "Allgemein"
_generated = {}                       # src_uri -> Markdown der erzeugten Übersichtsseiten

# Titel für Bereiche, die in der festen Navigation noch nicht existieren
NEUE_BEREICHE = {"anleitungen": "Anleitungen"}
# neue Bereiche werden vor diesem Navigationspunkt eingefügt
EINFUEGEN_VOR = "Troubleshooting"

# Ordner, deren Seiten nie automatisch in die Navigation kommen
IGNORIEREN = ("admin/",)

_meta_cache = {}


def _read_meta(path):
    if path not in _meta_cache:
        try:
            with open(path, encoding="utf-8-sig") as fh:
                _, meta = get_data(fh.read())
        except OSError:
            meta = {}
        _meta_cache[path] = meta or {}
    return _meta_cache[path]


def _slug(text):
    t = str(text or "").lower()
    for a, b in (("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")):
        t = t.replace(a, b)
    t = re.sub(r"[^a-z0-9]+", "-", t).strip("-")
    return t or "ohne-name"


def _load_yaml_dir(path):
    items = []
    if not os.path.isdir(path):
        return items
    for name in sorted(os.listdir(path)):
        if not name.endswith((".yml", ".yaml")):
            continue
        try:
            with open(os.path.join(path, name), encoding="utf-8-sig") as fh:
                data = yaml.safe_load(fh) or {}
        except (OSError, yaml.YAMLError) as exc:
            log.warning("Redaktion: %s/%s ist fehlerhaft und wird ignoriert (%s)", path, name, exc)
            continue
        if isinstance(data, dict) and str(data.get("title") or "").strip():
            data["_datei"] = posixpath.splitext(name)[0]
            items.append(data)
    return items


def _sort_key(item):
    try:
        order = int(item.get("reihenfolge") or 100)
    except (TypeError, ValueError):
        order = 100
    return (order, str(item.get("title")).lower())


def _kategorie_order(cms_dir):
    return {str(k["title"]).strip(): i for i, k in enumerate(sorted(_load_yaml_dir(os.path.join(cms_dir, "kategorien")), key=_sort_key))}


def _group_by_kategorie(entries, order):
    """entries: [(rel, meta)] -> Navigationsliste, nach Kategorie gruppiert."""
    groups = {}
    for rel, meta in entries:
        groups.setdefault(str(meta.get("kategorie") or "").strip(), []).append((rel, meta))
    out = []
    for name in sorted(groups, key=lambda n: (n == "", order.get(n, 999), n.lower())):
        pages = [{str(m.get("title") or posixpath.basename(r)): r} for r, m in sorted(groups[name], key=lambda x: str(x[1].get("title") or "").lower())]
        if name:
            out.append({name: pages})
        else:
            out.extend(pages)
    return out


def _insert_before(nav, title, entry):
    for i, item in enumerate(nav):
        if isinstance(item, dict) and title in item:
            nav.insert(i, entry)
            return
    nav.append(entry)


# --------------------------------------------------------------------------- Navigation
def _nav_paths(items, out):
    for item in items or []:
        if isinstance(item, str):
            out.add(item)
        elif isinstance(item, dict):
            for value in item.values():
                if isinstance(value, str):
                    out.add(value)
                elif isinstance(value, list):
                    _nav_paths(value, out)
    return out


def _find_section(items, index_path):
    """Liste (Abschnitt) finden, die `index_path` direkt enthält."""
    for item in items or []:
        if isinstance(item, dict):
            for value in item.values():
                if isinstance(value, list):
                    if index_path in value:
                        return value
                    found = _find_section(value, index_path)
                    if found is not None:
                        return found
    return None


def _title_for(docs_dir, rel):
    meta = _read_meta(os.path.join(docs_dir, rel))
    title = str(meta.get("title") or "").strip()
    if not title:
        title = posixpath.splitext(posixpath.basename(rel))[0].replace("-", " ").capitalize()
    return title


@event_priority(100)
def on_config(config):
    _meta_cache.clear()
    nav = config.get("nav")
    if not nav:
        return config  # automatische Navigation von MkDocs – nichts zu tun
    docs_dir = config["docs_dir"]
    cms_dir = os.path.join(os.path.dirname(config["config_file_path"]), "cms")
    _generated.clear()
    known = _nav_paths(nav, set())
    kat_order = _kategorie_order(cms_dir)

    # --- Editor-Seiten einsammeln
    anleitungen, beitraege = [], []
    for folder, bucket, vorlage in (("anleitungen", anleitungen, "anleitung"), (INHALTE_ORDNER, beitraege, "beitrag")):
        path = os.path.join(docs_dir, folder)
        if not os.path.isdir(path):
            continue
        for name in sorted(os.listdir(path)):
            rel = f"{folder}/{name}"
            if name.endswith(".md") and name != "index.md" and rel not in known:
                meta = _read_meta(os.path.join(docs_dir, rel))
                if meta.get("vorlage") == vorlage:
                    bucket.append((rel, meta))
                    known.add(rel)

    # --- Anleitungen: eigener Bereich, nach Kategorie gruppiert
    if anleitungen or os.path.exists(os.path.join(docs_dir, "anleitungen", "index.md")):
        section = _find_section(nav, "anleitungen/index.md")
        if section is None:
            section = []
            if "anleitungen/index.md" not in known and os.path.exists(os.path.join(docs_dir, "anleitungen", "index.md")):
                section.append("anleitungen/index.md")
                known.add("anleitungen/index.md")
            _insert_before(nav, EINFUEGEN_VOR, {NEUE_BEREICHE["anleitungen"]: section})
        section.extend(_group_by_kategorie(anleitungen, kat_order))

    # --- Eigene Inhaltstypen: je Typ ein Bereich mit erzeugter Übersichtsseite
    typen = {str(t["title"]).strip(): t for t in _load_yaml_dir(os.path.join(cms_dir, "inhaltstypen"))}
    nach_typ = {}
    for rel, meta in beitraege:
        name = str(meta.get("inhaltstyp") or "").strip() or "Weitere Inhalte"
        nach_typ.setdefault(name, []).append((rel, meta))
        typen.setdefault(name, {"title": name})
    for name in sorted(nach_typ, key=lambda n: _sort_key(typen[n])):
        typ = typen[name]
        entries = nach_typ[name]
        titel = str(typ.get("mehrzahl") or name).strip()
        uri = f"{UEBERSICHT_ORDNER}/{_slug(typ.get('_datei') or name)}.md"
        _generated[uri] = _uebersicht(titel, typ, entries)
        section = [uri] + _group_by_kategorie(entries, kat_order)
        if str(typ.get("position") or "").startswith("Am Ende"):
            _insert_before(nav, "Tags", {titel: section})
        else:
            _insert_before(nav, EINFUEGEN_VOR, {titel: section})
        log.info("Navigation: Inhaltstyp '%s' mit %d Beiträgen", titel, len(entries))

    missing = []
    for root, dirs, files in os.walk(docs_dir):
        dirs[:] = sorted(d for d in dirs if not d.startswith("."))
        for name in sorted(files):
            if not name.endswith(".md") or name.startswith("."):
                continue
            rel = os.path.relpath(os.path.join(root, name), docs_dir).replace(os.sep, "/")
            if rel in known or rel.startswith(IGNORIEREN):
                continue
            missing.append(rel)
    if not missing:
        config["nav"] = nav
        return config

    # Index-Seiten zuerst, dann nach Titel
    missing.sort(key=lambda r: (posixpath.dirname(r), not r.endswith("index.md"), _title_for(docs_dir, r).lower()))
    for rel in missing:
        folder = posixpath.dirname(rel)
        section = None
        # tiefsten vorhandenen Abschnitt mit index.md suchen
        probe = folder
        while probe and section is None:
            section = _find_section(nav, probe + "/index.md")
            probe = posixpath.dirname(probe)
        if section is None and folder:
            top = folder.split("/")[0]
            title = NEUE_BEREICHE.get(top, top.replace("-", " ").title())
            section = []
            pos = len(nav)
            for i, item in enumerate(nav):
                if isinstance(item, dict) and EINFUEGEN_VOR in item:
                    pos = i
                    break
            nav.insert(pos, {title: section})
            log.info("Navigation: neuer Bereich '%s'", title)
        if section is None:
            section = nav
        if rel.endswith("index.md"):
            section.insert(0, rel)
        else:
            section.append({_title_for(docs_dir, rel): rel})
        log.info("Navigation: %s ergänzt", rel)
    config["nav"] = nav
    return config


def _uebersicht(titel, typ, entries):
    lines = [f"# {titel}", ""]
    if typ.get("beschreibung"):
        lines += [str(typ["beschreibung"]).strip(), ""]
    lines += ["| Seite | Kategorie | Verantwortlich | Zuletzt geprüft |", "|---|---|---|---|"]
    for rel, meta in sorted(entries, key=lambda x: str(x[1].get("title") or "").lower()):
        suffix = " (archiviert)" if meta.get("archiviert") else ""
        link = posixpath.relpath(rel, UEBERSICHT_ORDNER)
        lines.append(f"| [{_cell(meta.get('title'))}]({link}){suffix} | {_cell(meta.get('kategorie'))} | "
                     f"{_cell(meta.get('verantwortlich'))} | {_cell(meta.get('zuletzt_geprueft'))} |")
    return "\n".join(lines) + "\n"


def on_files(files, config):
    for uri, content in _generated.items():
        if files.get_file_from_path(uri) is None:
            files.append(File.generated(config, uri, content=content))
    return files


# --------------------------------------------------------------------------- Darstellung
def _txt(value):
    if value is None:
        return ""
    if isinstance(value, (datetime.date, datetime.datetime)):
        return value.strftime("%d.%m.%Y")
    s = str(value).strip()
    try:  # ISO-Datum aus dem Editor
        return datetime.date.fromisoformat(s[:10]).strftime("%d.%m.%Y") if len(s) >= 10 and s[4] == "-" else s
    except ValueError:
        return s


def _cell(value):
    return _txt(value).replace("|", "\\|").replace("\n", " ")


def _section(title, content):
    content = (content or "").strip() if isinstance(content, str) else content
    if not content:
        return ""
    return f"## {title}\n\n{content}\n"


def _list(values):
    if isinstance(values, str):
        values = [values]
    return [v for v in (values or []) if v]


def _steckbrief(rows):
    rows = [(k, v) for k, v in rows if _txt(v)]
    if not rows:
        return ""
    lines = ['!!! info "Steckbrief"', ""]
    lines += [f"    - **{k}:** {_cell(v)}" for k, v in rows]
    return "\n".join(lines) + "\n"


def _bilder(meta):
    out = []
    for i, item in enumerate(_list(meta.get("bilder")), 1):
        if isinstance(item, dict):
            src, cap = item.get("bild"), (item.get("beschriftung") or "").strip()
        else:
            src, cap = item, ""
        if not src:
            continue
        alt = cap or f"Abbildung {i}"
        out.append(f"![{alt}]({src})")
        if cap:
            out.append(f"\nAbbildung {i}: {cap}")
        out.append("")
    return "\n".join(out).strip()


def _verwandte(meta, page_dir, docs_dir):
    lines = []
    for key, folder in (("verwandte_anleitungen", "anleitungen"), ("verwandte_troubleshooting", "troubleshooting")):
        for slug in _list(meta.get(key)):
            target = f"{folder}/{slug}.md"
            title = _title_for(docs_dir, target) if os.path.exists(os.path.join(docs_dir, target)) else slug
            lines.append(f"- [{title}]({posixpath.relpath(target, page_dir or '.')})")
    for link in _list(meta.get("weitere_links")):
        if isinstance(link, dict) and link.get("url"):
            lines.append(f"- [{link.get('text') or link['url']}]({link['url']})")
    return "\n".join(lines)


def _render(vorlage, meta, body, page_dir, docs_dir):
    title = str(meta.get("title") or "").strip()
    parts = [f"# {title}", ""]
    if meta.get("archiviert"):
        parts += ['!!! warning "Archiviert"', "    Dieser Beitrag ist archiviert und wird nicht mehr gepflegt.", ""]
    if meta.get("beschreibung"):
        parts += [str(meta["beschreibung"]).strip(), ""]
    sys_ = ", ".join(_list(meta.get("betroffene_systeme")))
    if vorlage == "anleitung":
        parts.append(_steckbrief([("Kategorie", meta.get("kategorie")), ("Verantwortlich", meta.get("verantwortlich")),
                                  ("Zuletzt geprüft", meta.get("zuletzt_geprueft"))]))
        parts += [_section("Voraussetzungen", meta.get("voraussetzungen")),
                  _section("Anleitung", body),
                  _section("Screenshots", _bilder(meta)),
                  _section("Prüfung / Erfolgskontrolle", meta.get("pruefung")),
                  _section("Troubleshooting", meta.get("troubleshooting")),
                  _section("Verwandte Artikel", _verwandte(meta, page_dir, docs_dir))]
    elif vorlage == "troubleshooting":
        parts.append(_steckbrief([("Kategorie", meta.get("kategorie")), ("Betroffene Systeme", sys_), ("Verantwortlich", meta.get("verantwortlich")),
                                  ("Zuletzt geprüft", meta.get("zuletzt_geprueft"))]))
        parts += [_section("Symptome", meta.get("symptome")),
                  _section("Ursache", meta.get("ursache")),
                  _section("Lösung", body),
                  _section("Screenshots", _bilder(meta)),
                  _section("Prüfschritte", meta.get("pruefschritte")),
                  _section("Eskalation", meta.get("eskalation"))]
    elif vorlage == "runbook":
        parts.append(_steckbrief([("Kategorie", meta.get("kategorie")), ("Auswirkung/Risiko", meta.get("risiko_stufe")), ("Verantwortlich", meta.get("verantwortlich")),
                                  ("Zuletzt geprüft", meta.get("zuletzt_geprueft"))]))
        parts += [_section("Zweck", meta.get("zweck")),
                  _section("Auswirkung / Risiko", meta.get("risiko")),
                  _section("Voraussetzungen", meta.get("voraussetzungen")),
                  _section("Vorgehen", body),
                  _section("Screenshots", _bilder(meta)),
                  _section("Rollback", meta.get("rollback")),
                  _section("Prüfung", meta.get("pruefung"))]
    elif vorlage == "standard":
        parts.append(_steckbrief([("Kategorie", meta.get("kategorie")), ("Geltungsbereich", meta.get("geltungsbereich")), ("Verantwortlich", meta.get("verantwortlich")),
                                  ("Gültig ab", meta.get("gueltig_ab")), ("Zuletzt geprüft", meta.get("zuletzt_geprueft"))]))
        parts += [_section("Ziel", meta.get("ziel")),
                  _section("Inhalt", body),
                  _section("Screenshots", _bilder(meta))]
    elif vorlage == "beitrag":
        angaben = [(str(a.get("bezeichnung") or "").strip(), a.get("wert")) for a in _list(meta.get("angaben")) if isinstance(a, dict)]
        parts.append(_steckbrief([("Inhaltstyp", meta.get("inhaltstyp")), ("Kategorie", meta.get("kategorie"))] + [a for a in angaben if a[0]]
                                 + [("Verantwortlich", meta.get("verantwortlich")), ("Zuletzt geprüft", meta.get("zuletzt_geprueft"))]))
        parts += [(body or "").strip() + "\n",
                  _section("Screenshots", _bilder(meta)),
                  _section("Verwandte Artikel", _verwandte(meta, page_dir, docs_dir))]
    return "\n".join(p for p in parts if p is not None).rstrip() + "\n"


def _cms_liste(page, files, docs_dir):
    folder = posixpath.dirname(page.file.src_uri)
    rows = []
    for f in files.documentation_pages():
        if posixpath.dirname(f.src_uri) != folder or f.src_uri == page.file.src_uri:
            continue
        meta = _read_meta(f.abs_src_path)
        if meta.get("vorlage") not in VORLAGEN:
            continue
        rows.append((str(meta.get("title") or f.name), posixpath.basename(f.src_uri), meta))
    if not rows:
        return ""
    rows.sort(key=lambda r: r[0].lower())
    out = ["| Seite | Verantwortlich | Zuletzt geprüft |", "|-------|----------------|-----------------|"]
    for title, link, meta in rows:
        suffix = " (archiviert)" if meta.get("archiviert") else ""
        out.append(f"| [{_cell(title)}]({link}){suffix} | {_cell(meta.get('verantwortlich'))} | {_cell(meta.get('zuletzt_geprueft'))} |")
    return "\n".join(out)


LISTE_RE = re.compile(r'<!-- cms:liste(?:\s+titel="([^"]*)")?\s*-->')


@event_priority(100)  # vor dem Tags-Plugin, damit Tags korrekt übernommen werden
def on_page_markdown(markdown, page, config, files):
    meta = page.meta
    vorlage = meta.get("vorlage")
    docs_dir = config["docs_dir"]
    if "<!-- cms:liste" in markdown:
        def _ersetzen(m):
            liste = _cms_liste(page, files, docs_dir)
            titel = m.group(1)
            if not titel:
                return liste or "Noch keine Beiträge aus dem Editor vorhanden."
            # Mit Titel: Abschnitt nur anzeigen, wenn es Beiträge gibt (bestehende Seiten bleiben sonst unverändert)
            return f"## {titel}\n\n{liste}" if liste else ""
        markdown = LISTE_RE.sub(_ersetzen, markdown)
    if vorlage not in VORLAGEN:
        return markdown
    typ = str(meta.get("inhaltstyp") or "").strip() if vorlage == "beitrag" else VORLAGEN[vorlage]
    typ = typ or "Beitrag"
    bereich = meta.get("kategorie") or STANDARD_BEREICH.get(vorlage)
    tags = []
    for t in [bereich, typ] + [str(t) for t in _list(meta.get("tags"))] + (["Archiviert"] if meta.get("archiviert") else []):
        if t and t not in tags:
            tags.append(t)
    meta["tags"] = tags
    meta["inhaltstyp"] = typ
    if meta.get("zuletzt_geprueft"):
        meta.setdefault("geaendert", str(meta["zuletzt_geprueft"])[:10])
    page_dir = posixpath.dirname(page.file.src_uri)
    return _render(vorlage, meta, markdown, page_dir, docs_dir)
