---
title: "IT-Wissensdatenbank"
hide:
  - toc
---

# IT-Wissensdatenbank

Zentrale Wissensdatenbank des IT-Teams: Anleitungen, Fehlerlösungen, Runbooks und Standards an einem Ort – durchsuchbar, versioniert und im Browser pflegbar.

!!! tip "Erste Schritte"
    Diese Startseite stammt aus der Vorlage. Passen Sie sie in Gitea an (`docs/index.md`, Stift-Symbol). Neue Beiträge schreiben Sie über den Knopf **Redaktion** oben links. Beiträge, deren Titel mit „Beispiel:“ beginnt, entfernen Sie auf dem Server mit `sudo bash /opt/it-wiki/scripts/cms-install.sh beispiele`.

<div class="grid cards" markdown>

-   **[Anleitungen](anleitungen/index.md)**

    Schritt für Schritt: Installation, Konfiguration, Einrichtung – gruppiert nach Kategorie

-   **[Troubleshooting](troubleshooting/index.md)**

    Fehlerbild, Ursache, Lösung – mit Prüfschritten und Eskalation

-   **[Runbooks](runbooks/index.md)**

    Wiederkehrende und kritische Betriebsabläufe mit Risiko und Rollback

-   **[Standards](standards/index.md)**

    Verbindliche Festlegungen und Richtlinien des IT-Teams

</div>

## So nutzen Sie das Wiki

- **Suche:** Mit ++s++ oder ++slash++ öffnen. Gesucht wird im Volltext aller Seiten, zum Beispiel nach Fehlercodes, KB-Nummern oder Produktnamen.
- **Tags:** Jede Seite trägt Kategorie und Inhaltstyp als Tag. Übersicht unter [Tags](tags.md).
- **Befehle kopieren:** Codeblöcke haben rechts oben eine Kopierschaltfläche.
- **Mitschreiben:** Knopf **Redaktion** oben links – Anmeldung mit dem Gitea-Konto. Regeln stehen in der [Dokumentationsrichtlinie](standards/dokumentationsrichtlinie.md).

!!! warning "Keine Geheimnisse ins Wiki"
    Passwörter, Lizenzschlüssel, Tokens und private Schlüssel gehören in den Passwortmanager. Im Wiki nur darauf verweisen.
