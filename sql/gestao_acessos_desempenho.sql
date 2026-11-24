-- Aplicado após autorização explícita da Diretoria; permissões anteriores preservadas.
-- Administração central, sem alterar cargos ou autorizações atuais na implantação.
create schema pdi_access_private;
revoke all on schema pdi_access_private from public,anon;
grant usage on schema pdi_access_private to authenticated;
create table public.pdi_performance_access(profile_id uuid not null references public.profiles(id),module_key text not null check(module_key in('pcp_m2','cash_daily','logistics','stock','sales_campaign','erika_glass')),permission text check(permission in('blocked','view','collect','supervisor','manage','sales','promoter','production','stock','coordinator')),revision integer not null default 1,assigned_at timestamptz not null default clock_timestamp(),assigned_by uuid not null references public.profiles(id),primary key(profile_id,module_key));
alter table public.pdi_performance_access enable row level security;
revoke all on public.pdi_performance_access from public,anon,authenticated;
grant select on public.pdi_performance_access to authenticated;
create policy performance_access_read on public.pdi_performance_access for select to authenticated using(profile_id=(select auth.uid())or(select pdi_performance_private.is_indicator_admin()));

create function pdi_access_private.mode(p_module text,p_profile uuid default auth.uid())returns text language sql stable security definer set search_path=pg_catalog as $$select a.permission from public.pdi_performance_access a join public.profiles p on p.id=a.profile_id where auth.uid()is not null and a.profile_id=p_profile and a.module_key=p_module and not(coalesce(p.is_master,false)or p.role in('master','diretor','diretoria'))$$;
create function pdi_access_private.allowed(p_module text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select auth.uid()is not null and pdi_access_private.mode(p_module)is distinct from'blocked'$$;
create function pdi_access_private.assert_allowed(p_module text,p_write boolean default false)returns boolean language plpgsql volatile security invoker set search_path=pg_catalog as $$begin
 if auth.uid()is null or not pdi_access_private.allowed(p_module)or(p_write and pdi_access_private.mode(p_module)='view')then raise exception 'Seu acesso a esta área ou operação foi retirado. Atualize a página.'using errcode='42501';end if;return true;
end$$;
revoke all on function pdi_access_private.mode(text,uuid),pdi_access_private.allowed(text),pdi_access_private.assert_allowed(text,boolean)from public,anon;
grant execute on function pdi_access_private.mode(text,uuid),pdi_access_private.allowed(text),pdi_access_private.assert_allowed(text,boolean)to authenticated;

create function pdi_access_private.catalog()returns jsonb language sql immutable set search_path=pg_catalog as $$select '[
{"key":"pcp_m2","label":"PCP","options":[{"value":"view","label":"Consultar dashboards","description":"Consulta consolidada, sem lançamentos ou ajustes."},{"value":"collect","label":"Registrar o próprio desempenho","description":"M² analisado e salvo, com pedidos para auditoria."},{"value":"supervisor","label":"Supervisão PCP · Rodrigo","description":"Correções apenas para Rodrigo F. L. Campos; desperdício segue a regra existente."}]},
{"key":"cash_daily","label":"Caixa","options":[{"value":"view","label":"Consultar dashboards","description":"Consulta do fechamento financeiro, sem alterações."},{"value":"collect","label":"Registrar o próprio caixa","description":"Fechamentos e comprovantes do próprio colaborador."}]},
{"key":"logistics","label":"Logística","options":[{"value":"view","label":"Consultar dashboards","description":"Consulta da operação, sem alterações."},{"value":"collect","label":"Registrar lançamentos","description":"Registros da operação; ajustes permanecem com a supervisão."},{"value":"supervisor","label":"Supervisão da operação","description":"Consultar e ajustar com justificativa."},{"value":"manage","label":"Gestão e cadastros","description":"Dashboards, log e cadastros; não muda o cargo do colaborador."}]},
{"key":"stock","label":"Estoque · movimentação interna","options":[{"value":"view","label":"Consultar indicadores","description":"Consulta das movimentações internas, sem alterações."},{"value":"collect","label":"Registrar movimentação interna","description":"Munck e movimentação interna. Desperdício continua exclusivo do Jackson."}]},
{"key":"sales_campaign","label":"Comercial · Vendas","options":[{"value":"collect","label":"Vendedor · desempenho próprio","description":"Somente seus indicadores e lançamentos."},{"value":"manage","label":"Gestão Comercial","description":"Todos os vendedores, importação, regras, ajustes e exclusões da campanha."}]},
{"key":"erika_glass","label":"Erika Glass","options":[{"value":"sales","label":"Vendas E.G.","description":"Seus relatórios, pedidos e visitas."},{"value":"promoter","label":"Promotoria E.G.","description":"Suas visitas, agenda e fotos."},{"value":"production","label":"Produção E.G.","description":"Conferir transferências e registrar preparo."},{"value":"stock","label":"Estoque E.G.","description":"Entradas, saídas e ocorrências do Estoque E.G."},{"value":"coordinator","label":"Coordenação E.G.","description":"Vendas, produção, financeiro, cadastros e importação. Sem enviar saídas do estoque."},{"value":"manage","label":"Gestão completa E.G.","description":"Coordenação e Estoque E.G. Exclusão de lançamentos continua exigindo cargo gerencial."}]}
]'::jsonb$$;
revoke all on function pdi_access_private.catalog()from public,anon;grant execute on function pdi_access_private.catalog()to authenticated;

