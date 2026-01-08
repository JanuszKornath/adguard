# AdGuard Home Master–Slave Sync Script

Dieses Bash-Skript synchronisiert eine **AdGuard Home Master-Instanz** mit einer oder mehreren **Slave-Instanzen**.

Ziel ist es, Filterlisten und Konfigurationsänderungen zentral zu pflegen, während **slave-spezifische Einstellungen** (z. B. Web-Interface, DNS-Listener, Benutzer) erhalten bleiben.

---

## Funktionsweise

Das Skript führt folgende Schritte aus:

1. **Synchronisation der Filter-Daten**
   - Spiegelung des `data/`-Verzeichnisses per `rsync`
   - Ausschluss von Statistik-, Query- und Logdateien

2. **Übertragung der Master-Konfiguration**
   - Kopiert `AdGuardHome.yaml` vom Master auf den Slave

3. **Konfigurations-Merge auf dem Slave**
   - Beibehaltung der lokalen Sektionen:
     - `http`
     - `dns`
     - `users`
   - Überschreibt alle übrigen Einstellungen mit der Master-Konfiguration

4. **Neustart von AdGuard Home**
   - Automatischer Restart des Dienstes auf dem Slave

---

## Wichtiger Hinweis

Dieses Skript **überschreibt aktiv die Konfiguration** der Slave-Instanz.  
Verwende es nur, wenn du die Auswirkungen verstehst und ein Backup existiert.

---

## Abhängigkeiten

### Auf Master **und** Slave erforderlich:
- `bash`
- `rsync`
- `ssh`
- `yq` **Version 4.x**
- `AdGuardHome`
- `systemd`
