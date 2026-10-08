// Created by Василий Маслов on 08.10.2026.
/** Follow the same entry point in C1 and legacy fixtures. */
export async function panelCommand(page,name){
 if(await page.locator('.panel-chrome').isVisible()){
  const menu=page.getByRole('button',{name:'Меню панели',exact:true});
  if(await menu.getAttribute('aria-expanded')!=='true')await menu.click();
 }
 await page.getByRole('button',{name,exact:true}).click();
}
