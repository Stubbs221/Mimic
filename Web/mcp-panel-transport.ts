// Created by Василий Маслов on 12.10.2026.
import type {App} from '@modelcontextprotocol/ext-apps';
import type {OpenAIExtensions} from '@openai/mcp-extensions/app';
import {ToolFailure,type PanelTransport} from './panel-transport';

/** Private presentation, terminal and simulator envelopes never enter model-visible state. */
export class MCPPanelTransport implements PanelTransport {
 constructor(private app:App,private extensions:OpenAIExtensions,private fallback:string){}
 async call<T=any>(name:string,args:Record<string,unknown>={}):Promise<T>{
  const result=await this.app.callServerTool({name,arguments:args});
  const text=result.content.find(item=>item.type==='text')?.text??'';
  const privateValue=result._meta?.[name.startsWith('simulator_ui_')?'mimic/simulator':'mimic/private'] as Record<string,unknown>|undefined;
  if(result.isError){const value=privateValue??result.structuredContent??{message:text};throw new ToolFailure(typeof value.message==='string'?value.message:this.fallback,typeof value.code==='string'?value.code:'unavailable');}
  if(name.startsWith('simulator_ui_')||name.startsWith('panel_'))return privateValue as T;
  const value=result.structuredContent??JSON.parse(text||'{}');
  return (['open_panel','get_state','bind_project'].includes(name)?{...value,...(result._meta?.['mimic/workspace'] as object??{})}:value) as T;
 }
 async openLink(url:string){await this.app.openLink({url});}
 async sendMessage(text:string,newChat=false){
  if(!this.extensions.message)throw new ToolFailure(this.fallback,'unsupported');
  await this.extensions.message.send({role:'user',content:[{type:'text',text}],...(newChat?{_meta:{'openai/message':{target:'new',send:true}}}:{})});
 }
}