create function pdi_access_private.set_access(p_profile_id uuid,p_module_key text,p_permission text,p_revision integer,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare target public.profiles%rowtype;before_row jsonb;after_row jsonb;current_row public.pdi_performance_access%rowtype;cfg jsonb;begin
 if auth.uid()is null or not pdi_performance_private.is_indicator_admin()then raise exception 'Somente Diretoria/Master administra acessos.'using errcode='42501';end if;
 select *into target from public.profiles where id=p_profile_id;if not found then raise exception 'Colaborador não encontrado.'using errcode='22023';end if;
 if coalesce(target.is_master,false)or target.role in('master','diretor','diretoria')then raise exception 'Diretoria/Master mantém acesso consolidado protegido.'using errcode='22023';end if;
 select value into cfg from jsonb_array_elements(pdi_access_private.catalog())where value->>'key'=p_module_key;
 if cfg is null or(p_permission is not null and p_permission<>'blocked'and not exists(select 1 from jsonb_array_elements(cfg->'options')where value->>'value'=p_permission))then raise exception 'Área ou permissão inválida.'using errcode='22023';end if;
 if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique a alteração em 10 a 300 caracteres.'using errcode='22023';end if;
 if p_permission='collect'and target.role not in('employee','colaborador','supervisor')then raise exception 'Lançamento próprio é para colaboradores e supervisão. Use consulta para o cargo gerencial.'using errcode='22023';end if;
 if p_module_key='pcp_m2'and p_permission='supervisor'and lower(btrim(target.full_name))<>'rodrigo f. l. campos'then raise exception 'A supervisão do PCP continua exclusiva de Rodrigo F. L. Campos.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_profile_id::text||':'||p_module_key,0));
 select *into current_row from public.pdi_performance_access where profile_id=p_profile_id and module_key=p_module_key for update;
 if current_row.revision is distinct from p_revision then raise exception 'O acesso mudou desde a consulta. Atualize antes de salvar.'using errcode='40001';end if;
 before_row:=case when current_row.profile_id is null then null else to_jsonb(current_row)end;
 if current_row.profile_id is not null and current_row.permission is not distinct from p_permission then return to_jsonb(current_row);end if;
 insert into public.pdi_performance_access(profile_id,module_key,permission,assigned_by)values(p_profile_id,p_module_key,p_permission,auth.uid())on conflict(profile_id,module_key)do update set permission=excluded.permission,revision=pdi_performance_access.revision+1,assigned_by=auth.uid(),assigned_at=clock_timestamp()returning to_jsonb(pdi_performance_access.*)into after_row;
 insert into public.pdi_area_access_audit(actor_id,action,before_data,after_data)values(auth.uid(),case when p_permission is null then'PERFORMANCE_RESTORE'when p_permission='blocked'then'PERFORMANCE_BLOCK'else'PERFORMANCE_GRANT'end,before_row,after_row||jsonb_build_object('reason',btrim(p_reason),'actor_name',(select full_name from public.profiles where id=auth.uid())));
 return after_row;
end$$;
revoke all on function pdi_access_private.set_access(uuid,text,text,integer,text)from public,anon;grant execute on function pdi_access_private.set_access(uuid,text,text,integer,text)to authenticated;
create function public.pdi_set_performance_access(p_profile_id uuid,p_module_key text,p_permission text,p_revision integer,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_access_private.set_access(p_profile_id,p_module_key,p_permission,p_revision,p_reason)$$;
revoke all on function public.pdi_set_performance_access(uuid,text,text,integer,text)from public,anon;grant execute on function public.pdi_set_performance_access(uuid,text,text,integer,text)to authenticated;
create function public.pdi_performance_access_admin_context()returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$begin
 if auth.uid()is null or not pdi_performance_private.is_indicator_admin()then raise exception 'Somente Diretoria/Master administra acessos.'using errcode='42501';end if;
 return jsonb_build_object('modules',pdi_access_private.catalog(),'profiles',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'full_name',full_name,'position',position,'sector',sector,'role',role,'is_master',is_master)order by full_name),'[]')from public.profiles),'overrides',(select coalesce(jsonb_agg(to_jsonb(a)),'[]')from public.pdi_performance_access a),'audit',(select coalesce(jsonb_agg(to_jsonb(a)),'[]')from(select *from public.pdi_area_access_audit order by occurred_at desc limit 200)a));
