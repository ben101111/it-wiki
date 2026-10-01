---
vorlage: anleitung
dateiname: beispiel-netzlaufwerk-per-gpo-verbinden
title: "Beispiel: Netzlaufwerk per Gruppenrichtlinie verbinden"
kategorie: Windows Server
beschreibung: Laufwerk für eine AD-Gruppe automatisch per Gruppenrichtlinie (Gruppenrichtlinien-Einstellungen) verbinden. Dies ist ein Beispielbeitrag der Vorlage.
voraussetzungen: |-
  - Freigabe ist angelegt, z. B. `\\FILESERVER\Abteilung`
  - Sicherheitsgruppe mit den Benutzern existiert, z. B. `GG-Abteilung`
  - Rechte für die Gruppenrichtlinienverwaltung
pruefung: |-
  Am Client als Mitglied der Gruppe anmelden und ausführen:

  ```powershell
  gpupdate /force
  gpresult /r /scope user
  ```

  Die GPO erscheint unter „Angewendete Gruppenrichtlinienobjekte“, im Explorer ist `S:` verbunden.
troubleshooting: |-
  - Laufwerk fehlt: Ist der Benutzer **direkt oder indirekt** Mitglied der Gruppe? Nach Gruppenänderungen ab- und wieder anmelden.
  - GPO nicht angewendet: Verknüpfung mit der richtigen OU und Sicherheitsfilterung („Authentifizierte Benutzer“ lesen) prüfen.
verwandte_troubleshooting:
  - beispiel-outlook-fragt-staendig-nach-kennwort
verantwortlich: IT-Team
zuletzt_geprueft: 2026-01-01
tags:
  - Beispiel
  - Gruppenrichtlinien
archiviert: false
---

1. **Gruppenrichtlinienverwaltung** (`gpmc.msc`) öffnen.
2. Neue GPO anlegen, z. B. `U-Laufwerke-Abteilung`, und mit der OU der Benutzer verknüpfen.
3. GPO bearbeiten: **Benutzerkonfiguration → Einstellungen → Windows-Einstellungen → Laufwerkszuordnungen**.
4. **Neu → Zugeordnetes Laufwerk**:
    - Aktion: `Aktualisieren`
    - Speicherort: `\\FILESERVER\Abteilung`
    - Laufwerksbuchstabe: `S:`
    - Beschriftung: `Abteilung`
5. Reiter **Gemeinsam → Zielgruppenadressierung auf Elementebene** aktivieren und die Gruppe `GG-Abteilung` auswählen.
6. Mit **OK** speichern.
