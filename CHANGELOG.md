# Changelog

## 1.0.0 – 2026-10-01

Erste öffentliche Version.

- Wiki auf Basis von MkDocs Material mit Suche, Tags, hellem und dunklem Design
- Redaktion im Browser (Decap CMS 3.16) mit Formularen für Anleitung, Troubleshooting, Runbook und Standard
- Kategorien und eigene Inhaltstypen in der Redaktion pflegbar
- Gitea 1.27 (rootless) als lokales Git-Backend mit OAuth-Anmeldung
- Deploy-Dienst: `mkdocs build --strict`, atomare Releases, Rollback, Build-Status unter `/admin/build/`
- Installationsskript mit `install`, `update`, `adressen`, `backup`, `editor`, `beispiele`, `test`, `uninstall`
- Zugriff über IP oder eigene Domains hinter einem Reverse Proxy
- Knöpfe „Redaktion“ und „Git“ in der Kopfzeile
- Beispielbeiträge für alle Inhaltstypen, bei der Installation wählbar (mit Beispielen oder leer)
