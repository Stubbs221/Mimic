// Created by Василий Маслов on 04.10.2026.
import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';
const result = await build({entryPoints:['panel.ts'],bundle:true,write:false,format:'iife',target:'es2022',minify:true,legalComments:'inline'});
const strings = JSON.parse(await readFile('ru.json','utf8'));
const title = strings.title.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const css = await readFile('panel.css','utf8') + '\n' + await readFile('node_modules/@xterm/xterm/css/xterm.css','utf8');
const js = result.outputFiles[0].text.replaceAll('</script','<\\/script');
await writeFile('../Sources/MimicMCP/Resources/panel.html', `<!-- Created by Василий Маслов on 05.10.2026. -->\n<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><style>${css}</style></head><body><main id="app" aria-busy="true"></main><script>${js}</script></body></html>`);
