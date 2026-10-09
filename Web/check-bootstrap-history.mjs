//
//  check-bootstrap-history.mjs
//  Mimic
//
//  Created by Василий Маслов on 09.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>response.end(html));
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
const output='/private/tmp/Mimic-bootstrap-v2-web-history';await mkdir(output,{recursive:true});
try{
 const page=await browser.newPage({viewport:{width:440,height:1200}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);
 await page.waitForFunction(()=>!!window.mimicBootstrapFixture);
 await page.evaluate(()=>window.mimicBootstrapFixture.empty());
 const older=await page.evaluate(()=>window.mimicBootstrapFixture.task('succeeded'));
 const active=await page.evaluate(()=>window.mimicBootstrapFixture.task('running','ios',false,'',true));
 await page.evaluate(id=>window.mimicBootstrapFixture.output(id,'| Dependency | Version |\r\n| A | 1.0 |\r\n'),active);
 await page.getByRole('button',{name:'История',exact:true}).click();
 const rows=page.locator('.bootstrap-history-row');
 assert.equal(await rows.count(),2);
 const oldRow=rows.filter({has:page.locator(`[aria-controls="bootstrap-history-${older}"]`)});
 await oldRow.locator('.item').click();
 assert.equal(await oldRow.locator('h2,.bootstrap-history-step:visible,progress:visible').count(),0,'old run never shows active progress or another header');
 assert.equal(await oldRow.locator('.status').count(),1);
 assert.equal(await oldRow.locator('.terminal-host').count(),1);
 assert.equal(await oldRow.locator('.terminal-host').evaluate(n=>n.getBoundingClientRect().height),240);
 const activeRow=rows.filter({has:page.locator(`[aria-controls="bootstrap-history-${active}"]`)});
 await activeRow.locator('.item').click();
 const card=page.locator('.panel-block[data-block=bootstrap]');
 const historyTerminal=activeRow.locator('.terminal-host'),cardTerminal=card.locator('.terminal-host');
 await page.waitForTimeout(1000);
 await historyTerminal.evaluate(n=>window.historyTerminalIdentity=n);
 await cardTerminal.evaluate(n=>window.cardTerminalIdentity=n);
 assert(await page.evaluate(()=>window.historyTerminalIdentity!==window.cardTerminalIdentity));
 assert((await historyTerminal.locator('.xterm-screen').innerText()).includes('| Dependency | Version |'));
 assert.equal(await activeRow.locator('progress:visible').count(),1);
 const input=historyTerminal.locator('.xterm-helper-textarea');await historyTerminal.click();await input.focus();
 assert.equal(await historyTerminal.getAttribute('data-selected'),'true');assert.equal(await cardTerminal.getAttribute('data-selected'),'false');
 await page.waitForTimeout(5100);
 assert(await input.evaluate(n=>document.activeElement===n),'poll preserves history terminal focus');
 assert(await historyTerminal.evaluate(n=>n===window.historyTerminalIdentity));
 assert(await cardTerminal.evaluate(n=>n===window.cardTerminalIdentity),'history never replaces card screen');
 await page.evaluate(()=>window.mimicBootstrapFixture.task('failed','ios',true,'Очень длинная ошибка '.repeat(30),true));
 assert(await activeRow.getByRole('button',{name:'Разобрать ошибку',exact:true}).isVisible());
 assert.equal(await activeRow.locator('.bootstrap-history-diagnostic textarea').count(),0,'editor opens only by action');
 await activeRow.getByRole('button',{name:'Разобрать ошибку',exact:true}).click();
 const editor=activeRow.getByRole('textbox',{name:'Диагностика локальной задачи',exact:true});await editor.fill('History edit');await editor.focus();
 await page.waitForTimeout(1100);assert(await editor.evaluate(n=>document.activeElement===n));
 await activeRow.getByRole('button',{name:'Закрыть диагностику',exact:true}).click();
 for(const width of [320,360,440,560])for(const colorScheme of ['light','dark'])for(const scale of [13,20]){
  await page.setViewportSize({width,height:1300});await page.emulateMedia({colorScheme});
  await page.evaluate(scale=>document.documentElement.style.fontSize=scale+'px',scale);await page.waitForTimeout(120);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
  const bounds=await activeRow.boundingBox();for(const button of await activeRow.locator('button:visible').all()){
   const rect=await button.boundingBox();assert(rect.x>=bounds.x&&rect.x+rect.width<=bounds.x+bounds.width+1);
  }
  assert.equal(await activeRow.locator('h2').count(),0);assert.equal(await activeRow.locator('.status').count(),1);
  await activeRow.screenshot({path:`${output}/history-${width}-${colorScheme}-${scale}.png`});
 }
 await activeRow.locator('.item').click();assert.equal(await activeRow.locator('.bootstrap-history-details:visible').count(),0);
 await activeRow.locator('.item').click();assert(await historyTerminal.evaluate(n=>n===window.historyTerminalIdentity),'collapse retains history screen');
 assert.deepEqual(errors,[]);
 console.log('PASS: inline disclosure, single header/status, historical progress identity, 240px terminal, independent simultaneous screens, ASCII tables, focus, action-only editor, widths/themes/enlarged text');
}finally{await browser.close();server.close();}
