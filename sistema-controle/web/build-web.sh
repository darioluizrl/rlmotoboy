#!/usr/bin/env bash
# Gera app/index.html (sistema web com banco Supabase) a partir de sistema-controle/index.html
# URL e chave "publishable" do Supabase são públicas por natureza (a segurança está nas regras do banco).
set -e
cd "$(dirname "$0")/../.."
python3 - <<'PY'
s=open('sistema-controle/index.html',encoding='utf-8').read()
cfg='<script>window.RL_SUPABASE={url:"https://uemtwxukdclxujffltfs.supabase.co",key:"sb_publishable_z2P88k5F3LQGcUWqzELxIw_JSlfYxYg"};</script>\n'
s=s.replace('<meta charset="UTF-8">','<meta charset="UTF-8">\n'+cfg,1)
s=s.replace('<meta name="viewport" content="width=device-width, initial-scale=1">','<meta name="viewport" content="width=device-width, initial-scale=1">\n<meta name="robots" content="noindex">',1)
open('app/index.html','w',encoding='utf-8').write(s)
PY
echo "app/index.html gerado"
