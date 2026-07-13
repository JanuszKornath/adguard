# AdGuard Home Master–Slave Sync Script

Dieses Bash-Skript synchronisiert eine **AdGuard Home Master-Instanz** mit einer **Slave-Instanz** (für weitere Slaves das Skript mit angepasster `SLAVE`-Variable mehrfach einrichten).

Ziel ist es, Filterlisten und Konfigurationsänderungen zentral zu pflegen, während **slave-spezifische Einstellungen** (z. B. Web-Interface, DNS-Listener, Benutzer) erhalten bleiben.

---

## Funktionsweise

Das Skript führt folgende Schritte aus:

1. **Synchronisation der Filter-Daten**
   - Spiegelung des `data/`-Verzeichnisses per `rsync`
   - Ausschluss von Statistik-, Query- und Logdateien sowie der
     slave-spezifischen `sessions.db` (Web-Logins) und `leases*` (DHCP)

2. **Übertragung der Master-Konfiguration**
   - Kopiert `AdGuardHome.yaml` vom Master in ein privates
     Temp-Verzeichnis (`mktemp -d`) auf dem Slave

3. **Konfigurations-Merge auf dem Slave**
   - Bricht ab, wenn die `schema_version` von Master und Slave nicht
     übereinstimmt (AdGuardHome-Versionen zuerst angleichen)
   - Beibehaltung der lokalen Einstellungen:
     - `http` (Web-Interface)
     - `users`
     - `schema_version`
     - `dns.bind_host` / `dns.bind_hosts` / `dns.port` (DNS-Listener)
   - Überschreibt alle übrigen Einstellungen mit der Master-Konfiguration
     (auch den Rest der `dns`-Sektion, z. B. Upstream-Server)
   - Die gemergte Config wird erst mit `--check-config` validiert und
     ersetzt die aktive Config nur bei Erfolg

4. **Neustart von AdGuard Home**
   - Automatischer Restart des Dienstes auf dem Slave

Bei Fehlern (auf Master- wie Slave-Seite) wird eine Mail an `root`
geschickt; auf dem Master zusätzlich ins Log `/var/log/adguard-sync.log`
protokolliert.

---

## Wichtiger Hinweis

Dieses Skript **überschreibt aktiv die Konfiguration** der Slave-Instanz.  
Verwende es nur, wenn du die Auswirkungen verstehst und ein Backup existiert.

Der SSH-Benutzer auf dem Slave (`adguard-sync`) benötigt Schreibrechte auf
`/opt/AdGuardHome` sowie das Recht, `systemctl restart AdGuardHome`
auszuführen (z. B. über eine passwortlose sudo-Regel, polkit oder indem der
Sync als `root` läuft — wegen `BatchMode=yes` darf dabei keine
Passwortabfrage entstehen).

---

## Abhängigkeiten

### Auf Master **und** Slave erforderlich:
- `bash`
- `rsync`
- `ssh`
- `yq` **Version 4.x**
- `mail` (z. B. aus `mailutils` oder `s-nail`)
- `AdGuardHome`
- `systemd`
