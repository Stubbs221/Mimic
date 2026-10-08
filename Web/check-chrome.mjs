// Created by Василий Маслов on 08.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
import {panelCommand} from './check-chrome-helpers.mjs';
const require=createRequire(import.meta.url),{chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile('../Sources/MimicMCP/Resources/panel.html');
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output='/private/tmp/MimicCodexC1-20261008';await mkdir(output,{recursive:true});
let browser;
try{
 browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
 const page=await browser.newPage({viewport:{width:520,height:900}}),errors=[];page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1&data=empty`);
 await page.waitForFunction(()=>!!window.mimicChromeFixture);
 const update=patch=>page.evaluate(patch=>window.mimicChromeFixture.update(patch),patch);
 const chrome=page.locator('.panel-chrome'),popup=chrome.locator('.chrome-popover');
 const branch=chrome.getByRole('button',{name:'Локальная ветка',exact:true});
 const menu=chrome.getByRole('button',{name:'Меню панели',exact:true});
 const savedContext=await page.evaluate(()=>window.mimicToolsFixture.context());
 await update({progress:'Готов к запуску'});
 assert.equal(await page.title(),'Mimic');assert.equal(await page.getByRole('heading',{level:1}).innerText(),'Mimic\n· '+savedContext.checkoutId.split('/').at(-1));
 assert.equal(await page.getByRole('button',{name:'Настройки',exact:true}).count(),1);
 for(const theme of ['light','dark'])for(const width of [320,360,520]){
  await page.setViewportSize({width,height:900});await page.emulateMedia({colorScheme:theme,reducedMotion:'reduce'});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`${width} ${theme} overflow`);
  const identity=await chrome.locator('.chrome-identity').boundingBox(),branchBounds=await branch.boundingBox();
  assert.equal(branchBounds.y<identity.y+identity.height,width>=480,'branch moves to a second row only at narrow widths');
  for(const button of await chrome.locator('.chrome-actions button').all()){const b=await button.boundingBox();assert(b.width>=32&&b.x>=0&&b.x+b.width<=width);}
  for(const name of ['plus','history','gear','branch','chevron'])assert((await chrome.locator('.chrome-icon-'+name).evaluate(n=>getComputedStyle(n).maskImage)).startsWith('url("data:image/svg+xml;base64,'));
  await page.screenshot({path:`${output}/${width}-${theme}.png`});
 }
 await page.setViewportSize({width:520,height:900});await page.emulateMedia({colorScheme:'light'});
 assert((await chrome.boundingBox()).height<=56,'idle C1 preserves the approved 52px header');
 await branch.click();const checkbox=popup.getByRole('checkbox',{name:'Rebase на develop'});
 await checkbox.check();await page.waitForFunction(()=>document.querySelector('.chrome-rebase').hidden===false);
 assert(await checkbox.isChecked());
 const select=popup.getByRole('combobox',{name:'Локальная ветка',exact:true});await select.selectOption('feature/mcp');
 await popup.getByRole('searchbox').fill('feature');assert.equal(await select.inputValue(),'feature/mcp');
 await panelCommand(page,'Обновить');assert(await popup.isHidden());
 await branch.click();assert(await checkbox.isChecked());
 await popup.getByRole('searchbox').fill('');await select.selectOption('develop');await popup.locator('[data-action=branch-switch]').click();
 await page.waitForFunction(()=>document.querySelector('.chrome-branch-name').textContent==='develop');assert(await popup.isHidden());
 await branch.click();await page.keyboard.press('Escape');assert(await popup.isHidden());assert(await branch.evaluate(n=>document.activeElement===n));
 await menu.click();await menu.click();assert(await popup.isHidden(),'same trigger closes the popup');
 await menu.click();await page.locator('[data-block=bootstrap]').click({position:{x:5,y:5}});assert(await popup.isHidden(),'outside click dismisses');
 await page.locator('[data-block=bootstrap] .block-title').click();
 await chrome.getByRole('button',{name:'Контекст проекта',exact:true}).click();
 assert((await popup.innerText()).includes(savedContext.checkoutId));assert((await popup.innerText()).includes(savedContext.xcode));
 await page.keyboard.press('Escape');
 await chrome.getByRole('button',{name:'Настройки',exact:true}).click();assert(await popup.getByRole('button',{name:'Оформление в Mimic',exact:true}).isVisible());await page.keyboard.press('Escape');
 await chrome.getByRole('button',{name:'Новое действие',exact:true}).click();assert(await page.locator('.block-catalog').isVisible());await chrome.getByRole('button',{name:'Новое действие',exact:true}).click();
 await chrome.getByRole('button',{name:'История',exact:true}).click();assert(await page.locator('.card').filter({has:page.getByRole('heading',{name:'История',exact:true})}).isVisible());
 await panelCommand(page,'Настроить панель');assert(await page.getByRole('button',{name:'Готово',exact:true}).isVisible());assert(await branch.isDisabled());
 await page.keyboard.press('Escape');assert(await branch.isEnabled());
 await panelCommand(page,'Настроить панель');await page.getByRole('button',{name:'Готово',exact:true}).click();assert(await branch.isEnabled());
 await update({context:{...savedContext,checkoutId:'/fixture/MobilePlatformInfrastructureDevelopmentCheckout',branch:'feature/vmaslov/IOS-20658-profile-webview-svpk-navigation'}});
 for(const width of [320,360,520]){await page.setViewportSize({width,height:900});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));}
 await page.setViewportSize({width:320,height:900});await page.evaluate(()=>document.documentElement.style.fontSize='26px');
 await page.waitForFunction(()=>document.documentElement.dataset.largeText==='true');assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));
 assert((await chrome.locator('.chrome-actions').boundingBox()).y<(await branch.boundingBox()).y,'large text puts actions before the branch');
 await branch.click();assert(await checkbox.isVisible());assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth));await page.keyboard.press('Escape');
 await page.screenshot({path:output+'/large-text.png'});await page.evaluate(()=>document.documentElement.style.fontSize='13px');
 await update({checkoutLocked:true});assert(await branch.isDisabled());assert((await chrome.locator('.chrome-status').innerText()).includes('Переключение ветки'));
 await update({checkoutLocked:false,context:null});assert(await chrome.getByRole('button',{name:'Новое действие',exact:true}).isDisabled());assert(await branch.isDisabled());
 await chrome.getByRole('button',{name:'Настройки',exact:true}).click();assert(await popup.getByRole('button',{name:'Оформление в Mimic',exact:true}).isEnabled());await page.keyboard.press('Escape');
 await update({context:savedContext,tasks:[{id:'header-test',title:'Подготовка проекта',status:'running',needsInput:true,createdAt:'2099-01-01T00:00:00Z',context:savedContext,diagnosticAvailable:false,canCancel:false}]});
 assert.equal(await chrome.locator('.chrome-status').getAttribute('data-status'),'input');await chrome.locator('.chrome-status').click();const detail=page.locator('.card').filter({has:page.getByRole('heading',{name:'Подготовка проекта',exact:true})});assert(await detail.isVisible());
 const detailBounds=await detail.boundingBox();assert(detailBounds.y>=0&&detailBounds.y<900,'attention status brings the task into view');
 await update({tasks:[{id:'header-test',title:'Подготовка проекта',status:'failed',createdAt:'2099-01-01T00:00:00Z',context:savedContext,diagnosticAvailable:false,canCancel:false}]});assert.equal(await chrome.locator('.chrome-status').getAttribute('data-status'),'failed');
 await branch.click();await page.evaluate(()=>window.mimicToolsFixture.appearance('legacy'));assert(await page.locator('.context-bar .branch-rebase').isVisible());assert(await chrome.isHidden());
 await page.evaluate(()=>window.mimicToolsFixture.appearance('tileGrid'));await branch.click();assert(await checkbox.isChecked());await page.keyboard.press('Escape');
 await page.locator('[data-block=builds] .block-title').click();const draft=page.locator('#build-testIdentifiers');await draft.fill('FixtureTests/Smoke/testExample');await draft.evaluate(n=>window.chromeDraft=n);
 await panelCommand(page,'Обновить');assert.equal(await draft.inputValue(),'FixtureTests/Smoke/testExample');assert(await draft.evaluate(n=>n===window.chromeDraft));
 assert.deepEqual(errors,[]);console.log('PASS: C1 sizes/themes/assets, Rebase/branch, menu/context/settings, catalog/history, edit cancel/save, 200% text, locks/missing context, task attention, legacy and draft identity.');
}finally{await browser?.close();server.close();}
