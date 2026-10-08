// Created by Василий Маслов on 08.10.2026.
/** Old helpers have no appearance field. Invalid polls retain the last valid choice. */
export function resolveAppearance(value:unknown,previous?:'tileGrid'|'legacy'):'tileGrid'|'legacy'{
 return value==='tileGrid'||value==='legacy'?value:previous??'legacy';
}
