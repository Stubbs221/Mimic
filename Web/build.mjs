// Created by Василий Маслов on 04.10.2026.
import { build } from 'esbuild';
import { readFile, writeFile } from 'node:fs/promises';
const result = await build({entryPoints:['panel.ts'],bundle:true,write:false,format:'iife',target:'es2022',minify:true,legalComments:'inline'});
const strings = JSON.parse(await readFile('ru.json','utf8'));
const title = strings.title.replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;');
const tokens = JSON.parse(await readFile('../Sources/MimicCore/Resources/panel-design-tokens.json','utf8'));
const variables = values => Object.entries(values).map(([key,value])=>`--mimic-${key}:${typeof value === "number" ? value + (key === "dragHoldMS" ? "ms" : "px") : value}`).join(';');
const light = variables(tokens.palettes.light), dark = variables(tokens.palettes.dark);
const tokenCSS = `:root{${light};${variables(tokens.metrics)}}:root[data-theme="dark"]{${dark}}@media(prefers-color-scheme:dark){:root:not([data-theme="light"]){${dark}}}`;
// Keep approved Figma vectors local while the MCP resource remains one self-contained document.
const icons = await Promise.all(['branch','chevron','plus','history','gear'].map(async name=>`--mimic-icon-${name}:url("data:image/svg+xml;base64,${(await readFile(`assets/chrome/${name}.svg`)).toString('base64')}")`));
const css = tokenCSS + '\n:root{' + icons.join(';') + '}\n' + await readFile('panel.css','utf8') + '\n' + await readFile('node_modules/@xterm/xterm/css/xterm.css','utf8');
const js = result.outputFiles[0].text.replaceAll('</script','<\\/script');
await writeFile('../Sources/MimicMCP/Resources/panel.html', `<!-- Created by Василий Маслов on 05.10.2026. -->\n<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${title}</title><style>${css}</style></head><body><main id="app" aria-busy="true"></main><script>${js}</script></body></html>`);
