#!/bin/bash
# MLXBits Image Studio — stabilité Mac mini (NetBird toujours joignable).
# À lancer sur la Mac mini :  bash mini-netbird-reliability.sh
#
# SANS sudo : utilise caffeinate (empêche la veille système) + un watchdog
# launchd qui relance NetBird toutes les 5 min si la connexion tombe.
set -e

echo "== 1. Anti-veille (caffeinate, sans sudo) =="
mkdir -p ~/bin ~/Library/LaunchAgents
cat > ~/Library/LaunchAgents/com.gildas.nosleep.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gildas.nosleep</string>
  <key>ProgramArguments</key>
  <array><string>/usr/bin/caffeinate</string><string>-i</string><string>-s</string><string>-u</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/com.gildas.nosleep 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gildas.nosleep.plist
echo "   caffeinate actif (pas de veille système)"

echo "== 2. Watchdog NetBird (toutes les 5 min) =="
cat > ~/bin/netbird-watchdog.sh << 'EOF'
#!/bin/bash
LOG="$HOME/netbird-watchdog.log"
ST=$(/usr/local/bin/netbird status 2>&1)
if echo "$ST" | grep -q "Management: Connected"; then exit 0; fi
echo "$(date '+%F %T') état: $(echo "$ST" | head -1) → reconnexion" >> "$LOG"
echo "$ST" >> "$LOG"
/usr/local/bin/netbird up >> "$LOG" 2>&1
sleep 5
/usr/local/bin/netbird connect >> "$LOG" 2>&1 || true
EOF
chmod +x ~/bin/netbird-watchdog.sh

cat > ~/Library/LaunchAgents/com.gildas.netbird-watchdog.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gildas.netbird-watchdog</string>
  <key>ProgramArguments</key>
  <array><string>/Users/gildas/bin/netbird-watchdog.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF
launchctl bootout gui/$(id -u)/com.gildas.netbird-watchdog 2>/dev/null || true
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gildas.netbird-watchdog.plist
echo "   watchdog installé (log ~/netbird-watchdog.log)"

echo "== 3. Worker mflux (vérification) =="
if curl -sf -m 5 http://127.0.0.1:8899/api/v1/status -H "Authorization: Bearer klein-4b" >/dev/null; then
    echo "   worker mflux OK (port 8899)"
else
    echo "   ATTENTION : worker mflux injoignable sur 127.0.0.1:8899"
fi

echo "Terminé. La mini restera joignable 24/7."
echo "NOTE : si la mise en veille doit être gérée proprement, exécutez en plus"
echo "(nécessite le mot de passe sudo) :"
echo "  sudo pmset -a sleep 0 disksleep 0 displaysleep 15 womp 1 networkoversleep 1 ttyskeepawake 1"
