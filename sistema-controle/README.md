# RL Motoboy — Controle Logístico

Sistema de controle da RL Motoboy Entregas Rápidas: entradas e saídas, clientes, motoboys e motoristas,
orçamentos com cálculo de km (Mapbox), tabela de preços cliente/motoboy, recibos em PDF, financeiro
(à vista / faturado, fechamento e acerto) e dashboard.

## ⬇ Download

**[Baixar o programa para Windows (versão mais recente)](https://github.com/darioluizrl/rlmotoboy/releases/latest/download/RL-Motoboy-Windows.zip)**

## Versões

| Versão | Onde | Dados |
|---|---|---|
| **Online** | https://claude.ai/artifact/LpJEMLaKoRFuNSniNskyxd | Na nuvem, compartilhados com a equipe |
| **Windows (offline)** | [⬇ Baixar a versão mais recente](https://github.com/darioluizrl/rlmotoboy/releases/latest/download/RL-Motoboy-Windows.zip) | `Documentos\RL Motoboy\dados.json` + cópia diária em `backups\` |

Os dados das duas versões são separados. Para levar de uma para outra use
**Orçamentos → Backup dos dados → Exportar / Importar backup**.

## Instalar no Windows

1. Baixe o programa: **[⬇ RL-Motoboy-Windows.zip](https://github.com/darioluizrl/rlmotoboy/releases/latest/download/RL-Motoboy-Windows.zip)** e extraia para uma pasta fixa (ex.: `C:\RL Motoboy`).
2. Rode `Criar atalho na Área de Trabalho.bat`.
3. Se aparecer "O Windows protegeu o computador": **Mais informações → Executar assim mesmo**.

## Estrutura

- `index.html` — o sistema (um arquivo só; roda online no claude.ai e offline no programa).
- `desktop/` — programa para Windows (Electron). `desktop/build.sh` gera o `.exe` a partir de `index.html`.

## Segurança

Este repositório é **público**: nunca envie arquivos de dados (`dados.json`, backups) — o `.gitignore` já bloqueia.
A chave do Mapbox **não** fica no repositório: para montar o programa, coloque-a em `desktop/mapbox-token.txt` (bloqueado pelo `.gitignore`) ou na variável `MAPBOX_TOKEN`.
