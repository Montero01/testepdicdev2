/* Extensão Caixa do PDI CDE. Carregada por desempenho.js, sem outra chave. */
(() => {
  'use strict';
  const PAGE = 30, BUCKET = 'pdi-cash-pdfs', MAX = 99999999999;
  const COLUMNS = 'id,cashier_id,work_date,result_cents,cash_cents,credit_cash_cents,credit_installment_cents,debit_cents,pix_cents,installment_plans,pdf_file_id,pdf_name_snapshot,cashier_name_snapshot,sector_snapshot,revision,created_at,created_by,updated_at,updated_by';
  const METHODS = [['cash_cents','Em dinheiro'],['credit_cash_cents','Crédito à vista'],['credit_installment_cents','Crédito parcelado'],['debit_cents','Débito'],['pix_cents','Pix']];
  const $ = (s,n=document) => n.querySelector(s);
  const el = (tag,cls,text) => { const n=document.createElement(tag); if(cls)n.className=cls; if(text!==undefined)n.textContent=text; return n; };
  const day = s => /^\d{4}-\d{2}-\d{2}$/.test(s||'') ? s.split('-').reverse().join('/') : '—';
  const time = s => new Intl.DateTimeFormat('pt-BR',{dateStyle:'short',timeStyle:'short',timeZone:'America/Manaus'}).format(new Date(s));
  function money(value) {
    const n=BigInt(String(value??0)); const abs=n<0n?-n:n;
    return `${n<0n?'-':''}R$ ${new Intl.NumberFormat('pt-BR').format(abs/100n)},${String(abs%100n).padStart(2,'0')}`;
  }
  const raw = cents => { const n=BigInt(String(cents??0)); return `${n/100n},${String(n%100n).padStart(2,'0')}`; };
  function parseMoney(value) {
    let s=String(value).trim();
    if (/^\d{1,3}(\.\d{3})+(,\d{1,2})?$/.test(s)) s=s.replaceAll('.','').replace(',','.');
    else if (/^\d+(,\d{1,2})?$/.test(s)) s=s.replace(',','.');
    else if (!/^\d+(\.\d{1,2})?$/.test(s)) throw new Error('Use valores em R$, com até duas casas decimais. Ex.: 1.234,56.');
    const [whole,decimal='']=s.split('.'); const cents=Number(BigInt(whole)*100n+BigInt(decimal.padEnd(2,'0')));
    if (!Number.isSafeInteger(cents)||cents<0||cents>MAX) throw new Error('Valor fora do limite permitido (até R$ 999.999.999,99).');
    return cents;
  }
  function planValue(totalRaw,amountRaw,countRaw) {
    const total=parseMoney(totalRaw),amount=parseMoney(amountRaw),count=Number(countRaw);
    if (!/^\d+$/.test(String(countRaw))||!Number.isInteger(count)||count<2||count>120||total<=0||amount<=0) throw new Error('Cada parcelamento precisa de valor positivo e quantidade de 2 a 120 parcelas.');
    const last=total-amount*(count-1);
    if (amount<Math.floor(total/count)||amount>Math.ceil(total/count)||last<=0) throw new Error('O valor das parcelas não fecha com o total. A última parcela pode ajustar apenas centavos de arredondamento.');
    return {total_cents:total,installment_cents:amount,count,last_installment_cents:last};
  }
  function msg(error) {
    if(error?.code==='23505')return 'O fechamento de hoje já foi registrado. Atualize os dados.';
    if(error?.code==='42501')return 'Seu perfil não tem permissão para esta operação. Atualize os dados ou procure a gestão.';
    if(error?.code==='22023')return error.message;
    if(error instanceof Error)return error.message;
    return 'Não foi possível concluir. Confira a conexão e atualize os dados antes de tentar novamente.';
  }
  function create(options) {
    const {db,user,root}=options;
    let disposed=false,busy=false,request=0,context=null,rows=[],count=0,page=0,logPage=0;
    let previewHandle=null;let filters={start:'',end:'',cashier:''};
    const alive=()=>!disposed&&options.isCurrent();
    function button(text,action,secondary=false) { const b=el('button',secondary?'pdi-perf-secondary':'',text);b.type='button';b.addEventListener('click',()=>{if(!busy)action();});return b; }
    function lock(value) { busy=value; if(!alive())return;root.setAttribute('aria-busy',String(value));root.querySelectorAll('input,select,textarea,button').forEach(n=>{n.disabled=value||n.dataset.fixedDisabled==='true';}); }
    function status(text,error=false) { const box=$('.pdi-perf-status',root);if(box){box.textContent=text;box.classList.toggle('is-error',error);} }
    function card(title,collapse=false) { const n=el(collapse?'details':'section','pdi-perf-card');n.append(el(collapse?'summary':'h2','',title));root.append(n);return n; }
    function field(host,label,name,value='',kind='text') {
      const wrap=el('div','pdi-perf-field');const l=el('label','',label);const input=el(kind==='textarea'?'textarea':'input');
      l.htmlFor=`pdi-cash-${name}`;input.id=l.htmlFor;input.name=name;if(kind!=='textarea')input.type=kind;input.value=value;
      if(kind==='text'){input.inputMode='decimal';input.maxLength=18;input.required=true;}
      wrap.append(l,input);host.append(wrap);return input;
    }
    function filtered(q,audit=false) {
      if(filters.cashier)q=q.eq('cashier_id',filters.cashier);
      if(!audit)return q.gte('work_date',filters.start).lte('work_date',filters.end);
      const end=new Date(`${filters.end}T12:00:00Z`);end.setUTCDate(end.getUTCDate()+1);
      return q.gte('occurred_at',`${filters.start}T00:00:00-04:00`).lt('occurred_at',`${end.toISOString().slice(0,10)}T00:00:00-04:00`);
    }
    function pager(index,total,navigate) {
      const nav=el('nav','pdi-perf-pager');nav.setAttribute('aria-label','Paginação');
      const prev=button('Anterior',()=>navigate(index-1),true),next=button('Próxima',()=>navigate(index+1),true);
      prev.disabled=index===0;next.disabled=(index+1)*PAGE>=total;
      prev.dataset.fixedDisabled=String(prev.disabled);next.dataset.fixedDisabled=String(next.disabled);
      nav.append(prev,el('span','',`Página ${index+1} de ${Math.max(1,Math.ceil(total/PAGE))}`),next);return nav;
    }
    async function refresh(notice='') {
      if(!alive())return;const r=++request;lock(true);
      try {
        const c=await db.rpc('pdi_cash_context');if(!alive()||r!==request)return;if(c.error)throw c.error;context=c.data;
        if(!context||(!context.is_cashier&&!context.can_manage))throw new Error('Não há formulário de Caixa configurado para o seu cargo.');
        if(!filters.start)filters.start=context.today.slice(0,8)+'01';if(!filters.end)filters.end=context.today;
        const q=filtered(db.from('pdi_cash_daily').select(COLUMNS,{count:'exact'})).order('work_date',{ascending:false}).order('id',{ascending:false}).range(page*PAGE,page*PAGE+PAGE-1);
        const own=context.can_collect&&context.is_cashier?db.from('pdi_cash_daily').select(COLUMNS).eq('cashier_id',user.id).eq('work_date',context.today).maybeSingle():Promise.resolve({data:null});
        const stats=context.can_manage?db.rpc('pdi_cash_dashboard',{p_start_date:filters.start,p_end_date:filters.end,p_cashier_id:filters.cashier||null}):Promise.resolve({data:null});
        const [list,today,summary]=await Promise.all([q,own,stats]);if(!alive()||r!==request)return;
        if(list.error)throw list.error;if(today.error)throw today.error;rows=list.data||[];count=list.count||0;
        render(today.data,summary,notice);
      } catch(error) { if(alive()&&r===request){root.replaceChildren();root.append(options.navigation(),el('p','pdi-perf-status is-error',msg(error)),button('Tentar novamente',()=>refresh(),true));} }
      finally {if(alive()&&r===request)lock(false);}
    }
    function render(today,summary,notice) {
      root.replaceChildren();
      root.append(window.CDEDesempenho.ui.heading({title:'Caixa',description:'Caixa · Fechamentos e formas de pagamento',badge:context.dashboard_only?'Somente consulta':context.can_correct?'Supervisão':'Registro diário',refresh:()=>{if(!busy)refresh();}}));
      const box=el('p','pdi-perf-status',notice);box.setAttribute('role','status');box.setAttribute('aria-live','polite');root.append(box);
      if(context.can_collect&&context.is_cashier){
        const c=card(`Resultado do Dia · ${day(context.today)}`);c.classList.add('pdi-perf-entry-card');c.dataset.sectorPane='entry';
        if(today){c.classList.add('pdi-perf-completed');c.append(el('p','pdi-perf-muted','Fechamento registrado. Para corrigir valores ou PDF, solicite à Diretoria a definição de uma função de correção financeira. A configuração atual do Caixa é de consulta para gerência e Diretoria.'),values(today));}
        else {c.append(el('p','pdi-perf-muted','Um registro por dia. Confira os valores antes de concluir. O PDF é opcional.'));c.append(form(null));}
      }
      if(context.can_manage)root.append(window.CDEFiles.toolbar({db,module:'cash_daily',filters:()=>({p_start:filters.start,p_end:filters.end,p_subject:filters.cashier||null}),alive,isBusy:()=>busy}));
      const filterHost=context.can_manage?card('Filtros'):card('Meus fechamentos',true);
      if(!context.can_manage)filterHost.id='pdi-cash-history';
      const f=el('form','pdi-perf-filters');
      if(context.can_manage){
        const wrap=el('div','pdi-perf-field');const label=el('label','','Op. de Caixa');label.htmlFor='pdi-cash-filter-cashier';
        const select=el('select');select.id=label.htmlFor;const all=el('option','','Todos os caixas do meu acesso');all.value='';select.append(all);
        (context.cashiers||[]).forEach(p=>{const o=el('option','',`${p.name} · ${p.sector||'Sem setor'}`);o.value=p.id;select.append(o);});select.value=filters.cashier;wrap.append(label,select);f.append(wrap);
      }
      const start=field(f,'De','start',filters.start,'date'),end=field(f,'Até','end',filters.end,'date');start.required=end.required=true;
      const apply=el('button','','Consultar');apply.type='submit';f.append(apply);
      const applyFilters=()=>{if(busy)return;
        if(!/^\d{4}-\d{2}-\d{2}$/.test(start.value)||!/^\d{4}-\d{2}-\d{2}$/.test(end.value)||start.value>end.value){status('Selecione um período válido.',true);return;}
        filters={start:start.value,end:end.value,cashier:$('#pdi-cash-filter-cashier',f)?.value||''};page=logPage=0;refresh().then(openHistory);
      };
      f.addEventListener('submit',event=>{event.preventDefault();applyFilters();});
      filterHost.append(window.CDEDesempenho.ui.periodButtons(context.today,(from,to)=>{if(busy)return;start.value=from;end.value=to;applyFilters();},filters));
      filterHost.classList.add('pdi-perf-filter-card');if(context.can_manage)filterHost.dataset.sectorCommon='filters';else filterHost.dataset.sectorPane='history';filterHost.append(f);
      if(context.can_manage)dashboard(summary);
      if(context.can_view_logs){
        const audit=card('Log do Caixa · acesso gerencial',true);audit.id='pdi-cash-audit';audit.dataset.sectorPane='audit';audit.append(el('p','pdi-perf-muted','Pesquisa mensal de eventos e exportações CSV. Datas de alteração no horário de Manaus.'));
        const body=el('div');audit.append(body);audit.addEventListener('toggle',()=>{if(audit.open&&!audit.dataset.loaded&&!busy)loadLogs(audit,body);});
      }
      if(context.dashboard_only){const docs=card('Comprovantes dos fechamentos',true);docs.dataset.sectorPane='overview';docs.append(el('p','pdi-perf-muted','Consulta dos arquivos do período, sem alterar os lançamentos.'));for(const row of rows){const entry=el('article','pdi-perf-record');entry.append(el('h3','',`${day(row.work_date)} · ${row.cashier_name_snapshot}`));if(row.pdf_file_id)entry.append(button(`Visualizar PDF · ${row.pdf_name_snapshot||'fechamento.pdf'}`,()=>viewPDF(row.pdf_file_id),true),button('Baixar PDF',()=>download(row.pdf_file_id),true));else entry.append(el('p','pdi-perf-muted','Sem PDF anexado.'));docs.append(entry);}if(!rows.length)docs.append(el('p','pdi-perf-muted','Nenhum fechamento no período.'));docs.append(pager(page,count,n=>{page=n;refresh();}));window.CDECharts.organize(root,{key:'cash',canManage:context.can_manage});return;}
      const history=context.can_manage?card('Fechamentos do período',true):filterHost;history.id='pdi-cash-history';history.dataset.sectorPane='history';
      history.append(el('p','pdi-perf-muted',`${count} fechamento(s) no período.`));
      if(!rows.length)history.append(el('p','pdi-perf-empty','Nenhum fechamento encontrado.'));
      rows.forEach(row=>{
        const item=el('article','pdi-perf-record');item.append(el('h3','',`${day(row.work_date)} · ${row.cashier_name_snapshot}`),values(row),el('p','pdi-perf-muted',`Atualizado em ${time(row.updated_at)} · revisão ${row.revision}`));
        if(context.can_correct)item.append(button('Corrigir fechamento',()=>{
          root.querySelectorAll('.pdi-cash-edit').forEach(n=>n.remove());const edit=form(row);edit.classList.add('pdi-cash-edit');item.append(edit);$('input',edit)?.focus();
        },true));history.append(item);
      });
      history.append(pager(page,count,n=>{page=n;refresh().then(openHistory);}));window.CDECharts.organize(root,{key:'cash',canManage:context.can_manage});


    }
    function openHistory(){if(alive()){const h=$('#pdi-cash-history',root);if(h)h.open=true;}}
    function dashboard(result) {
      const c=card('Resumo do período');c.id='pdi-cash-dashboard';c.dataset.sectorPane='overview';c.classList.add('pdi-perf-dashboard');c.append(el('p','pdi-perf-muted',`${day(filters.start)} a ${day(filters.end)} · ${filters.cashier?'Caixa selecionado':'Todos os caixas do meu acesso'}`));
      if(result.error||!result.data){c.append(el('p','pdi-perf-status is-error','Não foi possível calcular os indicadores. Atualize os dados.'));return;}
      const d=result.data,grid=el('dl','pdi-perf-metrics');
      for(const [label,value] of [['Resultado total',money(d.result_cents)],['Fechamentos',String(d.entry_count)],['Caixas com registro',String(d.cashier_count)]]){const n=el('div','pdi-perf-metric');n.append(el('dt','',label),el('dd','',value));grid.append(n);}
      const panel=el('section','pdi-cash-breakdown');panel.append(el('h3','','Por forma de pagamento'),el('p','pdi-perf-muted','Participação dos valores informados no fechamento.'),methodList(d,true));
      c.append(grid);window.CDECharts.cash(c,d,`${day(filters.start)} a ${day(filters.end)} · ${filters.cashier?(context.cashiers||[]).find(p=>p.id===filters.cashier)?.name||'Caixa selecionado':'Todos os caixas autorizados'}`);const detail=el('details','sector-existing');detail.append(el('summary','','Detalhamento das formas de pagamento'),panel);c.append(detail,el('p','pdi-perf-muted pdi-perf-footnote','Crédito parcelado considera o valor total das vendas informadas.'));
    }
    function methodList(row,chart=false) {
      const dl=el('dl','pdi-cash-methods');METHODS.forEach(([key,label])=>{const n=el('div');n.append(el('dt','',label),el('dd','',money(row[key])));
        if(chart){const track=el('div','pdi-perf-rank-track');track.setAttribute('aria-hidden','true');const bar=el('div','pdi-perf-rank-fill');const total=BigInt(String(row.result_cents||0));const part=BigInt(String(row[key]||0));bar.style.width=`${total>0n?Number(part*10000n/total)/100:0}%`;track.append(bar);n.append(track);}
        dl.append(n);});return dl;
    }
    function values(row) {
      const n=el('div');n.append(el('strong','pdi-perf-result',money(row.result_cents)),methodList(row));
      if(row.installment_plans?.length){const plans=el('details','pdi-cash-plans-view');plans.append(el('summary','','Detalhar crédito parcelado'));
        row.installment_plans.forEach((p,i)=>plans.append(el('p','pdi-perf-muted',`${i+1}. Total ${money(p.total_cents)} · ${p.count} parcelas · ${money(p.installment_cents)} nas primeiras ${p.count-1} · última ${money(p.last_installment_cents)}`)));n.append(plans);}
      if(row.pdf_file_id){n.append(button('Visualizar PDF',()=>viewPDF(row.pdf_file_id),true));n.append(button(`Baixar PDF · ${row.pdf_name_snapshot||'fechamento.pdf'}`,()=>download(row.pdf_file_id),true));}else n.append(el('p','pdi-perf-muted','Sem PDF anexado.'));
      return n;
    }
    function form(row) {
      const prefix=row?'edit':'create',f=el('form','pdi-perf-form pdi-cash-form'),grid=el('div','pdi-cash-money-grid');f.append(grid);
      const total=field(grid,'Resultado do Dia (Total R$)',`${prefix}-result`,row?raw(row.result_cents):'');
      total.parentElement.classList.add('pdi-cash-total-field');total.placeholder='0,00';
      const inputs={};METHODS.filter(([key])=>key!=='credit_installment_cents').forEach(([key,label])=>{inputs[key]=field(grid,`${label} R$`,`${prefix}-${key}`,raw(row?.[key]));});
      const plans=el('fieldset','pdi-cash-plan-editor');plans.append(el('legend','','Crédito parcelado'));
      plans.append(el('p','pdi-perf-muted','Adicione um parcelamento por venda ou grupo com as mesmas condições. A última parcela ajusta apenas centavos de arredondamento.'));
      const planHost=el('div');plans.append(planHost);let serial=0;const lines=[];
      const installmentTotal=el('p','pdi-cash-installment-total','Total parcelado: R$ 0,00');
      const balance=el('p','pdi-cash-balance');balance.setAttribute('role','status');balance.setAttribute('aria-live','polite');
      const collect=()=>lines.map(line=>planValue(line.total.value,line.amount.value,line.count.value));
      function calculate(){
        try{const ps=collect(),parcel=ps.reduce((a,p)=>a+p.total_cents,0);installmentTotal.textContent=`Total parcelado: ${money(parcel)}`;
          const sum=Object.values(inputs).reduce((a,n)=>a+parseMoney(n.value),0)+parcel;
          if(!total.value){balance.textContent=`Soma das formas de pagamento: ${money(sum)}. Informe o Resultado do Dia.`;return;}
          const difference=parseMoney(total.value)-sum;balance.textContent=difference===0?`Conferido: formas de pagamento somam ${money(sum)}.`:`Diferença a conferir: ${money(difference)}. Soma das formas: ${money(sum)}.`;
          balance.classList.toggle('is-error',difference!==0);
        }catch{installmentTotal.textContent='Total parcelado: preencha os dados de todas as linhas.';balance.textContent='Preencha valores válidos para conferir a soma.';balance.classList.add('is-error');}
      }
      function addLine(data=null){
        if(lines.length>=200){status('Limite de 200 parcelamentos por fechamento.',true);return;}
        const i=++serial,n=el('div','pdi-cash-plan-line');
        const t=field(n,'Valor total R$',`${prefix}-plan-${i}-total`,data?raw(data.total_cents):'');
        const a=field(n,'Valor da parcela R$',`${prefix}-plan-${i}-amount`,data?raw(data.installment_cents):'');
        const q=field(n,'Quantidade de parcelas',`${prefix}-plan-${i}-count`,String(data?.count??2),'number');q.required=true;q.min='2';q.max='120';q.step='1';
        const last=el('p','pdi-perf-muted');const line={total:t,amount:a,count:q,node:n};lines.push(line);
        const update=()=>{try{const p=planValue(t.value,a.value,q.value);last.textContent=`Última parcela: ${money(p.last_installment_cents)}`;}catch{last.textContent='Confira total, valor e quantidade de parcelas.';}calculate();};
        [t,a,q].forEach(input=>input.addEventListener('input',update));
        n.append(last,button('Remover parcelamento',()=>{lines.splice(lines.indexOf(line),1);n.remove();calculate();},true));planHost.append(n);update();
      }
      plans.append(button('Adicionar parcelamento',()=>{addLine();calculate();},true),installmentTotal);f.append(plans);
      (row?.installment_plans||[]).forEach(addLine);
      const file=field(f,'Comprovante em PDF (opcional)',`${prefix}-pdf`,'','file');file.accept='application/pdf,.pdf';file.parentElement.classList.add('pdi-cash-upload');file.parentElement.append(el('p','pdi-perf-muted','Selecione um PDF de até 10 MB.'));
      let remove=null;if(row?.pdf_file_id){
        f.append(el('p','pdi-perf-muted',`PDF atual: ${row.pdf_name_snapshot}. Deixe o arquivo vazio para manter.`));
        const label=el('label','pdi-cash-checkbox');remove=el('input');remove.type='checkbox';remove.id=`pdi-cash-${prefix}-remove-pdf`;label.append(remove,document.createTextNode(' Retirar o PDF atual nesta correção (a versão anterior ficará no log).'));f.append(label);
        file.addEventListener('change',()=>{if(file.files?.length)remove.checked=false;});
      }
      let reason=null;if(row){reason=field(f,'Justificativa da correção (10 a 300 caracteres)',`${prefix}-reason`,'','textarea');reason.required=true;reason.minLength=10;reason.maxLength=300;}
      f.append(balance);const save=el('button','',row?'Salvar correção':'Registrar fechamento de hoje');save.type='submit';f.append(save);
      if(row)f.append(button('Cancelar',()=>f.remove(),true));
      [total,...Object.values(inputs)].forEach(n=>n.addEventListener('input',calculate));calculate();
      let draftId=row?.id||null,cached=null;
      f.addEventListener('submit',async event=>{
        event.preventDefault();if(busy)return;
        let payload,selected=file.files?.[0]||null;
        try{
          const ps=collect();payload={result_cents:parseMoney(total.value),installment_plans:ps};Object.entries(inputs).forEach(([key,input])=>{payload[key]=parseMoney(input.value);});
          const sum=Object.keys(inputs).reduce((a,key)=>a+payload[key],0)+ps.reduce((a,p)=>a+p.total_cents,0);
          if(sum!==payload.result_cents)throw new Error('O Resultado do Dia deve ser igual à soma de todas as formas de pagamento.');
          if(row){payload.edit_reason=reason.value.trim();if(payload.edit_reason.length<10||payload.edit_reason.length>300)throw new Error('Informe uma justificativa de 10 a 300 caracteres.');}
          if(selected){
            if(selected.size<8||selected.size>10485760||!/\.pdf$/i.test(selected.name)||selected.name.length>180)throw new Error('Selecione um PDF de até 10 MB, com nome de até 180 caracteres.');
          }
        }catch(error){status(msg(error),true);return;}
        lock(true);status(selected?'Conferindo dados e enviando PDF…':'Conferindo e salvando fechamento…');
        try{
          const check=await db.rpc('pdi_cash_context');if(!alive())return;if(check.error)throw check.error;
          if(!row){
            if(check.data.today!==context.today){await refresh('O dia mudou. Confira o novo dia antes de registrar.');return;}
            const existing=await db.from('pdi_cash_daily').select('id').eq('cashier_id',user.id).eq('work_date',context.today).maybeSingle();if(!alive())return;if(existing.error)throw existing.error;
            if(existing.data){await refresh('O fechamento de hoje já está registrado.');return;}
          }
          draftId||=window.crypto.randomUUID();
          let pdfId=remove?.checked?null:(row?.pdf_file_id||null);
          if(selected){
            const header=String.fromCharCode(...new Uint8Array(await selected.slice(0,5).arrayBuffer()));if(!alive())return;
            if(header!=='%PDF-')throw new Error('O arquivo selecionado não tem um cabeçalho PDF válido.');
            if(!cached||cached.file!==selected){
              const reserved=await db.rpc('pdi_cash_reserve_pdf',{p_entry_id:draftId,p_cashier_id:row?.cashier_id||user.id,p_work_date:row?.work_date||context.today,p_original_name:selected.name,p_size_bytes:selected.size});
              if(!alive())return;if(reserved.error)throw reserved.error;
              const uploaded=await db.storage.from(BUCKET).upload(reserved.data.path,selected,{contentType:'application/pdf',upsert:false,cacheControl:'0'});
              if(!alive())return;if(uploaded.error){await db.rpc('pdi_cash_file_event',{p_file_id:reserved.data.id,p_action:'PDF_UPLOAD_FAILED'});throw uploaded.error;}cached={file:selected,id:reserved.data.id,confirmed:false};
            }
            if(!cached.confirmed){const confirmed=await db.rpc('pdi_cash_file_event',{p_file_id:cached.id,p_action:'PDF_UPLOAD_CONFIRMED'});if(!alive())return;if(confirmed.error)throw confirmed.error;cached.confirmed=true;}
            pdfId=cached.id;
          }
          payload.pdf_file_id=pdfId;
          const result=row
            ? await db.from('pdi_cash_daily').update(payload).eq('id',row.id).eq('revision',row.revision).select('id,revision')
            : await db.from('pdi_cash_daily').insert({...payload,id:draftId,cashier_id:user.id,work_date:context.today});
          if(!alive())return;if(result.error)throw result.error;
          if(row&&!result.data?.length){status('O fechamento mudou ou sua permissão foi alterada. Atualize os dados e revise a correção antes de tentar novamente.',true);return;}
          await refresh(row?'Correção salva no log de auditoria.':'Fechamento registrado com sucesso.');if(row)openHistory();
        }catch(error){if(alive())status(msg(error),true);}
        finally{if(alive())lock(false);}
      });return f;
    }
    async function viewPDF(id){
      if(busy)return;lock(true);status('Abrindo PDF…');let requested=false;
      try{const event=await db.rpc('pdi_cash_file_event',{p_file_id:id,p_action:'PDF_VIEW_REQUESTED'});if(event.error)throw event.error;requested=true;if(!alive())return;
      const f=await db.from('pdi_cash_files').select('storage_path,original_name').eq('id',id).single();if(f.error||!f.data)throw new Error('PDF indisponível para seu perfil.');
      const result=await db.storage.from(BUCKET).download(f.data.storage_path);if(result.error)throw result.error;if(!alive())return;
      previewHandle?.destroy();previewHandle=window.CDEFiles.preview(result.data,f.data.original_name,()=>download(id));
      const logged=await db.rpc('pdi_cash_file_event',{p_file_id:id,p_action:'PDF_VIEW_OPENED'});if(alive())status(logged.error?'Janela aberta; confirmação no log pendente.':'Janela de visualização aberta e registrada no log.');
      }catch(error){if(requested&&alive())await db.rpc('pdi_cash_file_event',{p_file_id:id,p_action:'PDF_VIEW_FAILED'});if(alive())status(msg(error),true);}finally{if(alive())lock(false);}
    }
    async function download(id){
      if(busy)return;let requestedDownload=false;lock(true);status('Preparando PDF para download…');
      try{
        const requested=await db.rpc('pdi_cash_file_event',{p_file_id:id,p_action:'PDF_DOWNLOAD_REQUESTED'});if(!alive())return;if(requested.error)throw requested.error;requestedDownload=true;
        const f=await db.from('pdi_cash_files').select('storage_path,original_name').eq('id',id).single();if(!alive())return;if(f.error||!f.data)throw new Error('PDF indisponível para seu perfil. Atualize os dados.');
        const result=await db.storage.from(BUCKET).download(f.data.storage_path);if(!alive())return;if(result.error)throw result.error;
        const url=URL.createObjectURL(result.data);const a=el('a');a.href=url;a.download=f.data.original_name;root.append(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),10000);const logged=await db.rpc('pdi_cash_file_event',{p_file_id:id,p_action:'PDF_DOWNLOAD_TRIGGERED'});if(alive())status(logged.error?'Download acionado; não foi possível confirmar esse acionamento no log.':'Download do PDF acionado e registrado no log.');
      }catch(error){if(requestedDownload&&alive())await db.rpc('pdi_cash_file_event',{p_file_id:id,p_action:'PDF_DOWNLOAD_FAILED'});if(alive())status(msg(error),true);}finally{if(alive())lock(false);}
    }
    async function loadLogs(details,body){if(!context.can_view_logs||busy||!alive())return;details.dataset.loaded='true';window.CDEAudit.mount({db,host:body,module:'cash_daily',subjectId:filters.cashier||null,today:context.today,alive:()=>alive()&&body.isConnected});}
    return Object.freeze({refresh,isBusy:()=>busy,destroy:()=>{previewHandle?.destroy();previewHandle=null;disposed=true;request++;context=null;rows=[];}});
  }
  window.CDECaixa=Object.freeze({create});
})();
