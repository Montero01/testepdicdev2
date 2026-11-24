import assert from 'node:assert/strict';
import {boot} from '../interface.mjs';
let checks=0;const ok=(value,message)=>{assert.ok(value,message);checks++;};
const permissions={allowed:true,can_eg:true,can_stock_module:true,can_manage:true};
let t=boot(2);t.controls.rpc.pdi_eg_context=async()=>({data:permissions});
let mounted=[],destroyed=0,busy=false;
t.window.CDEErika={mount(args){mounted.push(args);args.host.append(Object.assign(t.document.createElement('h1'),{textContent:args.mode==='stock'?'Estoque E.G.':'Desempenho E.G.'}));return{destroy(){destroyed++;},isBusy:()=>busy};}};
await t.login();ok(t.D.modules.some(m=>m.page_key==='eg'),'Contexto autorizado libera E.G.');ok(!t.D.modules.some(m=>m.page_key==='egstock'),'Estoque fica dentro do único módulo Erika Glass');
await t.M.navigate('performance');ok(t.q('[data-route=eg]')&&!t.q('[data-route=egstock]'),'Única entrada Erika Glass aparece em Desempenho');
ok(await t.M.navigate('eg'),'Rota E.G. autorizada abre');ok(mounted.at(-1).mode==='eg'&&mounted.at(-1).db===t.D.db,'Montagem recebe modo e conexão da sessão');const first=mounted.at(-1);ok(first.alive(),'Montagem ativa válida');busy=true;ok(await t.M.navigate('mypdi')===false&&t.M.route==='eg','Formulário ocupado impede troca de página');busy=false;
await t.M.navigate('egstock');ok(!first.alive()&&destroyed===1,'Troca destrói montagem anterior e invalida respostas pendentes');ok(mounted.at(-1).mode==='stock','Estoque E.G. usa modo stock');
await t.M.navigate('analytics');await t.flush();ok(!t.calls.some(([name,args])=>name==='pdi_performance_series'&&['eg','egstock'].includes(args?.p_module)),'BI genérico não consulta módulos E.G. como séries PCP');
await t.M.navigate('eg');const last=mounted.at(-1);await t.M.logout();ok(!last.alive()&&t.D.egContext.allowed===false,'Sair invalida montagem e limpa contexto E.G.');
for(const permissions of [{allowed:false,can_eg:true,can_stock_module:true},{allowed:true,can_eg:false,can_stock_module:false}]){t=boot(2);t.controls.rpc.pdi_eg_context=async()=>({data:permissions});await t.login();ok(await t.M.navigate('eg')===false&&await t.M.navigate('egstock')===false,'Atalho direto respeita contexto negado');ok(!t.D.modules.some(m=>['eg','egstock'].includes(m.page_key)),'Sem cartões E.G. fora do acesso');}
t=boot(10);t.controls.rpc.pdi_eg_context=async()=>({data:{allowed:true,can_eg:false,can_stock_module:true,can_manage:false}});await t.login();ok(await t.M.navigate('eg')===true,'Acesso só Estoque abre o contêiner Erika Glass');await t.M.navigate('stock');await t.flush();ok([...t.q('#page-content').querySelectorAll('button')].some(b=>b.textContent==='Abrir Estoque E.G.'),'Estoque oferece atalho apenas ao módulo autorizado');
console.log(`${checks} verificações E.G. de rotas, permissões, sessão, montagem e integração: OK.`);
