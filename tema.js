/* Preferência visual apenas; não armazena credenciais. */
(() => {
 const key='cde-pdi-modelo-theme';let stored;
 try{stored=localStorage.getItem(key);}catch{}
 const theme=['light','dark'].includes(stored)?stored:'light';
 document.documentElement.dataset.theme=theme;
 window.CDEModelTheme={get:()=>document.documentElement.dataset.theme,set(value){const next=value==='dark'?'dark':'light';document.documentElement.dataset.theme=next;try{localStorage.setItem(key,next);}catch{}window.dispatchEvent(new Event('cde-theme-change'));}};
})();