end$$;
revoke all on function public.pdi_performance_access_admin_context()from public,anon;grant execute on function public.pdi_performance_access_admin_context()to authenticated;

-- Mantém os corpos anteriores em schema privado e conserva os OIDs públicos das regras.
do $migration$declare n text;f regprocedure;definition text;begin
 foreach n in array array['module_level','can_view_module','can_collect_module','can_correct_module','can_audit_module','logistics_register','stock_operator','stock_waste_supervisor','sales_manage','sales_participant','cash_file_can_read']loop
 f:=to_regprocedure('pdi_performance_private.'||n||case when n in('module_level','can_view_module','can_collect_module','can_correct_module','can_audit_module','cash_file_can_read')then'(text)'when n='sales_participant'then'(uuid)'else'()'end);
 if f is null then raise exception 'Regra obrigatória ausente: %',n;end if;
 definition:=pg_get_functiondef(f);definition:=replace(definition,'FUNCTION pdi_performance_private.'||n||'(','FUNCTION pdi_access_private.base_'||n||'(');execute definition;
 execute 'revoke all on function pdi_access_private.base_'||n||case when n in('module_level','can_view_module','can_collect_module','can_correct_module','can_audit_module','cash_file_can_read')then'(text)'when n='sales_participant'then'(uuid)'else'()'end||' from public,anon';
 execute 'grant execute on function pdi_access_private.base_'||n||case when n in('module_level','can_view_module','can_collect_module','can_correct_module','can_audit_module','cash_file_can_read')then'(text)'when n='sales_participant'then'(uuid)'else'()'end||' to authenticated';
 end loop;
