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

# versão de TESTE (banco separado rl-motoboy-teste): nada aqui mexe nos dados reais
t=s.replace(cfg,'<script>window.RL_SUPABASE={url:"https://glkltcsulanqsbzpwcdf.supabase.co",key:"sb_publishable_8h9FIs5NBKLtTajVgs4FxA_MIMPOmJ1"};window.RL_CENTRAL=true;</script>\n',1)
selo='<div style="position:fixed;left:8px;bottom:8px;z-index:9999;background:#7c3aed;color:#fff;font:700 11px system-ui;padding:4px 9px;border-radius:999px;pointer-events:none">AMBIENTE DE TESTE</div>'
t=t.replace('</body>',selo+'</body>',1).replace('<title>','<title>[TESTE] ',1)
import os; os.makedirs('teste',exist_ok=True)
open('teste/index.html','w',encoding='utf-8').write(t)
PY
echo "app/index.html e teste/index.html gerados"

# página pública de rastreio (motoboy libera / RL e cliente acompanham)
python3 - <<'PY'
import re, os
src=open('sistema-controle/index.html',encoding='utf-8').read()
logo=re.search(r'const LOGO="(data:image/[^"]+)"',src).group(1)
p=open('sistema-controle/web/rastreio-src.html',encoding='utf-8').read()
p=p.replace('__LOGO__',logo).replace('__CFG__','{url:"https://uemtwxukdclxujffltfs.supabase.co",key:"sb_publishable_z2P88k5F3LQGcUWqzELxIw_JSlfYxYg"}')
os.makedirs('rastreio',exist_ok=True); open('rastreio/index.html','w',encoding='utf-8').write(p)
PY
echo "rastreio/index.html gerado"
