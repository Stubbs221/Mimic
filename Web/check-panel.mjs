// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,reply)=>{reply.setHeader('Content-Type','text/html');reply.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
const url=`http://127.0.0.1:${server.address().port}/?preview=1`;
try{
 const page=await browser.newPage({viewport:{width:440,height:1050}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));await page.goto(url);
 const block=kind=>page.locator(`.panel-block[data-block="${kind}"]`);
 const title=kind=>block(kind).locator('.block-title');
 await page.getByRole('button',{name:'Настроить панель',exact:true}).waitFor();
 assert(await block('bootstrap').getByRole('button',{name:'iOS',exact:true}).isVisible(),'default bootstrap exposes primary action');
 assert(await page.locator('.block-chevron').count()===0,'card chevrons are removed');
 for(const kind of ['bootstrap','builds']){
  await block(kind).click({position:{x:5,y:5}});assert(await title(kind).getAttribute('aria-expanded')==='true','surface opens '+kind);
  await block(kind).click({position:{x:5,y:5}});assert(await title(kind).getAttribute('aria-expanded')==='false','surface closes '+kind);
 }
 await block('bootstrap').locator('.terminal-host').click({position:{x:10,y:10}});
 assert(await title('bootstrap').getAttribute('aria-expanded')==='false','terminal click keeps disclosure');
 await title('builds').focus();await page.keyboard.press('Enter');
 assert(await title('builds').getAttribute('aria-expanded')==='true','keyboard opens card');
 assert(await block('utils').evaluate(node=>node.hidden&&node.inert),'expanded peer stays inert');
 const field=block('builds').locator('input,select,textarea').first();await field.click();
 assert(await title('builds').getAttribute('aria-expanded')==='true','nested field keeps disclosure');
 await title('builds').press('Enter');
 await page.getByRole('button',{name:'Настроить панель',exact:true}).click();
 await block('builds').click({position:{x:5,y:5}});
 assert(await title('builds').getAttribute('aria-expanded')==='false','editing surface does not expand');
 await page.keyboard.press('Escape');
 if(process.env.MIMIC_PANEL_CHECK==='surface'){assert.deepEqual(errors,[]);console.log('PASS: card surface disclosure and terminal exclusion');process.exitCode=0;}else{
 for(const width of [360,440,480,520])for(const theme of ['light','dark']){
  await page.setViewportSize({width,height:1050});await page.emulateMedia({colorScheme:theme,reducedMotion:'reduce'});
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),`no horizontal overflow ${width} ${theme}`);
  await title('builds').click();
  assert(await block('utils').evaluate(node=>node.hidden&&node.inert&&node.getAttribute('aria-hidden')==='true'));
  const bounds=await block('builds').boundingBox();assert(bounds.width>=width-28,'right mini expands left across row');
  await title('builds').click();assert(await title('utils').isVisible());
 }
 await page.setViewportSize({width:440,height:1050});await page.emulateMedia({reducedMotion:'no-preference',colorScheme:'light'});
 await title('builds').click();
 for(let sample=0;sample<5;sample++){await page.waitForTimeout(40);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'animated right expansion cannot overflow');}
 for(let sample=0;sample<5;sample++){await page.waitForTimeout(40);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'right disclosure must remain inside panel during motion');}
 const identifiers=page.locator('#build-testIdentifiers');await identifiers.fill('FixtureTests/Smoke/testExample\nFixtureTests/Other');await identifiers.focus();
 await identifiers.evaluate(node=>{window.fixtureInputIdentity=node;});await page.waitForTimeout(5300);
 assert.equal(await identifiers.inputValue(),'FixtureTests/Smoke/testExample\nFixtureTests/Other');
 assert(await identifiers.evaluate(node=>node===window.fixtureInputIdentity&&document.activeElement===node),'poll preserves focus and form identity');
 await title('builds').click();await page.getByRole('button',{name:'Настроить панель',exact:true}).click();
 await block('utils').locator('.placement-menu summary').click();await block('utils').getByRole('button',{name:'Убрать с панели',exact:true}).click();
 assert(await block('utils').evaluate(n=>n.hidden));assert.equal(await page.locator('.empty-slot').count(),1);
 // Drag a mini block into the free half without overwriting its neighbour.
 await page.waitForTimeout(250);const source=await block('ci').locator('.drag-handle').boundingBox(),destination=await page.locator('.empty-slot').boundingBox();
 await page.mouse.move(source.x+source.width/2,source.y+source.height/2);await page.mouse.down();await page.waitForTimeout(380);await page.mouse.move(destination.x+destination.width/2,destination.y+destination.height/2,{steps:8});
 assert.equal(await page.locator('[data-drag-active]').count(),1);await page.mouse.up();
 assert.equal(await block('ci').evaluate(n=>n.style.gridRow),await block('builds').evaluate(n=>n.style.gridRow));
 await page.getByRole('button',{name:'Отмена',exact:true}).click();assert(await title('utils').isVisible());
 await page.getByRole('button',{name:'Настроить панель',exact:true}).click();
 const grip=await block('builds').locator('.drag-handle').boundingBox();await page.mouse.move(grip.x+5,grip.y+5);await page.mouse.down();await page.waitForTimeout(380);await page.mouse.move(30,40);await page.keyboard.press('Escape');await page.mouse.up();assert.equal(await page.locator('[data-drag-active]').count(),0);
 await block('utils').locator('.placement-menu summary').click();await block('utils').getByRole('button',{name:'Убрать с панели',exact:true}).click();await page.getByRole('button',{name:'Готово',exact:true}).click();await page.waitForTimeout(100);
 assert(await block('utils').evaluate(n=>n.hidden));
 await title('builds').click();assert.equal(await identifiers.inputValue(),'FixtureTests/Smoke/testExample\nFixtureTests/Other');await title('builds').click();
 await page.getByRole('button',{name:'Новое действие',exact:true}).click();await page.locator('.block-catalog').getByRole('button',{name:'UI-компонент',exact:true}).click();
 await page.getByRole('button',{name:'Предпросмотр',exact:true}).click();await page.locator('.preview-files').filter({hasText:'Sources/Fixture.swift'}).waitFor();
 await page.getByRole('button',{name:'Создать файлы',exact:true}).click();
 await page.getByRole('button',{name:'Новое действие',exact:true}).click();await page.locator('.block-catalog').getByRole('button',{name:'Beta',exact:true}).click();
 await page.getByRole('button',{name:'Получить параметры Jenkins',exact:true}).click();assert(await block('beta').getByRole('button',{name:'Запустить',exact:true}).isEnabled());
 assert.equal(await block('beta').locator('select[id$="-target"] option').count(),2,'choices supplied only by server produce a select');
 await title('beta').click();await page.getByRole('button',{name:'История',exact:true}).click();await page.locator('.item').filter({hasText:'Bootstrap iOS'}).first().click();await page.getByRole('button',{name:'Терминал',exact:true}).click();await page.locator('.xterm').waitFor();await page.waitForTimeout(900);assert((await page.locator('.xterm-screen').innerText()).includes('Mimic fixture terminal')||await page.locator('.xterm-screen canvas').count()>0);
 const terminal=page.locator('.terminal-host');await terminal.evaluate(node=>window.fixtureTerminalIdentity=node);await page.waitForTimeout(5100);assert(await terminal.evaluate(node=>node===window.fixtureTerminalIdentity),'terminal instance remains attached across polls');
 await page.getByRole('button',{name:'Настроить панель',exact:true}).click();await page.getByRole('button',{name:'Сбросить',exact:true}).click();await page.getByRole('button',{name:'Готово',exact:true}).click();assert(await title('utils').isVisible());
 await page.screenshot({path:process.env.MIMIC_PANEL_SCREENSHOT??'/private/tmp/MimicPanel-acceptance.png',fullPage:true});
 for(const data of ['worst','empty','large']){
  await page.goto(url+'&data='+data);await page.setViewportSize({width:360,height:1050});await page.getByRole('button',{name:'История',exact:true}).click();
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'edge data cannot overflow: '+data);
  if(data==='empty')assert.equal(await page.locator('.item').count(),0);
  if(data==='large')assert.equal(await page.locator('.item').count(),100);
 }
 assert.deepEqual(errors,[]);console.log('PASS: 360/440/480, themes, Reduce Motion, right expansion/inert peer, focus/drafts, drag/free slot/Escape, cancel/save/reset, hidden catalogue, generator digest, CI form, encrypted xterm fixture');
}}finally{await browser.close();server.close();}
