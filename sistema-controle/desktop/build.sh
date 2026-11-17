#!/usr/bin/env bash
# Gera o programa para Windows a partir de ../index.html
# A chave pública do Mapbox NÃO fica no git: coloque-a em desktop/mapbox-token.txt
# (ou na variável de ambiente MAPBOX_TOKEN) antes de rodar.
set -e
cd "$(dirname "$0")"
TOKEN="${MAPBOX_TOKEN:-$(cat mapbox-token.txt 2>/dev/null || true)}"
[ -z "$TOKEN" ] && echo "Aviso: sem chave do Mapbox — o cálculo de km ficará desativado no programa."
TOKEN="$TOKEN" python3 - <<'PY'
import os, json
s=open('../index.html',encoding='utf-8').read()
inj='<script>window.RL_OFFLINE=true;window.RL_MAPBOX_TOKEN=%s;window.RL_LIBS={chart:"lib/chart.umd.js",jspdf:"lib/jspdf.umd.min.js"};</script>\n' % json.dumps(os.environ.get("TOKEN",""))
open('app/index.html','w',encoding='utf-8').write(s.replace('<meta charset="UTF-8">','<meta charset="UTF-8">\n'+inj,1))
PY
npx --yes @electron/packager@18 . "RL Motoboy" --platform=win32 --arch=x64 --electron-version=33.2.1 --out=dist --overwrite --ignore="^/(dist|build.sh|seticon.js|icon.ico|mapbox-token.txt)"
npm i --no-save resedit@2 >/dev/null && node seticon.js "dist/RL Motoboy-win32-x64/RL Motoboy.exe" icon.ico
echo "Pronto: dist/RL Motoboy-win32-x64"
