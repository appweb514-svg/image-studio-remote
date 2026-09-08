#!/bin/bash
# MLXBits Image Studio — stabilité Mac mini (NetBird toujours joignable).
# À lancer sur la Mac mini :  bash mini-netbird-reliability.sh
set -e

echo "== 1. Empêcher la mise en veille (cause n°1 des drops NetBird) =="
sudo pmset -a sleep 0
sudo pmset -a disksleep 0
sudo pmset -a displaysleep 15
sudo pmset -a womp 1                  # Wake on network access
sudo pmset -a networkoversleep 1      # Rester joignable pendant la veille affichage
sudo pmset -a ttyskeepawake 1
echo "   pmset configuré (jamais de veille système sur secteur)"

echo "== 2. Watchdog NetBird (relance la connexion si tombée) =="
mkdir -p ~/bin
cat > ~/bin/netbird-watchdog.sh << 'EOF'
#!/bin/bash
# Vérifie NetBird toutes les 5 min ; relance si déconnecté.
LOG="$HOME/netbird-watchdog.log"
if ! /usr/local/bin/netbird status 2>/dev/null | grep -q "Connected: true"; then
    echo "$(date '+%F %T') déconnecté → netbird up" >> "$LOG"
    /usr/local/bin/netbird up >> "$LOG" 2>&1
    sleep 10
    /usr/local/bin/netbird connect >> "$LOG" 2>&1 || true
fi
EOF
chmod +x ~/bin/netbird-watchdog.sh

cat > ~/Library/LaunchAgents/com.gildas.netbird-watchdog.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gildas.netbird-watchdog</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/gildas/bin/netbird-watchdog.sh</string>
  </array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/com.gildas.netbird-watchdog 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gildas.netbird-watchdog.plist
echo "   watchdog installé (toutes les 5 min, log ~/netbird-watchdog.log)"

echo "== 3. Vérifications =="
pmset -g | grep -E "^ sleep|womp|networkoversleep" || true
/usr/local/bin/netbird status 2>/dev/null | head -3 || echo "NetBird CLI introuvable — vérifiez l'installation"

echo "Terminé. La mini restera joignable 24/7."
