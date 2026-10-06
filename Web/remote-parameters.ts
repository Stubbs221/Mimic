// Created by Василий Маслов on 06.10.2026.
type Parameter={id:string;kind:string};
type RemoteField={choices:string[];defaultValue:string};

/** Apply server defaults only to declared non-branch fields. Jenkins wire branch names
 * belong to the native adapter; the user's CI branch must survive a configuration refresh. */
export function applyRemoteDefaults(parameters:Parameter[],values:Record<string,string>,fields:Record<string,RemoteField>):string[]{
 const changed:string[]=[];
 for(const parameter of parameters){
  if(parameter.kind==='branch')continue;
  const field=fields[parameter.id];if(!field)continue;
  if(field.choices.length? !field.choices.includes(values[parameter.id]):values[parameter.id]===undefined){
   values[parameter.id]=field.defaultValue;changed.push(parameter.id);
  }
 }
 return changed;
}
