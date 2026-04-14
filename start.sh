#!/bin/bash
# ── BlackWave Server + Tunnel Launcher ────────────────────
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT=8080
CLOUDFLARED=/tmp/cloudflared
CF_LOG=/tmp/cf_blackwave.log

echo "🖤  BlackWave — iniciando..."

# ── 1. Matar procesos previos ──────────────────────────────
OLD=$(lsof -ti :$PORT 2>/dev/null)
if [ -n "$OLD" ]; then
  echo "    Deteniendo servidor anterior (PID $OLD)..."
  kill -9 $OLD 2>/dev/null
  sleep 1
fi
pkill -f "cloudflared tunnel" 2>/dev/null
sleep 1

# ── 2. Arrancar servidor Ruby ──────────────────────────────
cd "$DIR"
nohup bundle exec ruby server.rb >> server.log 2>&1 &
SERVER_PID=$!
sleep 2

if ! lsof -ti :$PORT &>/dev/null; then
  echo "    ❌ Servidor no arrancó — revisa server.log"; exit 1
fi
echo "    ✅ Servidor corriendo (PID $SERVER_PID)"

# ── 3. Descargar cloudflared si no existe ──────────────────
if [ ! -f "$CLOUDFLARED" ]; then
  echo "    Descargando cloudflared..."
  curl -sL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-arm64.tgz" \
    -o /tmp/cloudflared.tgz && tar -xzf /tmp/cloudflared.tgz -C /tmp/ && chmod +x "$CLOUDFLARED"
fi

# ── 4. Arrancar túnel Cloudflare ───────────────────────────
rm -f "$CF_LOG"
nohup "$CLOUDFLARED" tunnel --url http://localhost:$PORT --no-autoupdate > "$CF_LOG" 2>&1 &
CF_PID=$!

echo "    Esperando URL pública..."
for i in $(seq 1 20); do
  URL=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' "$CF_LOG" 2>/dev/null | head -1)
  [ -n "$URL" ] && break
  sleep 1
done

if [ -z "$URL" ]; then
  echo "    ⚠️  No se obtuvo URL del túnel — revisa /tmp/cf_blackwave.log"
else
  ICAL_URL="${URL}/api/bookings/calendar.ics?token=BlackWave2026"
  echo ""
  echo "    ════════════════════════════════════════════════"
  echo "    🌐 Sitio web   →  ${URL}/index.html"
  echo "    📋 Admin panel →  ${URL}/admin.html"
  echo "    📅 iCal iPhone →  ${ICAL_URL}"
  echo "    ════════════════════════════════════════════════"
  echo ""
  echo "    Copia la URL del iCal en tu iPhone:"
  echo "    Ajustes → Calendar → Cuentas → Añadir cuenta"
  echo "    → Otro → Añadir calendario suscrito"
  echo ""
  # Copiar iCal URL al portapapeles
  echo -n "$ICAL_URL" | pbcopy
  echo "    ✅ URL copiada al portapapeles"
fi

open "${URL}/index.html" 2>/dev/null
