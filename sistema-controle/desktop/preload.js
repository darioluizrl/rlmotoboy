const { contextBridge, ipcRenderer } = require('electron');
const fs = require('fs');
const path = require('path');

const dir = ipcRenderer.sendSync('rl-path');
const file = path.join(dir, 'dados.json');
const bkDir = path.join(dir, 'backups');

function hoje() { const d = new Date(); return d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' + String(d.getDate()).padStart(2, '0'); }

contextBridge.exposeInMainWorld('rlStore', {
  load() { try { return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null; } catch (e) { return null; } },
  save(json) {
    fs.mkdirSync(bkDir, { recursive: true });
    const tmp = file + '.tmp';
    fs.writeFileSync(tmp, json, 'utf8');
    fs.renameSync(tmp, file);
    // uma cópia por dia, mantém as 60 mais recentes
    const bk = path.join(bkDir, 'dados-' + hoje() + '.json');
    fs.copyFileSync(file, bk);
    const lista = fs.readdirSync(bkDir).filter(f => /^dados-\d{4}-\d{2}-\d{2}\.json$/.test(f)).sort();
    while (lista.length > 60) { try { fs.unlinkSync(path.join(bkDir, lista.shift())); } catch (e) { break; } }
  },
  pasta() { return dir; },
  abrirPasta() { ipcRenderer.send('rl-abrir-pasta'); }
});
