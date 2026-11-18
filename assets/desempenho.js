/* PDI CDE — módulo adicional. Não contém chaves nem substitui o app.js. */
(() => {
  'use strict';
  const NS = 'http://www.w3.org/2000/svg';
  const PAGE = 30;
  const moduleURL = document.currentScript?.src || document.baseURI;
  let cashLoading = null;
  const $ = (s, n = document) => n.querySelector(s);
  const fmt = n => new Intl.NumberFormat('pt-BR', { maximumFractionDigits: 3 }).format(Number(n));
  const day = s => /^\d{4}-\d{2}-\d{2}$/.test(s || '') ? s.split('-').reverse().join('/') : '—';
  const time = s => new Intl.DateTimeFormat('pt-BR', { dateStyle: 'short', timeStyle: 'short', timeZone: 'America/Manaus' }).format(new Date(s));
  function el(tag, cls, text) {
    const n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text !== undefined) n.textContent = text;
    return n;
  }
  function icon(name = 'chart') {
    const svg = document.createElementNS(NS, 'svg');
    for (const [k, v] of Object.entries({ viewBox: '0 0 24 24', width: '20', height: '20', fill: 'none', stroke: 'currentColor', 'stroke-width': '1.8', 'aria-hidden': 'true', focusable: 'false', class: 'pdi-perf-icon' })) svg.setAttribute(k, v);
    const p = document.createElementNS(NS, 'path');
    p.setAttribute('d', ({chart:'M4 20V10m8 10V4m8 16v-7M2 22h20',refresh:'M20 8a8 8 0 1 0 0 8M20 3v5h-5',wallet:'M3 7h17v13H3zM3 7V4h15v3M15 12h5v4h-5z',check:'m5 12 4 4L19 6',calendar:'M4 5h16v16H4zM8 2v6m8-6v6M4 10h16',plus:'M12 4v16M4 12h16'})[name] || 'M4 20V10m8 10V4m8 16v-7M2 22h20'); svg.append(p); return svg;
  }
  function button(text, action, secondary = false) {
    const b = el('button', secondary ? 'pdi-perf-secondary' : '', text); b.type = 'button';
    b.addEventListener('click', action); return b;
  }
  function field(form, label, kind, name, value = '') {
    const wrap = el('div', 'pdi-perf-field');
    const id = `pdi-perf-${name}`;
    const l = el('label', '', label); l.htmlFor = id;
    const input = el(kind === 'textarea' ? 'textarea' : 'input'); input.id = id; input.name = name;
    if (kind !== 'textarea') input.type = kind;
    input.value = value; wrap.append(l, input); form.append(wrap); return input;
  }
  function heading({title, description, badge, refresh: reload}) {
    const head = el('header','pdi-perf-heading');
    const content = el('div','pdi-perf-heading-copy');
    content.append(el('p','pdi-perf-eyebrow','CDE · DESEMPENHO'),el('h1','',title),el('p','pdi-perf-muted',description));
    const actions = el('div','pdi-perf-heading-actions');
    actions.append(el('span','pdi-perf-access-badge',badge));
    const update = button('Atualizar dados',reload,true); update.prepend(icon('refresh')); actions.append(update);
    head.append(content,actions); return head;
  }
  function periods(today) {
    const [year,month] = today.split('-').map(Number);
    const before = new Date(Date.UTC(year,month-2,1)).toISOString().slice(0,10);
    const end = new Date(Date.UTC(year,month-1,0)).toISOString().slice(0,10);
    return [['Hoje',today,today],['Este mês',today.slice(0,8)+'01',today],['Mês anterior',before,end]];
  }
  function periodButtons(today,apply,range=null) {
    const nav=el('div','pdi-perf-periods');nav.setAttribute('role','group');nav.setAttribute('aria-label','Períodos rápidos');
    let selected=false;
    for (const [label,start,end] of periods(today)) {
      const b=button(label,()=>apply(start,end),true);const match=!selected&&range?.start===start&&range?.end===end;b.setAttribute('aria-pressed',String(match));if(match)selected=true;nav.append(b);
    }
    return nav;
  }
  function parseM2(raw) {
    const value = String(raw).trim();
    if (!/^\d{1,9}([.,]\d{1,3})?$/.test(value)) throw new Error('Informe os m² sem separador de milhar, com até 3 casas decimais. Ex.: 12,350.');
    return value.replace(',', '.');
  }
  function parseOrders(raw, m2) {
    const items = String(raw).trim().split(/[\s,;]+/).filter(Boolean);
    if (items.length > 200 || items.some(x => !/^\d{1,20}$/.test(x))) throw new Error('Informe até 200 pedidos, somente números, com até 20 dígitos cada. Separe por vírgula, espaço ou linha.');
    if (new Set(items).size !== items.length) throw new Error('Há pedidos repetidos na lista. Remova as repetições.');
    if (Number(m2) > 0 && !items.length) throw new Error('Informe os pedidos que correspondem aos m² salvos.');
    return items;
  }
  function message(error) {
    if (error?.code === '23505') return 'O lançamento de hoje já foi registrado. Atualize a tela para consultá-lo.';
    if (error?.code === '42501') return 'Seu perfil não tem permissão para esta operação. Atualize a tela ou procure a gestão.';
    if (error?.code === '22023') return error.message;
    if (error instanceof Error) return error.message;
    return 'Não foi possível concluir a operação. Verifique a conexão e tente novamente.';
  }
  let db, user, profile, root, menu, mountMode, context, cashController;
  let activeModule = 'pcp';
  const isCashPosition = value => ['opdecaixa','opcaixa','operadordecaixa','operadoradecaixa','caixa'].includes(String(value || '').trim().toLowerCase().replace(/[.\s]+/g, ''));
  let epoch = 0, request = 0, busy = false, subscription;
  let wasteData={rows:[],count:0},wastePage=0,recordWaste=new Map();
  let page = 0, logPage = 0, rankPage = 0, dashboard = null, rows = [], count = 0, editId = null;
  let filters = { pcp: '', start: '', end: '' };
  function current(e) { return e === epoch && !!user; }
  function status(text, error = false) {
    const box = root && $('.pdi-perf-status', root);
    if (box) { box.textContent = text; box.classList.toggle('is-error', error); }
  }
  function lock(value) {
    busy = value;
    if (root) { root.setAttribute('aria-busy', String(value)); root.querySelectorAll('button,input,textarea,select').forEach(n => { n.disabled = value || n.dataset.fixedDisabled === 'true'; }); }
    if (menu) menu.disabled = value;
  }
  function reset() {
    cashController?.destroy(); cashController = null;
    epoch++; request++; busy = false; context = null; dashboard = null; rows = []; wasteData={rows:[],count:0};recordWaste.clear();editId = null;
    root?.remove(); menu?.remove(); root = menu = null;
    const nav = $('#pdi-perf-employee-nav'); nav?.remove();
    const base = $('#pdi-perf-employee-base'); if (base) base.hidden = false;
    if (mountMode === 'management' && $('#tab-overview')?.classList.contains('hidden') && typeof window.switchTab === 'function') window.switchTab('overview');
    user = profile = null;
  }
  function mount() {
    const staff = profile.is_master === true || ['master', 'diretor', 'diretoria', 'gerente', 'supervisor'].includes(String(profile.role).trim().toLowerCase());
    const pcp = String(profile.position || '').trim().toLowerCase() === 'pcp';
    if (!staff && !pcp && !isCashPosition(profile.position)) return;
    mountMode = staff ? 'management' : 'employee';
    root = el('section', 'pdi-perf'); root.setAttribute('aria-label', 'Desempenho'); root.hidden = true;
    root.append(el('p', 'pdi-perf-status', 'Abra Desempenho para carregar os dados.'));
    $('.pdi-perf-status', root).setAttribute('role', 'status');
    if (staff) {
      const host = $('#management-view'); const tabs = $('.tabs', host);
      if (!host || !tabs) return;
      root.id = 'tab-desempenho'; root.classList.add('tab-content', 'hidden'); root.hidden = false;
      menu = button('Desempenho', open); menu.className = 'tab-btn pdi-perf-menu'; menu.dataset.tab = 'desempenho'; menu.prepend(icon());
      tabs.classList.add('pdi-perf-tabs'); tabs.append(menu); host.append(root);
    } else {
      const host = $('#employee-view'); if (!host) return;
      let base = $('#pdi-perf-employee-base');
      if (!base) {
        base = el('div'); base.id = 'pdi-perf-employee-base';
        [...host.children].filter(n => !n.classList.contains('header')).forEach(n => base.append(n)); host.append(base);
      }
      const nav = el('nav', 'pdi-perf-nav'); nav.id = 'pdi-perf-employee-nav'; nav.setAttribute('aria-label', 'Área do colaborador');
      const home = button('Meu PDI', () => { if (busy || cashController?.isBusy()) return; base.hidden = false; root.hidden = true; home.setAttribute('aria-current', 'page'); menu.removeAttribute('aria-current'); }, true);
      home.setAttribute('aria-current', 'page'); menu = button('Desempenho', () => { home.removeAttribute('aria-current'); menu.setAttribute('aria-current', 'page'); open(); }, true); menu.prepend(icon());
      nav.append(home, menu); host.insertBefore(nav, base); host.append(root);
    }
  }
  async function open() {
    if (busy || cashController?.isBusy()) return;
    if (mountMode === 'management') {
      if (typeof window.switchTab !== 'function') { status('Não foi possível localizar a navegação do PDI.', true); return; }
      window.switchTab('desempenho');
    } else { $('#pdi-perf-employee-base').hidden = true; root.hidden = false; }
    await refresh();
  }
  async function openModule(name) {
    if (!['pcp','cash'].includes(name) || !window.CDEModelData.modules.some(m=>m.page_key===name) || !user || busy || cashController?.isBusy()) return false;
    const own = isCashPosition(profile.position) ? 'cash' : 'pcp';
    if (mountMode !== 'management' && name !== own) return false;
    if (activeModule !== name) { cashController?.destroy(); cashController = null; activeModule = name; request++; }
    await open(); return true;
  }
  function moduleNavigation() {
    const nav = el('nav', 'pdi-perf-module-nav'); nav.setAttribute('aria-label', 'Módulos de desempenho');
    if (mountMode !== 'management') { nav.hidden = true; return nav; }
    for (const [key,label] of [['pcp','PCP'],['cash','Caixa']].filter(([key])=>window.CDEModelData.modules.some(m=>m.page_key===key))) {
      const b = button(label, () => {
        if (busy || cashController?.isBusy() || activeModule === key) return;
        cashController?.destroy(); cashController = null; activeModule = key; request++;
        refresh();
      }, true);
      b.prepend(icon(key === 'cash' ? 'wallet' : 'chart'));
      if (activeModule === key) b.setAttribute('aria-current', 'page'); nav.append(b);
    }
    return nav;
  }
  async function loadCashCode() {
    if (window.CDECaixa) return;
    if (!cashLoading) cashLoading = new Promise((resolve,reject) => {
      const script = document.createElement('script'); script.src = new URL('desempenho-caixa.js', moduleURL).href;
      let settled = false;
      const finish = error => { if (settled) return; settled = true; clearTimeout(timer); script.onload = script.onerror = null;
        if (error) { script.remove(); cashLoading = null; reject(error); } else resolve(); };
      const timer = setTimeout(() => finish(new Error('Não foi possível carregar o módulo Caixa. Confira se desempenho-caixa.js foi publicado junto do PDI.')),15000);
      script.onload = () => finish(window.CDECaixa ? null : new Error('Módulo Caixa indisponível. Atualize os arquivos.'));
      script.onerror = () => finish(new Error('Publique desempenho-caixa.js na mesma pasta do PDI e tente novamente.'));
      document.head.append(script);
    });
    await cashLoading;
  }
  async function refreshCash(notice) {
    const e = epoch, r = ++request; lock(true);
    try {
      await loadCashCode(); if (!current(e) || r !== request) return;
      if (!cashController) cashController = window.CDECaixa.create({db,user,profile,root,navigation:moduleNavigation,isCurrent:() => current(e) && activeModule === 'cash'});
      await cashController.refresh(notice);
    } catch (error) {
      if (current(e) && r === request) root.replaceChildren(moduleNavigation(),el('p','pdi-perf-status is-error',message(error)),button('Tentar novamente',()=>refresh(),true));
    } finally { if (current(e) && r === request) lock(false); }
  }
  function filterQuery(q, audit = false) {
    if (filters.pcp) q = q.eq('pcp_id', filters.pcp);
    if (audit) {
      q = q.gte('occurred_at', `${filters.start}T00:00:00-04:00`);
      const next = new Date(`${filters.end}T12:00:00Z`); next.setUTCDate(next.getUTCDate() + 1);
      return q.lt('occurred_at', `${next.toISOString().slice(0, 10)}T00:00:00-04:00`);
    }
    return q.gte('work_date', filters.start).lte('work_date', filters.end);
  }
  async function refresh(notice = '') {
    if (activeModule === 'cash') return refreshCash(notice);
    const e = epoch; const r = ++request; lock(true);
    try {
      const result = await db.rpc('pdi_desempenho_context');
      if (!current(e) || r !== request) return;
      if (result.error) throw result.error;
      context = result.data;
      if (!context || (!context.is_pcp && !context.can_manage)) { root.replaceChildren(el('p', 'pdi-perf-status', 'Não há formulário de desempenho configurado para seu cargo.')); return; }
      if (!filters.start) filters.start = context.today.slice(0, 8) + '01';
      if (!filters.end) filters.end = context.today;
      const q = context.dashboard_only ? Promise.resolve({ data: [], count: 0 }) : filterQuery(db.from('pdi_pcp_daily').select('id,pcp_id,work_date,m2_saved,order_numbers,m2_analyzed,pcp_name_snapshot,sector_snapshot,revision,created_at,created_by,updated_at,updated_by', { count: 'exact' }))
        .order('work_date', { ascending: false }).order('id', { ascending: false }).range(page * PAGE, page * PAGE + PAGE - 1);
      const todayQuery = context.can_collect && context.is_pcp ? db.from('pdi_pcp_daily').select('id,m2_saved,m2_analyzed,order_numbers').eq('pcp_id', user.id).eq('work_date', context.today).maybeSingle() : Promise.resolve({ data: null });
      const dashboardQuery = context.can_manage
        ? db.rpc('pdi_pcp_dashboard', { p_start_date: filters.start, p_end_date: filters.end, p_pcp_id: filters.pcp || null })
        : Promise.resolve({ data: null });
      const [list, today, summary, wasted] = await Promise.all([q, todayQuery, dashboardQuery,db.rpc('pdi_pcp_waste_entries',{p_start_date:filters.start,p_end_date:filters.end,p_pcp_id:filters.pcp||null,p_offset:wastePage*PAGE})]);
      if (!current(e) || r !== request) return;
      if (list.error) throw list.error; if (today.error) throw today.error;
      if(wasted.error)throw wasted.error;wasteData={rows:wasted.data?.rows||[],count:wasted.data?.count||0};
      rows = list.data || []; count = list.count || 0; editId = null;
      const recordFiles=rows.length?await db.from('pdi_pcp_waste').select('entry_id,m2_wasted').in('entry_id',rows.map(row=>row.id)): {data:[]};
      if(!current(e)||r!==request)return;if(recordFiles.error)throw recordFiles.error;recordWaste=new Map((recordFiles.data||[]).map(w=>[w.entry_id,w.m2_wasted]));
      dashboard = summary.error ? null : summary.data;
      render(today.data, notice, summary.error);
    } catch (error) { if (current(e) && r === request) {
      // Não exibe números antigos como se correspondessem a um novo filtro.
      root.replaceChildren(el('p', 'pdi-perf-status is-error', message(error)), button('Tentar novamente', () => refresh(), true));
    } }
    finally { if (current(e) && r === request) lock(false); }
  }
  function card(title, collapsible = false) {
    const n = el(collapsible ? 'details' : 'section', 'pdi-perf-card');
    const h = el(collapsible ? 'summary' : 'h2', '', title); n.append(h); root.append(n); return n;
  }
  function render(today, notice, dashboardError) {
    root.replaceChildren();
    root.append(heading({title:'PCP',description:'PCP · Área recuperada em produção',badge:context.dashboard_only?'Somente consulta':context.can_correct?'Supervisão':'Registro diário',refresh:()=>refresh()}));
    const msg = el('p', 'pdi-perf-status', notice); msg.setAttribute('role', 'status'); msg.setAttribute('aria-live', 'polite'); root.append(msg);
    if (context.can_collect && context.is_pcp) {
      const c = card(`Resultado PCP · ${day(context.today)}`); c.classList.add('pdi-perf-entry-card');c.dataset.sectorPane='entry';
      if (today) {
        c.classList.add('pdi-perf-completed'); c.prepend(el('span','pdi-perf-access-badge','Dia registrado'));
        c.append(el('strong', 'pdi-perf-result', `Salvo: ${fmt(today.m2_saved)} m² · Analisado: ${today.m2_analyzed===null?'não informado':fmt(today.m2_analyzed)+' m²'}`), el('p', 'pdi-perf-muted', `Pedidos: ${today.order_numbers.join(', ') || 'Nenhum'}.
O lançamento do dia foi concluído. Para correções, procure a supervisão.`));
      } else {
        c.append(el('p', 'pdi-perf-muted', 'Um lançamento por dia. Informe o total antes de registrar. A supervisão pode corrigir o lançamento com justificativa.'));
        const form = el('form', 'pdi-perf-form pdi-perf-pcp-form');
        const m2 = field(form, 'M² Salvo Dia', 'text', 'create-m2'); m2.inputMode = 'decimal'; m2.required = true; m2.maxLength = 13; m2.placeholder = 'Ex.: 12,350';
        const analyzed=field(form,'M² Analisado','text','create-analyzed');analyzed.inputMode='decimal';analyzed.required=true;analyzed.maxLength=13;analyzed.placeholder='Ex.: 100,000';
        const orders = field(form, 'Números dos pedidos para auditoria', 'textarea', 'create-orders'); orders.rows = 3; orders.maxLength = 4400; orders.placeholder = 'Ex.: 001234, 001235';
        const hint = el('p', 'pdi-perf-muted', 'Use números separados por vírgula, espaço ou linha. Os pedidos podem ficar vazios somente quando analisado e salvo forem zero.'); form.append(hint);
        const save = el('button', '', 'Registrar resultado de hoje'); save.type = 'submit'; form.append(save);
        form.addEventListener('submit', event => { event.preventDefault(); createEntry(m2.value, orders.value,analyzed.value); }); c.append(form);
      }
    }
    const manageEpoch=epoch,manageRoot=root;window.CDEManagement.deletion({db,host:root,module:'pcp_m2',filters:()=>({start:filters.start,end:filters.end}),refresh:()=>refresh(),alive:()=>current(manageEpoch)&&manageRoot.isConnected});
    const filterHost = context.can_manage ? card('Filtros') : card('Lançamentos do período', true);
    const exportEpoch=epoch,exportRoot=root;if(context.can_manage)root.append(window.CDEFiles.toolbar({db,module:'pcp_m2',filters:()=>({p_start:filters.start,p_end:filters.end,p_subject:filters.pcp||null}),alive:()=>current(exportEpoch)&&exportRoot.isConnected,isBusy:()=>busy}));
    const filter = el('form', 'pdi-perf-filters');
    if (context.can_manage) {
      const wrap = el('div', 'pdi-perf-field'); const label = el('label', '', 'PCP'); label.htmlFor = 'pdi-perf-pcp';
      const select = el('select'); select.id = 'pdi-perf-pcp';
      const all = el('option', '', 'Todos os PCPs do meu acesso'); all.value = ''; select.append(all);
      (context.pcps || []).forEach(p => { const o = el('option', '', `${p.name} · ${p.sector || 'Sem setor'}`); o.value = p.id; select.append(o); });
      select.value = filters.pcp; wrap.append(label, select); filter.append(wrap);
    }
    const start = field(filter, 'De', 'date', 'start', filters.start); start.required = true;
    const end = field(filter, 'Até', 'date', 'end', filters.end); end.required = true;
    const apply = el('button', '', 'Consultar'); apply.type = 'submit'; filter.append(apply);
    const applyFilters = () => { if (busy || cashController?.isBusy()) return;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(start.value) || !/^\d{4}-\d{2}-\d{2}$/.test(end.value) || start.value > end.value) { status('Selecione um período válido: a data inicial deve ser anterior ou igual à final.', true); return; }
      filters = { start: start.value, end: end.value, pcp: $('#pdi-perf-pcp', filter)?.value || '' }; page = logPage = rankPage = wastePage = 0;
      refresh().then(() => { const h = root && $('[data-sector-pane="history"]', root); if (h) h.open = true; });
    };
    filter.addEventListener('submit',event=>{event.preventDefault();applyFilters();});
    filterHost.append(periodButtons(context.today,(from,to)=>{if(busy)return;start.value=from;end.value=to;applyFilters();},filters));
    filterHost.classList.add('pdi-perf-filter-card');if(context.can_manage)filterHost.dataset.sectorCommon='filters';else filterHost.dataset.sectorPane='history';
    filterHost.append(filter);
    if (context.can_manage){renderPcpDashboard(dashboardError);renderWasteManagement();}
    if (context.can_view_logs) {
      const logs = card('Log de auditoria · acesso gerencial', true); logs.id = 'pdi-perf-audit';logs.dataset.sectorPane='audit';
      logs.append(el('p', 'pdi-perf-muted', 'Pesquisa mensal de eventos e arquivos CSV dos meses anteriores. Horários de Manaus.'));
      const body = el('div', 'pdi-perf-audit-body'); logs.append(body);
      logs.addEventListener('toggle', () => { if (logs.open && !logs.dataset.loaded) loadLogs(body, logs); });
    }
    if (context.dashboard_only) {
      window.CDECharts.organize(root,{key:'pcp',canManage:context.can_manage});return;
    }
    const history = context.can_manage ? card('Lançamentos do período', true) : filterHost;history.dataset.sectorPane='history';
    history.append(el('p', 'pdi-perf-muted', `${count} lançamento(s) no período. Cada lançamento corresponde a um PCP por dia.`));
    if (!rows.length) history.append(el('p', 'pdi-perf-empty', 'Nenhum lançamento encontrado neste período.'));
    rows.forEach(row => history.append(record(row)));
    history.append(pager(page, count, n => { page = n; refresh().then(() => { const h = root && $('[data-sector-pane="history"]', root); if (h) h.open = true; }); }));
    if (context.can_correct) history.append(el('p', 'pdi-perf-muted', 'Selecione “Corrigir” em um lançamento existente. Não há cadastro em nome de outro PCP nesta etapa.'));window.CDECharts.organize(root,{key:'pcp',canManage:context.can_manage});


  }
  const areaUnits=value=>{const[w,f='']=String(value).split('.');return BigInt(w)*1000n+BigInt((f+'000').slice(0,3));};
  const areaValue=value=>value===null||value===undefined?'Não informado':`${fmt(value)} m²`;
  const percent=value=>value===null||value===undefined?'—':`${fmt(value)}%`;
  function renderPcpDashboard(error){
    const c=card('Produção · indicadores do período');c.dataset.sectorPane='overview';if(error||!dashboard){c.append(el('p','pdi-perf-status is-error','Não foi possível consultar os indicadores.'));return;}
    const metrics=el('dl','pdi-perf-metrics');for(const[label,value]of[['M² analisados',areaValue(dashboard.total_analyzed)],['M² salvos',areaValue(dashboard.total_m2)],['M² desperdiçados',areaValue(dashboard.total_wasted)],['Aproveitamento',percent(dashboard.utilization_percent)],['Taxa de desperdício',percent(dashboard.waste_percent)],['Recuperação · salvo/analisado',percent(dashboard.recovery_percent)]]){const n=el('div','pdi-perf-metric');n.append(el('dt','',label),el('dd','',value));metrics.append(n);}c.append(metrics);
    c.append(el('p','pdi-perf-muted',`${dashboard.entry_count} lançamento(s). ${dashboard.pending_count||0} pendente(s) de análise ou desperdício. Aproveitamento e taxa de desperdício do resumo consideram apenas pares informados.`),el('p','pdi-perf-muted','Aproveitamento = (analisado − desperdiçado) ÷ analisado × 100. Recuperação = salvo ÷ analisado × 100; os m² salvos já fazem parte da área analisada. Base zero: sem percentual.'));
    window.CDECharts.pcp(c,dashboard,`${day(filters.start)} a ${day(filters.end)} · ${filters.pcp?(context.pcps||[]).find(p=>p.id===filters.pcp)?.name||'PCP selecionado':'Todos os PCPs autorizados'}`);const details=el('details','sector-existing');details.append(el('summary','','Rankings e informações existentes'));const rankings=el('div','pcp-ranking-grid');
    for(const [title,key,negative,isPercent]of[['Mais m² analisados','total_analyzed',false,false],['Mais m² salvos','total_m2',false,false],['Ranking de aproveitamento','utilization_percent',false,true],['Mais desperdício · indicador negativo','total_wasted',true,false]]){
      const panel=el('section',`pcp-ranking-card${negative?' pcp-ranking-negative':''}`);panel.append(el('h3','',title));const items=[...(dashboard.ranking||[])].filter(r=>r[key]!==null&&r[key]!==undefined).sort((a,b)=>Number(b[key])-Number(a[key])||a.name.localeCompare(b.name));
      if(!items.length)panel.append(el('p','pdi-perf-empty',isPercent?'Sem base completa para classificar o aproveitamento.':'Nenhum valor informado neste período.'));
      const max=Math.max(1,...items.map(r=>Number(r[key]))),list=el('ol','pdi-perf-ranking-list');let last=null,place=0;
      items.forEach(row=>{if(last!==String(row[key]))place++;last=String(row[key]);const item=el('li','pdi-perf-rank-row'),head=el('div','pdi-perf-rank-heading');head.append(el('span','pdi-perf-place',`${place}º`),el('strong','pdi-perf-rank-name',row.name),el('strong','pdi-perf-rank-total',isPercent?percent(row[key]):areaValue(row[key])));const track=el('div','pdi-perf-rank-track'),bar=el('div','pdi-perf-rank-fill');bar.style.width=`${Math.max(0,Number(row[key]))/max*100}%`;track.setAttribute('aria-hidden','true');track.append(bar);item.append(head,track,el('p','pdi-perf-muted',`${row.entry_count} lançamento(s) · ${row.pending_count||0} pendência(s) de análise/desperdício`));list.append(item);});panel.append(list);if(isPercent)panel.append(el('p','pdi-perf-muted','Somente PCPs com análise e desperdício preenchidos em todos os lançamentos do recorte; percentual calculado sobre os totais.'));if(negative)panel.append(el('p','pdi-perf-muted','Maior volume perdido no topo: sinal de atenção, não de melhor desempenho. Compare também a taxa percentual e o volume analisado.'));rankings.append(panel);
    }details.append(rankings);c.append(details);
    const daily=el('details','pcp-daily');daily.append(el('summary','','Métricas por dia'));for(const d of dashboard.daily||[]){const row=el('article','pdi-perf-record');row.append(el('h3','',day(d.date)),el('p','',`Analisado: ${areaValue(d.analyzed)} · Salvo: ${areaValue(d.saved)} · Desperdício: ${areaValue(d.wasted)}`),el('p','pdi-perf-muted',`Aproveitamento: ${percent(d.utilization_percent)} · ${d.pending_count} pendência(s)`));daily.append(row);}c.append(daily);
  }
  function renderWasteManagement(){
    if(!dashboard?.can_record_waste)return;const c=card('Registrar desperdício por PCP',true);c.id='pdi-pcp-waste-management';c.dataset.sectorPane='waste';c.append(el('p','pdi-perf-muted','Use os filtros de PCP e período acima. Registre zero quando tiver confirmado que não houve desperdício. A quantidade é vinculada ao lançamento do PCP nesse dia.'));
    if(!wasteData.rows.length)c.append(el('p','pdi-perf-empty','Nenhum lançamento do PCP encontrado para registrar desperdício.'));
    for(const row of wasteData.rows){const item=el('article','pdi-perf-record');item.append(el('h3','',`${day(row.work_date)} · ${row.pcp_name_snapshot}`),el('p','',`Analisado: ${areaValue(row.m2_analyzed)} · Salvo: ${areaValue(row.m2_saved)} · Desperdício: ${areaValue(row.m2_wasted)}`));
      if(row.m2_analyzed===null)item.append(el('p','pdi-perf-muted','Registro antigo sem análise: a supervisão deve completar os m² analisados antes do desperdício.'));
      else{const form=el('form','pdi-perf-form'),amount=field(form,'M² desperdiçados','text',`waste-${row.id}`,row.m2_wasted===null?'':String(row.m2_wasted).replace('.',','));amount.inputMode='decimal';amount.required=true;amount.maxLength=13;let reason=null;if(row.waste_revision){reason=field(form,'Justificativa da correção (10 a 300 caracteres)','textarea',`waste-reason-${row.id}`);reason.required=true;reason.minLength=10;reason.maxLength=300;}const save=el('button','',row.waste_revision?'Corrigir desperdício':'Registrar desperdício');save.type='submit';form.append(save);form.addEventListener('submit',event=>{event.preventDefault();saveWaste(row,amount.value,reason?.value||'');});item.append(form);}c.append(item);
    }c.append(pager(wastePage,wasteData.count,n=>{wastePage=n;refresh().then(()=>{const d=$('#pdi-pcp-waste-management',root);if(d)d.open=true;});}));
  }
  async function saveWaste(row,raw,reason){if(busy)return;let amount;try{amount=parseM2(raw);if(areaUnits(amount)+areaUnits(row.m2_saved)>areaUnits(row.m2_analyzed))throw new Error('Desperdício mais m² salvos não podem superar os analisados.');if(row.waste_revision&&(reason.trim().length<10||reason.length>300))throw new Error('Justifique a correção em 10 a 300 caracteres.');}catch(error){status(message(error),true);return;}const e=epoch;lock(true);try{const q=row.waste_revision?db.from('pdi_pcp_waste').update({m2_wasted:amount,reason:reason.trim()}).eq('entry_id',row.id).eq('revision',row.waste_revision).select('entry_id'):db.from('pdi_pcp_waste').insert({entry_id:row.id,m2_wasted:amount});const result=await q;if(!current(e))return;if(result.error)throw result.error;if(row.waste_revision&&!result.data?.length)throw new Error('O registro mudou. Atualize os dados antes de corrigir.');await refresh('Desperdício salvo e registrado no log de auditoria.');const d=$('#pdi-pcp-waste-management',root);if(d)d.open=true;}catch(error){if(current(e))status(message(error),true);}finally{if(current(e))lock(false);}}

  function pager(index, total, navigate) {
    const n = el('nav', 'pdi-perf-pager'); n.setAttribute('aria-label', 'Paginação');
    const prev = button('Anterior', () => { if (!busy) navigate(index - 1); }, true); prev.disabled = index === 0; prev.dataset.fixedDisabled = String(prev.disabled);
    const next = button('Próxima', () => { if (!busy) navigate(index + 1); }, true); next.disabled = (index + 1) * PAGE >= total; next.dataset.fixedDisabled = String(next.disabled);
    n.append(prev, el('span', '', `Página ${index + 1} de ${Math.max(1, Math.ceil(total / PAGE))}`), next); return n;
  }
  function record(row) {
    const analyzed=row.m2_analyzed,wasted=recordWaste.get(row.id); 
    const n = el('article', 'pdi-perf-record');
    n.append(el('h3', '', `${day(row.work_date)} · ${row.pcp_name_snapshot}`), el('strong', 'pdi-perf-result', `${fmt(row.m2_saved)} m²`),
      el('p','pdi-perf-muted',`Analisado: ${areaValue(analyzed)} · Desperdício: ${areaValue(wasted)} · Aproveitamento: ${analyzed>0&&wasted!==null&&wasted!==undefined?percent((Number(analyzed)-Number(wasted))/Number(analyzed)*100):'—'}`),
      el('p', 'pdi-perf-orders', `Pedidos: ${row.order_numbers.join(', ') || 'Nenhum'}`), el('p', 'pdi-perf-muted', `Última atualização: ${time(row.updated_at)} · revisão ${row.revision}`));
    if (context.can_correct) n.append(button('Corrigir', () => {
      if (busy || cashController?.isBusy()) return;
      root.querySelectorAll('.pdi-perf-edit-form').forEach(f => f.remove()); editId = row.id;
      const form = el('form', 'pdi-perf-form pdi-perf-edit-form');
      const m2 = field(form, 'M² Salvo Dia — corrigido', 'text', 'edit-m2', String(row.m2_saved).replace('.', ',')); m2.inputMode = 'decimal'; m2.required = true; m2.maxLength = 13;
      const analyzedInput=field(form,'M² Analisado — corrigido','text','edit-analyzed',row.m2_analyzed===null?'':String(row.m2_analyzed).replace('.',','));analyzedInput.required=true;analyzedInput.inputMode='decimal';analyzedInput.maxLength=13;
      const orders = field(form, 'Pedidos para auditoria — corrigidos', 'textarea', 'edit-orders', row.order_numbers.join(', ')); orders.maxLength = 4400;
      const reason = field(form, 'Justificativa da correção (10 a 300 caracteres)', 'textarea', 'edit-reason'); reason.required = true; reason.minLength = 10; reason.maxLength = 300;
      const save = el('button', '', 'Salvar correção'); save.type = 'submit';
      const cancel = button('Cancelar', () => { if (!busy) { form.remove(); editId = null; } }, true); form.append(save, cancel);
      form.addEventListener('submit', event => { event.preventDefault(); updateEntry(row, m2.value, orders.value, reason.value,analyzedInput.value); }); n.append(form); m2.focus();
    }, true));
    return n;
  }
  async function createEntry(rawM2, rawOrders,rawAnalyzed) {
    if (busy || cashController?.isBusy()) return;
    let m2, orders,analyzed;
    try { m2 = parseM2(rawM2);analyzed=parseM2(rawAnalyzed);if(Number(m2)>Number(analyzed))throw new Error('Salvo não pode superar analisado.'); orders = parseOrders(rawOrders, Number(m2)||Number(analyzed)); } catch (error) { status(message(error), true); return; }
    const e = epoch; lock(true);
    try {
      // Revalida o dia no servidor: não reutiliza a data de uma aba aberta ontem.
      const check = await db.rpc('pdi_desempenho_context'); if (!current(e)) return;
      if (check.error) throw check.error;
      if (check.data.today !== context.today) { await refresh('O dia mudou. Confira os dados e envie o lançamento novamente.'); return; }
      const result = await db.from('pdi_pcp_daily').insert({ pcp_id: user.id, work_date: context.today, m2_saved: m2,m2_analyzed:analyzed, order_numbers: orders });
      if (!current(e)) return; if (result.error) throw result.error;
      await refresh('Resultado registrado com sucesso.');
    } catch (error) { if (current(e)) status(message(error), true); }
    finally { if (current(e)) lock(false); }
  }
  async function updateEntry(row, rawM2, rawOrders, rawReason,rawAnalyzed) {
    if (busy || editId !== row.id) return;
    let m2, orders,analyzed; const reason = rawReason.trim();
    try {
      m2 = parseM2(rawM2);analyzed=parseM2(rawAnalyzed);if(Number(m2)>Number(analyzed))throw new Error('Salvo não pode superar analisado.'); orders = parseOrders(rawOrders, Number(m2)||Number(analyzed));
      if (reason.length < 10 || reason.length > 300) throw new Error('Informe uma justificativa de 10 a 300 caracteres.');
      if (row.m2_analyzed!==null&&Number(analyzed)===Number(row.m2_analyzed)&&Number(m2) === Number(row.m2_saved) && JSON.stringify(orders) === JSON.stringify(row.order_numbers)) throw new Error('Não há alteração nos m² ou pedidos.');
    } catch (error) { status(message(error), true); return; }
    const e = epoch; lock(true);
    try {
      const result = await db.from('pdi_pcp_daily').update({ m2_saved: m2,m2_analyzed:analyzed, order_numbers: orders, edit_reason: reason }).eq('id', row.id).eq('revision', row.revision).select('id,revision');
      if (!current(e)) return; if (result.error) throw result.error;
      if (!result.data?.length) { status('O registro mudou ou sua permissão foi alterada. Atualize os dados e revise a correção antes de tentar novamente.', true); return; }
      await refresh('Correção salva e registrada no log de auditoria.');
      if (current(e)) { const h = $('[data-sector-pane="history"]', root); if (h) h.open = true; }
    } catch (error) { if (current(e)) status(message(error), true); }
    finally { if (current(e)) lock(false); }
  }
  async function loadLogs(body,details){if(!context?.can_view_logs||busy)return;details.dataset.loaded='true';const e=epoch;window.CDEAudit.mount({db,host:body,module:'pcp_m2',subjectId:filters.pcp||null,today:context.today,alive:()=>current(e)&&body.isConnected});}
  async function setSession(client, sessionUser, sessionProfile) {
    reset(); db = client; user = sessionUser; profile = sessionProfile;
    activeModule = isCashPosition(profile?.position) ? 'cash' : 'pcp';
    page = logPage = rankPage = wastePage = 0; filters = { pcp: '', start: '', end: '' };
    subscription?.unsubscribe(); subscription = null;
    if (!db || !user || !profile) return;
    const listener = db.auth.onAuthStateChange(event => { if (event === 'SIGNED_OUT') reset(); });
    subscription = listener.data?.subscription; mount();
  }
  window.CDEDesempenho = Object.freeze({ setSession, clear: reset, open, openModule,isBusy:()=>busy||Boolean(cashController?.isBusy()), ui:Object.freeze({heading,periodButtons,icon}) });
})();
