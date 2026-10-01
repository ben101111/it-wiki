---
vorlage: runbook
dateiname: beispiel-monatlicher-patchday
title: "Beispiel: Monatlicher Patchday Windows Server"
kategorie: Windows Server
zweck: |-
  Monatliche Windows-Updates auf allen Servern geordnet installieren, ohne dass Dienste unnötig ausfallen.
risiko_stufe: Mittel
risiko: |-
  Neustarts unterbrechen Anmeldung, Dateizugriff und Fachanwendungen für einige Minuten. Fehlerhafte Updates können Dienste beeinträchtigen.
voraussetzungen: |-
  - Wartungsfenster mit den Fachabteilungen abgestimmt
  - Aktuelle, geprüfte Sicherung aller Server
  - Bekannte Probleme der aktuellen Updates geprüft (Release Health)
rollback: |-
  Problematisches Update deinstallieren:

  ```powershell
  Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5
  wusa /uninstall /kb:NUMMER /norestart
  ```

  Reicht das nicht: Server aus der Sicherung wiederherstellen.
pruefung: |-
  - Dienste mit Starttyp „Automatisch“ laufen: `Get-Service | Where-Object {$_.StartType -eq 'Automatic' -and $_.Status -ne 'Running'}`
  - Anmeldung, Netzlaufwerke und Fachanwendungen stichprobenartig testen
  - Ereignisanzeige auf neue kritische Fehler prüfen
verantwortlich: IT-Team
zuletzt_geprueft: 2026-01-01
tags:
  - Beispiel
  - Updates
archiviert: false
---

1. Benutzer über das Wartungsfenster informieren.
2. Server in dieser Reihenfolge aktualisieren und neu starten:
    1. Anwendungs- und Terminalserver
    2. Dateiserver
    3. zweiter Domänencontroller
    4. erster Domänencontroller
3. Nach jedem Neustart die Prüfung (unten) durchführen, erst dann den nächsten Server starten.
