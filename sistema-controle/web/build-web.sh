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
import hashlib
VER=hashlib.sha1(s.encode()).hexdigest()[:10]
# o app confere se saiu versão nova e se atualiza sozinho (o GitHub guarda a página em cache por até 10 min)
auto=("""<script>(function(){var V="%s";
function novo(n){ if(n===V) return; try{ if(sessionStorage.getItem("rlv")===n) return; }catch(e){}
  var m=document.getElementById("modal"), a=document.activeElement, ocupado=(m&&m.offsetParent)||(a&&/INPUT|TEXTAREA|SELECT/.test(a.tagName));
  function ir(){ try{ sessionStorage.setItem("rlv",n); }catch(e){} var u=new URL(location.href); u.searchParams.set("v",n); location.replace(u.toString()); }
  if(!ocupado){ ir(); return; }
  if(document.getElementById("rlNova")) return; var b=document.createElement("button"); b.id="rlNova"; b.textContent="⬆ Nova versão do sistema — toque para atualizar";
  b.style.cssText="position:fixed;left:50%%;transform:translateX(-50%%);bottom:14px;z-index:10000;background:#e85d0c;color:#fff;border:0;border-radius:999px;padding:10px 18px;font:700 14px system-ui;box-shadow:0 4px 14px rgba(0,0,0,.25)"; b.onclick=ir; document.body.appendChild(b); }
function ver(){ fetch("versao.txt?t="+Date.now(),{cache:"no-store"}).then(function(r){return r.ok?r.text():""}).then(function(t){t=(t||"").trim(); if(t) novo(t);}).catch(function(){}); }
setTimeout(ver,4000); setInterval(ver,120000); document.addEventListener("visibilitychange",function(){ if(document.visibilityState==="visible") ver(); });
})();</script>""")
def carimbo(html,ver):
    i=html.rfind('</body>')
    return html[:i]+(auto%ver)+html[i:]
open('app/index.html','w',encoding='utf-8').write(carimbo(s,VER)); open('app/versao.txt','w').write(VER+"\n")

# MegaEntregas OFICIAL (banco próprio, separado do sistema da RL) — publicado em /megaentregas/
t=s.replace(cfg,'<script>window.RL_SUPABASE={url:"https://glkltcsulanqsbzpwcdf.supabase.co",key:"sb_publishable_8h9FIs5NBKLtTajVgs4FxA_MIMPOmJ1"};window.RL_CENTRAL=true;</script>\n',1)
t=t.replace('<title>RL Motoboy — Controle Logístico</title>','<title>MegaEntregas — Entregas rápidas</title>\n<link rel="icon" href="../marca/megaentregas-192.png"><link rel="apple-touch-icon" href="../marca/megaentregas-192.png"><meta name="apple-mobile-web-app-title" content="MegaEntregas"><meta name="theme-color" content="#e0480a">',1)
import os; os.makedirs('megaentregas',exist_ok=True); os.makedirs('teste',exist_ok=True)
VT=hashlib.sha1(t.encode()).hexdigest()[:10]
open('megaentregas/index.html','w',encoding='utf-8').write(carimbo(t,VT)); open('megaentregas/versao.txt','w').write(VT+"\n")
# endereço antigo de teste: só leva para o novo (mantém login, mesmo site)
open('teste/index.html','w',encoding='utf-8').write('<!DOCTYPE html><html lang="pt-BR"><head><meta charset="UTF-8"><title>MegaEntregas</title><script>location.replace("../megaentregas/"+location.search+location.hash);</script></head><body>Abrindo o MegaEntregas…</body></html>')
open('teste/versao.txt','w').write("mudou-"+VT+"\n")
PY
echo "app/ e megaentregas/ gerados"

# página pública de rastreio (motoboy libera / RL e cliente acompanham)
python3 - <<'PY'
import re, os
src=open('sistema-controle/index.html',encoding='utf-8').read()
logo=re.search(r'const LOGO="(data:image/[^"]+)"',src).group(1)
p=open('sistema-controle/web/rastreio-src.html',encoding='utf-8').read()
base=p
p=base.replace('__LOGO__',logo).replace('__MARCA__','RL Motoboy e Entregas').replace('__CFG__','{url:"https://uemtwxukdclxujffltfs.supabase.co",key:"sb_publishable_z2P88k5F3LQGcUWqzELxIw_JSlfYxYg"}')
os.makedirs('rastreio',exist_ok=True); open('rastreio/index.html','w',encoding='utf-8').write(p)
# rastreio dos serviços MegaEntregas (banco próprio, marca própria)
logo_me=re.search(r'LOGO_ME="(data:image/[^"]+)"',src).group(1)
p=base.replace('__LOGO__',logo_me).replace('__MARCA__','MegaEntregas').replace('Rastreio — RL Motoboy','Rastreio — MegaEntregas').replace('__CFG__','{url:"https://glkltcsulanqsbzpwcdf.supabase.co",key:"sb_publishable_8h9FIs5NBKLtTajVgs4FxA_MIMPOmJ1"}')
os.makedirs('megaentregas/rastreio',exist_ok=True); open('megaentregas/rastreio/index.html','w',encoding='utf-8').write(p)
PY
echo "rastreio/index.html gerado"
