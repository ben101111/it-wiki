---
vorlage: troubleshooting
dateiname: beispiel-outlook-fragt-staendig-nach-kennwort
title: "Beispiel: Outlook fragt ständig nach dem Kennwort"
kategorie: Microsoft 365
betroffene_systeme:
  - Outlook (Microsoft 365 Apps)
  - Windows 10/11
symptome: |-
  Outlook zeigt wiederholt das Anmeldefenster, obwohl das Kennwort korrekt ist. Teilweise bleibt der Status auf „Kennwort erforderlich“.
ursache: |-
  Häufig veraltete oder beschädigte Anmeldeinformationen in der Windows-Anmeldeinformationsverwaltung oder ein abgelaufenes Token nach einer Kennwortänderung.
pruefschritte: |-
  - Status unten rechts in Outlook: „Verbunden mit Microsoft Exchange“.
  - Nach einem Neustart erscheint keine erneute Kennwortabfrage.
eskalation: |-
  Tritt der Fehler bei mehreren Benutzern gleichzeitig auf: Störungsmeldungen im Microsoft 365 Admin Center (Dienststatus) prüfen und an das 2nd-Level-Team übergeben.
verantwortlich: IT-Team
zuletzt_geprueft: 2026-01-01
tags:
  - Beispiel
  - Outlook
archiviert: false
---

1. Outlook schließen.
2. **Anmeldeinformationsverwaltung → Windows-Anmeldeinformationen** öffnen und alle Einträge entfernen, die `MicrosoftOffice`, `Outlook` oder die E-Mail-Adresse enthalten.
3. In einer Office-App unter **Datei → Konto** abmelden und neu anmelden.
4. Outlook starten und mit dem aktuellen Kennwort anmelden.
