// Created by Василий Маслов on 12.10.2026.
/** UI has no knowledge of MCP envelopes. A desktop adapter can implement this same boundary. */
export interface PanelTransport {
 call<T=any>(name:string,args?:Record<string,unknown>):Promise<T>;
 openLink(url:string):Promise<void>;
 sendMessage(text:string,newChat?:boolean):Promise<void>;
}

export class ToolFailure extends Error {
 constructor(message:string,readonly code:string){super(message);}
}
