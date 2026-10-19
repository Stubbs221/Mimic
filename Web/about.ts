// Created by Василий Маслов on 13.10.2026.
/** The existing delivery metadata can omit native identity when connected to an older app. */
export type MimicDelivery = {native?: {version?: unknown;build?: unknown}|null}|null;

/** Settings show the running native app's identity, even when an older helper is connected. */
export class MimicAbout {
 readonly host=document.createElement('section');
 private readonly version=document.createElement('p');
 constructor(private readonly t:(key:string)=>string){
  this.host.className='mimic-about';this.host.setAttribute('aria-label',t('settings.about.title'));
  const heading=document.createElement('h2'),author=document.createElement('p');
  heading.textContent=t('settings.about.title');author.textContent=t('settings.about.author');
  this.host.append(heading,this.version,author);this.update();
 }
 update(delivery?:MimicDelivery){
  const version=delivery?.native?.version,build=delivery?.native?.build;
  this.version.textContent=typeof version==='string'&&version.trim()
   ?this.t('settings.about.version').replace('{version}',version).replace('{build}',typeof build==='string'&&build.trim()?build:'—')
   :this.t('settings.about.unavailable');
 }
}
