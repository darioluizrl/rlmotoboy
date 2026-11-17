const { app, BrowserWindow, shell, ipcMain, Menu } = require('electron');
const path = require('path');
const fs = require('fs');

const dataDir = path.join(app.getPath('documents'), 'RL Motoboy');
try { fs.mkdirSync(path.join(dataDir, 'backups'), { recursive: true }); } catch (e) {}

ipcMain.on('rl-path', (e) => { e.returnValue = dataDir; });
ipcMain.on('rl-abrir-pasta', () => { shell.openPath(dataDir); });

if (!app.requestSingleInstanceLock()) { app.quit(); }

let win;
function createWindow() {
  win = new BrowserWindow({
    width: 1366, height: 860, minWidth: 980, minHeight: 640,
    title: 'RL Motoboy', icon: path.join(__dirname, 'icon.png'),
    autoHideMenuBar: true, backgroundColor: '#f4f5f7', show: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true, sandbox: false, spellcheck: true }
  });
  Menu.setApplicationMenu(null);
  win.loadFile(path.join(__dirname, 'app', 'index.html'));
  win.once('ready-to-show', () => { win.maximize(); win.show(); });
  // links externos (Google Maps etc.) abrem no navegador
  win.webContents.setWindowOpenHandler(({ url }) => { if (/^https?:/.test(url)) shell.openExternal(url); return { action: 'deny' }; });
  win.webContents.on('will-navigate', (e, url) => { if (!url.startsWith('file:')) { e.preventDefault(); shell.openExternal(url); } });
  // F5 recarrega, F12 ferramentas
  win.webContents.on('before-input-event', (e, input) => {
    if (input.type === 'keyDown' && input.key === 'F5') win.reload();
    if (input.type === 'keyDown' && input.key === 'F12') win.webContents.toggleDevTools();
  });
}
app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
app.whenReady().then(createWindow);
app.on('window-all-closed', () => app.quit());