end$migration$;
create or replace function pdi_performance_private.module_level(p_module text)returns text language sql stable security invoker set search_path=pg_catalog as $$select case pdi_access_private.mode(p_module)when'blocked'then null when'view'then'viewer'when'collect'then'collector'when'supervisor'then'supervisor'when'manage'then'manager'else pdi_access_private.base_module_level(p_module)end$$;
create or replace function pdi_performance_private.can_view_module(p_module text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode(p_module)is null then pdi_access_private.base_can_view_module(p_module)else pdi_access_private.mode(p_module)in('view','supervisor','manage')end$$;
create or replace function pdi_performance_private.can_collect_module(p_module text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode(p_module)is null then pdi_access_private.base_can_collect_module(p_module)else pdi_access_private.mode(p_module)='collect'or(p_module='logistics'and pdi_access_private.mode(p_module)='supervisor')end$$;
create or replace function pdi_performance_private.can_correct_module(p_module text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode(p_module)is null or pdi_access_private.mode(p_module)='supervisor'then pdi_access_private.base_can_correct_module(p_module)else false end$$;
create or replace function pdi_performance_private.can_audit_module(p_module text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode(p_module)is null then pdi_access_private.base_can_audit_module(p_module)else pdi_access_private.mode(p_module)='manage'end$$;
create or replace function pdi_performance_private.logistics_register()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode('logistics')is null then pdi_access_private.base_logistics_register()else pdi_access_private.mode('logistics')='manage'end$$;
create or replace function pdi_performance_private.stock_operator()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode('stock')is null then pdi_access_private.base_stock_operator()else pdi_access_private.mode('stock')='collect'end$$;
create or replace function pdi_performance_private.stock_waste_supervisor()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select pdi_access_private.allowed('stock')and pdi_access_private.mode('stock')is distinct from'view'and pdi_access_private.base_stock_waste_supervisor()$$;
create or replace function pdi_performance_private.sales_manage()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode('sales_campaign')is null then pdi_access_private.base_sales_manage()else pdi_access_private.mode('sales_campaign')='manage'end$$;
create or replace function pdi_performance_private.sales_participant(p_id uuid)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select case when pdi_access_private.mode('sales_campaign',p_id)is null or pdi_access_private.mode('sales_campaign',p_id)='manage'then pdi_access_private.base_sales_participant(p_id)else auth.uid()is not null and pdi_access_private.mode('sales_campaign',p_id)='collect'end$$;
create or replace function pdi_performance_private.cash_file_can_read(path text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select pdi_access_private.allowed('cash_daily')and pdi_access_private.base_cash_file_can_read(path)$$;

-- E.G. tem perfis operacionais próprios, sem promover o cargo em profiles.
do $migration$declare definition text;begin
 definition:=pg_get_functiondef('pdi_eg_private.permissions()'::regprocedure);execute replace(definition,'FUNCTION pdi_eg_private.permissions(','FUNCTION pdi_access_private.base_eg_permissions(');
end$migration$;
revoke all on function pdi_access_private.base_eg_permissions()from public,anon;grant execute on function pdi_access_private.base_eg_permissions()to authenticated;
create or replace function pdi_eg_private.permissions()returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$
declare m text:=pdi_access_private.mode('erika_glass');c boolean;st boolean;sa boolean;pr boolean;pd boolean;mg boolean;begin
 if m is null then return pdi_access_private.base_eg_permissions();end if;
 c:=m in('coordinator','manage');st:=m in('stock','manage');sa:=m='sales';pr:=m='promoter';pd:=m='production';mg:=pdi_eg_private.global_manager()and m='manage';
 return jsonb_build_object('allowed',auth.uid()is not null and m<>'blocked','manager',mg,'coordinator',c,'can_manage',c,'can_import',c,'can_sales',c or sa,'can_visit',c or sa or pr,'can_production',c or pd,'can_stock',st,'can_occurrences',c or st,'can_finance',c,'can_delete',mg,'can_eg',c or sa or pr or pd,'can_stock_module',c or st);
end$$;

-- Bloqueio e consulta são aplicados também às leituras/gravações diretas, não só aos menus.
do $migration$declare t text;m text;begin
 foreach m in array array['pcp_m2','cash_daily','sales_campaign','erika_glass']loop
 foreach t in array (case m when'pcp_m2'then array['pdi_pcp_daily','pdi_pcp_waste','pdi_performance_audit']when'cash_daily'then array['pdi_cash_daily','pdi_cash_files','pdi_cash_audit']when'sales_campaign'then array['pdi_sales_daily','pdi_sales_targets','pdi_sales_campaigns']else array['pdi_eg_records','pdi_eg_companies','pdi_eg_products','pdi_eg_prices','pdi_eg_stock_moves','pdi_eg_photos','pdi_eg_audit']end) loop
 execute format('create policy performance_access_gate on public.%I as restrictive for select to authenticated using((select pdi_access_private.allowed(%L)))',t,m);
 execute format('create policy performance_access_insert_gate on public.%I as restrictive for insert to authenticated with check((select pdi_access_private.allowed(%L))and(select pdi_access_private.mode(%L))is distinct from''view'')',t,m,m);
 execute format('create policy performance_access_update_gate on public.%I as restrictive for update to authenticated using((select pdi_access_private.allowed(%L))and(select pdi_access_private.mode(%L))is distinct from''view'')with check((select pdi_access_private.allowed(%L))and(select pdi_access_private.mode(%L))is distinct from''view'')',t,m,m,m,m);
 execute format('create policy performance_access_delete_gate on public.%I as restrictive for delete to authenticated using((select pdi_access_private.allowed(%L))and(select pdi_access_private.mode(%L))is distinct from''view'')',t,m,m);
 end loop;end loop;
 foreach t in array array['pdi_logistics_people','pdi_logistics_vehicles']loop
 execute format('create policy performance_access_gate on public.%I as restrictive for all to authenticated using((select pdi_access_private.allowed(''logistics''))or(select pdi_access_private.allowed(''stock'')))with check((select pdi_access_private.allowed(''logistics''))and(select pdi_access_private.mode(''logistics''))is distinct from''view'')',t);
 end loop;
end$migration$;
create policy performance_access_gate on public.pdi_logistics_records as restrictive for select to authenticated using(pdi_access_private.allowed(case when origin_module='stock'then'stock'else'logistics'end));
create policy performance_access_insert_gate on public.pdi_logistics_records as restrictive for insert to authenticated with check(pdi_access_private.allowed(case when origin_module='stock'then'stock'else'logistics'end)and pdi_access_private.mode(case when origin_module='stock'then'stock'else'logistics'end)is distinct from'view');
create policy performance_access_update_gate on public.pdi_logistics_records as restrictive for update to authenticated using(pdi_access_private.allowed(case when origin_module='stock'then'stock'else'logistics'end)and pdi_access_private.mode(case when origin_module='stock'then'stock'else'logistics'end)is distinct from'view')with check(pdi_access_private.allowed(case when origin_module='stock'then'stock'else'logistics'end)and pdi_access_private.mode(case when origin_module='stock'then'stock'else'logistics'end)is distinct from'view');
create policy performance_access_gate on public.pdi_performance_events as restrictive for select to authenticated using(pdi_access_private.allowed(module_key));
create policy performance_access_gate on public.pdi_audit_exports as restrictive for select to authenticated using(pdi_access_private.allowed(module_key));
create or replace function public.pdi_performance_permissions()returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select jsonb_build_object('can_delete',pdi_performance_private.performance_manager(),'can_budget',pdi_performance_private.performance_manager()and pdi_access_private.allowed('logistics')and pdi_access_private.mode('logistics')is distinct from'view','can_stock_waste',pdi_performance_private.stock_waste_supervisor(),'read_only_modules',(select coalesce(jsonb_agg(module_key),'[]')from public.pdi_performance_access where profile_id=auth.uid()and permission in('view','blocked')),'deletion_modules',(select coalesce(jsonb_object_agg(module_key,deletion_targets),'{}')from public.pdi_indicator_modules where enabled))$$;
notify pgrst,'reload schema';
