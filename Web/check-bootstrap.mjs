// Created by Василий Маслов on 06.10.2026.
import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const {chromium}=require(process.env.MIMIC_PLAYWRIGHT_MODULE??'playwright');
const html=await readFile(new URL('../Sources/MimicMCP/Resources/panel.html',import.meta.url));
const server=createServer((_,response)=>{response.setHeader('Content-Type','text/html');response.end(html);});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const output=process.env.MIMIC_BOOTSTRAP_PREVIEWS??'/private/tmp/Mimic-bootstrap-previews';await mkdir(output,{recursive:true});
const browser=await chromium.launch({headless:true,executablePath:process.env.MIMIC_CHROME_EXECUTABLE});
try{
 const page=await browser.newPage({viewport:{width:440,height:1050}}),errors=[];
 page.on('pageerror',error=>errors.push(error.message));
 await page.goto(`http://127.0.0.1:${server.address().port}/?preview=1`);
 await page.waitForFunction(()=>!!window.mimicBootstrapFixture);
 const block=page.locator('.panel-block[data-block="bootstrap"]'),title=block.locator('.block-title');
 const setMode=mode=>page.evaluate(mode=>window.mimicBootstrapFixture.mode(mode),mode);
 const setTask=(status,platform='ios',reuse=false,error='')=>page.evaluate(args=>window.mimicBootstrapFixture.task(...args),[status,platform,reuse,error]);
 await page.evaluate(()=>window.mimicBootstrapFixture.empty());await setMode('full');
 assert.equal(await block.locator('.bootstrap-launchers button').count(),2);
 assert.equal(await block.locator('select,details').count(),0);
 assert(await block.locator('.bootstrap-overview').getByText('Зависимости',{exact:false}).isVisible());
 assert(await block.getByText('Запуск закроет Xcode',{exact:true}).isVisible());
 const iosBox=await block.getByRole('button',{name:'iOS',exact:true}).boundingBox(),tvBox=await block.getByRole('button',{name:'tvOS',exact:true}).boundingBox();assert(tvBox.y>=iosBox.y+iosBox.height,'platform buttons stack vertically');assert.equal(iosBox.height,28);assert.equal(iosBox.width,104,'short platform names use compact controls');assert.equal(await block.locator('.bootstrap-platform-icon').count(),2);
 const controls=await block.locator('.bootstrap-controls').boundingBox(),terminal=await block.locator('.bootstrap-terminal-region').boundingBox();
 assert(terminal.x>=controls.x+controls.width,'full terminal occupies the right half');
 assert(Math.abs(terminal.width/controls.width-1.5)<.02,'full columns allocate 40/60');
 await block.getByRole('button',{name:'iOS',exact:true}).evaluate(node=>{node.click();node.click();});
 assert(!await block.getByRole('button',{name:'iOS',exact:true}).isVisible());
 assert(await block.getByRole('button',{name:'Отменить',exact:true}).isVisible());
 assert(!await block.evaluate(node=>node.classList.contains('expanded')),'launch preserves disclosure');
 const launches=await page.evaluate(()=>window.mimicBootstrapFixture.launches);
 assert.equal(launches.length,1);assert.deepEqual(launches[0].parameters,{device:'true',match:'true',full:'true',dependencies:'true',uiDependencies:'false',setup:'true',platform:'ios'});
 await block.locator('.terminal-host').waitFor();await block.locator('.terminal-host').evaluate(node=>window.bootstrapTerminalIdentity=node);
 await setMode('mini');assert(!await block.locator('.bootstrap-terminal-region').isVisible());assert(await block.locator('.bootstrap-state').isVisible());
 assert(await block.getByRole('button',{name:'Отменить',exact:true}).isVisible());
 await title.click();assert(await block.locator('.bootstrap-terminal-region').isVisible());
 const expandedTerminal=await block.locator('.bootstrap-terminal-region').boundingBox(),controlsBox=await block.locator('.bootstrap-controls').boundingBox();assert(expandedTerminal.y>=controlsBox.y+controlsBox.height);
 assert(await block.locator('.terminal-host').evaluate(node=>node===window.bootstrapTerminalIdentity));
 const id=await setTask('running','ios',true);await page.waitForTimeout(900);
 assert(await block.getByRole('button',{name:'Остановить',exact:true}).isVisible());
 assert.equal(await block.locator('.terminal-host').getAttribute('data-font-size'),'12');
 assert.equal(await block.locator('.bootstrap-stages [data-state=complete]').count(),1);
 const input=block.locator('.xterm-helper-textarea');await input.focus();await input.press('a');await page.waitForTimeout(200);
 assert((await page.evaluate(()=>window.mimicBootstrapFixture.inputCount))>0,'live encrypted input is delivered');
 await page.evaluate(id=>window.mimicBootstrapFixture.output(id,'FINAL BOOTSTRAP LINE\r\n'),id);await setTask('succeeded','ios',true);await page.waitForTimeout(900);
 assert((await block.locator('.xterm-screen').innerText()).includes('FINAL BOOTSTRAP LINE'),'final output survives completion');
 const sentInputs=await page.evaluate(()=>window.mimicBootstrapFixture.inputCount);await input.press('b');await page.waitForTimeout(150);assert.equal(await page.evaluate(()=>window.mimicBootstrapFixture.inputCount),sentInputs);
 await setMode('full');assert.equal(await block.locator('.terminal-host').getAttribute('data-font-size'),'10');
 await page.emulateMedia({colorScheme:'dark'});assert(await block.locator('.terminal-host').evaluate(node=>getComputedStyle(node).backgroundColor==='rgb(32, 40, 51)'));
 await page.emulateMedia({colorScheme:'light'});
 await setMode('mini');await title.click();await page.waitForTimeout(150);assert((await block.locator('.xterm-screen').innerText()).includes('FINAL BOOTSTRAP LINE'));assert(await block.locator('.terminal-host').evaluate(node=>node===window.bootstrapTerminalIdentity));
 await page.evaluate(()=>window.mimicBootstrapFixture.refreshContext());await page.waitForTimeout(800);assert((await block.locator('.xterm-screen').innerText()).includes('FINAL BOOTSTRAP LINE'),'Git metadata refresh preserves the completed task screen');
 const failedID=await setTask('running','tvos');await page.waitForTimeout(800);await setTask('failed','tvos',true,'Не удалось загрузить InfrastructureDependencyRegistryConfiguration из registry.example.invalid');
 const overlay=block.getByRole('button',{name:'Передать ошибку агенту',exact:true});assert(await overlay.isVisible());
 const overlayBounds=await overlay.boundingBox(),screenBounds=await block.locator('.xterm-screen').boundingBox();assert(screenBounds.y>=overlayBounds.y+overlayBounds.height,'error action leaves every output line readable');await overlay.click();
 const editor=block.getByRole('textbox',{name:'Диагностика локальной задачи',exact:true});await editor.fill('Edited dependency error');await block.getByRole('textbox',{name:'Комментарий к ошибке',exact:true}).fill('Original bootstrap task');
 await editor.focus();await editor.evaluate(node=>window.bootstrapEditorIdentity=node);await page.waitForTimeout(5100);
 assert(await editor.evaluate(node=>node===window.bootstrapEditorIdentity&&document.activeElement===node),'poll preserves diagnostic editor and focus');
 assert.equal(await page.evaluate(()=>window.mimicBootstrapFixture.sent),'','opening diagnostics never sends');
 await block.getByRole('button',{name:'Отправить на разбор',exact:true}).click();
 const sent=await page.evaluate(()=>window.mimicBootstrapFixture.sent);assert(sent.includes('Edited dependency error')&&sent.includes('Original bootstrap task')&&sent.includes(failedID));
 await page.evaluate(()=>window.mimicBootstrapFixture.disconnected(true));assert(await block.getByRole('button',{name:'tvOS',exact:true}).isDisabled());await page.evaluate(()=>window.mimicBootstrapFixture.disconnected(false));
 await page.evaluate(()=>window.mimicBootstrapFixture.missingContext(true));assert(await block.getByRole('button',{name:'iOS',exact:true}).isDisabled());await page.evaluate(()=>window.mimicBootstrapFixture.missingContext(false));
 for(const width of [320,360,440,480,520])for(const colorScheme of ['light','dark'])for(const reducedMotion of ['reduce','no-preference'])for(const mode of ['mini','full','expanded']){
  await page.setViewportSize({width,height:1100});await page.emulateMedia({colorScheme,reducedMotion});await setMode(mode);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'no horizontal document overflow');
  for(const button of await block.locator('.bootstrap-launchers button').all()){const box=await button.boundingBox();const bounds=await block.boundingBox();assert(box.x>=bounds.x&&box.x+box.width<=bounds.x+bounds.width,'platform action remains reachable');}
  if(mode==='mini')assert(!await block.locator('.bootstrap-terminal-region').isVisible());
  else{const region=await block.locator('.bootstrap-terminal-region').boundingBox(),bounds=await block.boundingBox();assert(region.x>=bounds.x&&region.x+region.width<=bounds.x+bounds.width);}
  if(mode!=='expanded'){const bounds=await block.boundingBox();for(const node of await block.locator('.bootstrap-controls > :visible').all()){const box=await node.boundingBox();assert(box.y+box.height<=bounds.y+bounds.height-8,'collapsed content fits the card');}}
  await block.screenshot({path:`${output}/bootstrap-${mode}-${width}-${colorScheme}-${reducedMotion}.png`});
 }
 for(const state of ['queued','blocked','running','succeeded','cancelled','failed']){
  await setTask(state);await setMode('mini');
  const bounds=await block.boundingBox();for(const node of await block.locator('.bootstrap-controls > :visible').all()){const box=await node.boundingBox();assert(box.y+box.height<=bounds.y+bounds.height-8,`${state} fits 160px`);}
  if(state==='blocked')assert(await block.getByRole('button',{name:'Повторить проверку',exact:true}).isVisible());
  if(state==='running'){await block.getByRole('button',{name:'Остановить',exact:true}).click();assert(await block.getByRole('button',{name:'iOS',exact:true}).isVisible());}
 }
 await setTask('succeeded');
 await page.emulateMedia({forcedColors:'active'});await setMode('expanded');await block.screenshot({path:`${output}/bootstrap-contrast.png`});
 await page.emulateMedia({forcedColors:'none'});await setMode('mini');await title.focus();await page.keyboard.press('Tab');assert.equal(await page.evaluate(()=>document.activeElement?.textContent),'iOS');await page.keyboard.press('Tab');assert.equal(await page.evaluate(()=>document.activeElement?.textContent),'tvOS');await page.keyboard.press('Tab');assert(!await page.evaluate(()=>document.activeElement?.closest('.bootstrap-terminal-region')),'hidden terminal is outside keyboard navigation');
 await page.evaluate(()=>window.mimicBootstrapFixture.empty());
 await block.getByRole('button',{name:'tvOS',exact:true}).evaluate(node=>{node.click();node.click();});
 await page.waitForFunction(()=>window.mimicBootstrapFixture.launches.length===2);
 const tvLaunches=await page.evaluate(()=>window.mimicBootstrapFixture.launches);assert.deepEqual(tvLaunches[1].parameters,{...launches[0].parameters,platform:'tvos'});
 assert(await block.evaluate(node=>node.classList.contains('mini')&&!node.classList.contains('expanded')),'mini launch preserves size and disclosure');
 await page.evaluate(()=>{const id=window.mimicBootstrapFixture.task('succeeded');window.mimicBootstrapFixture.unavailable(id);});await setMode('expanded');
 await block.getByText('Вывод недоступен; сохранён только контекст задачи',{exact:true}).waitFor();
 await page.evaluate(()=>window.mimicBootstrapFixture.rejectNext());await block.getByRole('button',{name:'iOS',exact:true}).click();
 assert(await block.locator('.bootstrap-error').getByText('Fixture admission refused',{exact:true}).isVisible());
 await block.getByRole('button',{name:'Передать ошибку агенту',exact:true}).click();assert.equal(await block.getByRole('textbox',{name:'Диагностика локальной задачи',exact:true}).inputValue(),'Fixture admission refused');
 assert.deepEqual(errors,[]);console.log('PASS: platform defaults, no auto expansion, mini/full/expanded, 40/60 columns, vertical launchers, adaptive palette/font, compact state, encrypted input, final output, identity, diagnostics preview/send/focus, offline/no checkout, widths/themes/Reduce Motion/contrast/keyboard');
}finally{await browser.close();server.close();}
