# AdGuard Home Master–Slave Sync Script

Dieses Bash-Skript synchronisiert eine **AdGuard Home Master-Instanz** mit einer **Slave-Instanz** (für weitere Slaves das Skript mit angepasster `SLAVE`-Variable mehrfach einrichten).

Ziel ist es, Filterlisten und Konfigurationsänderungen zentral zu pflegen, während **slave-spezifische Einstellungen** (z. B. Web-Interface, DNS-Listener, Benutzer) erhalten bleiben.

---

## Funktionsweise

Das Skript führt folgende Schritte aus:

0. **Besitz auf dem Slave herstellen**
   - `sudo -n chown` auf `data/`, `AdGuardHome.yaml` und
     `AdGuardHome.yaml.backup` zum User `adguard-sync`
     (siehe [Warum der chown am Anfang?](#warum-der-chown-am-anfang))

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
   - Restart des Dienstes auf dem Slave per `sudo -n systemctl restart`
   - Schlägt der Neustart fehl, wird das Backup zurückgespielt und
     erneut gestartet

Bei Fehlern (auf Master- wie Slave-Seite) wird eine Mail an `root`
geschickt; auf dem Master zusätzlich ins Log
`/var/log/adguard/adguard-sync.log` protokolliert.

---

## Wichtiger Hinweis

Dieses Skript **überschreibt aktiv die Konfiguration** der Slave-Instanz.  
Verwende es nur, wenn du die Auswirkungen verstehst und ein Backup existiert.

**Bei Master-Ausfall:** Änderungen, die direkt auf dem Slave gemacht werden,
überschreibt der nächste Sync — ausgenommen `http`, `users`,
`schema_version` und die DNS-Listener (`dns.bind_host` / `dns.bind_hosts` /
`dns.port`). Solche Änderungen müssen vorher auf den Master übertragen oder
der Cronjob auf dem Master so lange ausgesetzt werden.

---

## Einrichtung

Der Sync läuft auf dem Slave nicht als `root`, sondern als dedizierter User
`adguard-sync`. Root-Rechte bekommt er nur für die exakt freigegebenen
Befehle per sudo.

### Auf dem Slave

1. **User anlegen** (Shell nötig, weil das Skript remote `bash -s` ausführt):

   ```bash
   adduser --disabled-password --gecos "" --shell /bin/bash adguard-sync
   ```

2. **Besitz und Rechte setzen.** Die Backup-Datei muss vorher existieren:
   `adguard-sync` kann in `/opt/AdGuardHome` (Besitz `root`, 755) keine
   neuen Dateien anlegen, und der `chown` in Schritt 0 schlägt bei einer
   fehlenden Datei fehl.

   ```bash
   cd /opt/AdGuardHome
   [ -e AdGuardHome.yaml.backup ] || install -m 600 /dev/null AdGuardHome.yaml.backup
   chown -R adguard-sync:adguard-sync data
   chown adguard-sync:adguard-sync AdGuardHome.yaml AdGuardHome.yaml.backup
   chmod 755 /opt/AdGuardHome   # nicht 777
   ```

   Die übrigen Rechte bleiben wie von AdGuardHome gesetzt (600 für Dateien,
   700 für Verzeichnisse).

3. **sudo-Regeln** in `/etc/sudoers.d/adguard-sync` (Mode 440), anschließend
   mit `visudo -cf /etc/sudoers.d/adguard-sync` prüfen:

   ```
   adguard-sync ALL=(root) NOPASSWD: /usr/bin/systemctl restart AdGuardHome
   adguard-sync ALL=(root) NOPASSWD: /usr/bin/chown adguard-sync\:adguard-sync /opt/AdGuardHome/AdGuardHome.yaml /opt/AdGuardHome/AdGuardHome.yaml.backup
   adguard-sync ALL=(root) NOPASSWD: /usr/bin/chown -R adguard-sync\:adguard-sync /opt/AdGuardHome/data
   ```

   Der Doppelpunkt muss in sudoers escaped werden. Die Regeln erwarten exakt
   diese Argumente — deshalb ist der User im Skript hart codiert und wird
   nicht aus `SLAVE` abgeleitet.

4. **sshd** (`/etc/ssh/sshd_config`): `PermitRootLogin no`. Falls bereits
   eine `AllowUsers`-Zeile existiert, `adguard-sync` dort ergänzen — eine
   neue `AllowUsers`-Zeile nur mit `adguard-sync` würde alle anderen User
   aussperren.

### Auf dem Master (als root)

1. **SSH-Key erzeugen:**

   ```bash
   ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519_adguard-sync
   ```

2. **Public Key auf dem Slave** in `~adguard-sync/.ssh/authorized_keys`
   eintragen, eingeschränkt auf den Master:

   ```
   from="<Master-IP>",no-agent-forwarding,no-port-forwarding,no-X11-forwarding,no-pty ssh-ed25519 AAAA... root@master
   ```

3. **Log-Verzeichnis und logrotate:**

   ```bash
   mkdir -p /var/log/adguard
   install -m 644 logrotate/adguard-sync /etc/logrotate.d/adguard-sync
   ```

### Warum der chown am Anfang?

AdGuardHome läuft als `root` und schreibt seine YAML bei **jedem Start** neu —
danach gehört sie wieder `root`. Gleiches gilt für Filterdateien, die
AdGuardHome selbst aktualisiert. Ohne den `chown` am Anfang des Skripts
scheitert deshalb schon der zweite Sync-Lauf (nach dem Neustart durch den
ersten), nicht erst nach Änderungen auf dem Slave.

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
- `sudo` (Slave)
- `logrotate` (Master)
