// Grava a simulação (demo/index.html) em vídeo, num navegador sem tela do GitHub Actions.
const { chromium } = require('playwright');
(async () => {
  const b = await chromium.launch({ args: ['--use-gl=swiftshader', '--enable-unsafe-swiftshader'] });
  const ctx = await b.newContext({ viewport: { width: 1600, height: 900 }, recordVideo: { dir: 'saida', size: { width: 1600, height: 900 } } });
  const pg = await ctx.newPage();
  pg.on('console', m => { if (m.type() === 'error') console.log('console:', m.text()); });
  await pg.goto('https://darioluizrl.github.io/rlmotoboy/demo/?gravar=1&t=' + Date.now());
  const t0 = Date.now();
  // espera a história chegar ao último passo e terminar
  await pg.waitForFunction(() => document.querySelector('#passoN')?.textContent === '6', null, { timeout: 180000 });
  await pg.waitForTimeout(15000);
  console.log('duração:', Math.round((Date.now() - t0) / 1000), 's');
  await ctx.close(); await b.close();
})();
