begin;
create table public.pdi_sales_campaigns(id uuid primary key default gen_random_uuid(),name text not null check(length(name) between 1 and 100),start_date date,end_date date,rules jsonb not null default '{}',revision integer not null default 1,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),updated_by uuid references public.profiles(id),check((start_date is null and end_date is null)or(start_date is not null and end_date is not null and start_date<=end_date)));
create table public.pdi_sales_daily(id uuid primary key default gen_random_uuid(),campaign_id uuid not null references public.pdi_sales_campaigns(id),seller_id uuid not null references public.profiles(id),work_date date not null,data jsonb not null,revision integer not null default 1,deleted boolean not null default false,created_at timestamptz not null default now(),created_by uuid not null references public.profiles(id),updated_at timestamptz not null default now(),updated_by uuid not null references public.profiles(id));
create unique index pdi_sales_daily_unique on public.pdi_sales_daily(campaign_id,seller_id,work_date) where not deleted;
create index pdi_sales_daily_scope on public.pdi_sales_daily(seller_id,campaign_id,work_date,id) where not deleted;
create index pdi_sales_daily_campaign on public.pdi_sales_daily(campaign_id,work_date,id) where not deleted;
alter table public.pdi_sales_campaigns enable row level security;alter table public.pdi_sales_daily enable row level security;
revoke all on public.pdi_sales_campaigns,public.pdi_sales_daily from public,anon,authenticated;grant select on public.pdi_sales_campaigns,public.pdi_sales_daily to authenticated;
create function pdi_performance_private.sales_manage()returns boolean language sql stable security definer set search_path=pg_catalog as $$select auth.uid()is not null and (pdi_performance_private.performance_manager()or exists(select 1 from public.profiles where id=auth.uid()and lower(btrim(position))='coordenadora comercial'))$$;
create function pdi_performance_private.sales_participant(p_id uuid)returns boolean language sql stable security definer set search_path=pg_catalog as $$select auth.uid()is not null and exists(select 1 from public.profiles where id=p_id and lower(btrim(position))in('consultor(a) de vendas','coordenadora comercial'))$$;
create function pdi_performance_private.sales_access()returns boolean language sql stable set search_path=pg_catalog as $$select auth.uid()is not null and(pdi_performance_private.sales_manage()or pdi_performance_private.sales_participant(auth.uid()))$$;
create policy sales_campaign_read on public.pdi_sales_campaigns for select to authenticated using((select pdi_performance_private.sales_access()));
create policy sales_daily_read on public.pdi_sales_daily for select to authenticated using(not deleted and((select pdi_performance_private.sales_manage())or(seller_id=(select auth.uid())and(select pdi_performance_private.sales_participant(auth.uid())))));
create function pdi_performance_private.sales_context()returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$begin
if not pdi_performance_private.sales_access()then return jsonb_build_object('allowed',false);end if;
return jsonb_build_object('allowed',true,'today',pdi_performance_private.today_manaus(),'can_manage',pdi_performance_private.sales_manage(),'is_participant',pdi_performance_private.sales_participant(auth.uid()),'participants',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',full_name)order by full_name),'[]')from public.profiles where lower(btrim(position))in('consultor(a) de vendas','coordenadora comercial')and(pdi_performance_private.sales_manage()or id=auth.uid())));end $$;
create function pdi_performance_private.sales_rules(p_id uuid,p_name text,p_start date,p_end date,p_rules jsonb,p_revision integer,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c public.pdi_sales_campaigns%rowtype;k text;r jsonb;n numeric;begin
if not pdi_performance_private.sales_manage()then raise exception 'Configuração restrita à coordenação e gestão.'using errcode='42501';end if;
if p_start is null or p_end is null or p_start>p_end or length(btrim(p_name))not between 1 and 100 or p_rules is null or jsonb_typeof(p_rules)<>'object' or length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Confira as datas, nome, regras e justificativa (10 a 300 caracteres).'using errcode='22023';end if;
select *into c from public.pdi_sales_campaigns where id=p_id for update;if c.id is null or c.revision is distinct from p_revision then raise exception 'A configuração mudou. Atualize os dados.'using errcode='40001';end if;
for k,r in select key,value from jsonb_each(p_rules)loop
if not(k=any(ARRAY['salesQty','salesValue','salesArea','habitatValue','habitatArea','laminatedValue','laminatedArea','quotesQty','quotesValue','errorsQty','errorsValue','errorsArea','fullQty','fullValue','conversion','ticket','customers']))or jsonb_typeof(r)<>'object' or jsonb_typeof(r->'enabled')is distinct from 'boolean' then raise exception 'Regra inválida.'using errcode='22023';end if;
if(r->>'enabled')::boolean then
if jsonb_typeof(r->'target')is distinct from 'number'or jsonb_typeof(r->'points')is distinct from 'number'then raise exception 'Meta e pontos devem ser números.'using errcode='22023';end if;
if(r->>'target')::numeric<=0 or(r->>'target')::numeric>1000000000000 or(r->>'points')::numeric<0 or(r->>'points')::numeric>1000000 then raise exception 'Meta ou pontos fora do limite.'using errcode='22023';end if;end if;end loop;
if exists(select 1 from public.pdi_sales_daily where campaign_id=p_id and not deleted and(work_date<p_start or work_date>p_end))then raise exception 'Existem lançamentos fora das novas datas.'using errcode='22023';end if;
update public.pdi_sales_campaigns set name=btrim(p_name),start_date=p_start,end_date=p_end,rules=p_rules,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()where id=p_id;
perform pdi_performance_private.record_event('sales_campaign','campanha','SALES_RULES_UPDATED',null,to_jsonb(c),(select to_jsonb(x)from public.pdi_sales_campaigns x where id=p_id),p_reason);return jsonb_build_object('ok',true);end $$;
create function pdi_performance_private.sales_save(p_id uuid,p_campaign uuid,p_seller uuid,p_date date,p_data jsonb,p_revision integer,p_campaign_revision integer,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c public.pdi_sales_campaigns%rowtype;oldrow public.pdi_sales_daily%rowtype;newrow public.pdi_sales_daily%rowtype;k text;n numeric;customer jsonb;begin
if not pdi_performance_private.sales_access()or not pdi_performance_private.sales_participant(p_seller)or(not pdi_performance_private.sales_manage()and p_seller is distinct from auth.uid())then raise exception 'Participante fora do seu acesso.'using errcode='42501';end if;
select *into c from public.pdi_sales_campaigns where id=p_campaign for share;
if c.id is null or c.revision is distinct from p_campaign_revision then raise exception 'A campanha mudou. Atualize os dados.'using errcode='40001';end if;
if c.start_date is null or p_date is null or p_date<c.start_date or p_date>c.end_date or p_date>pdi_performance_private.today_manaus()then raise exception 'Configure a campanha e use uma data válida, até hoje.'using errcode='22023';end if;
if p_data is null or jsonb_typeof(p_data)<>'object'then raise exception 'Indicadores inválidos.'using errcode='22023';end if;
if exists(select 1 from jsonb_object_keys(p_data) as x(k) where not(x.k=any(ARRAY['salesQty','salesValue','salesArea','habitatValue','habitatArea','laminatedValue','laminatedArea','quotesQty','quotesValue','errorsQty','errorsValue','errorsArea','fullQty','fullValue','bitrix','customers','notes'])))then raise exception 'Campo não reconhecido.'using errcode='22023';end if;
foreach k in array ARRAY['salesQty','salesValue','salesArea','habitatValue','habitatArea','laminatedValue','laminatedArea','quotesQty','quotesValue','errorsQty','errorsValue','errorsArea','fullQty','fullValue']loop
if jsonb_typeof(p_data->k)is distinct from 'number'then raise exception 'Indicador obrigatório: %',k using errcode='22023';end if;n:=(p_data->>k)::numeric;
if n<0 or n>1000000000000 or n<>trunc(n)then raise exception 'Valor inválido: %',k using errcode='22023';end if;end loop;
if jsonb_typeof(p_data->'bitrix')is distinct from 'boolean'or jsonb_typeof(p_data->'customers')is distinct from 'array'or jsonb_typeof(p_data->'notes')is distinct from 'string'or length(p_data->>'notes')>500 then raise exception 'Revise Bitrix, clientes e observações.'using errcode='22023';end if;
if jsonb_array_length(p_data->'customers')>500 then raise exception 'Limite de 500 novos clientes por dia.'using errcode='22023';end if;
for customer in select value from jsonb_array_elements(p_data->'customers')loop
if jsonb_typeof(customer)<>'object'or jsonb_typeof(customer->'name')is distinct from 'string'or length(btrim(customer->>'name'))not between 1 and 150 or jsonb_typeof(customer->'reference')is distinct from 'string'or length(customer->>'reference')>80 then raise exception 'Identificação do cliente inválida.'using errcode='22023';end if;end loop;
if(p_data->>'salesQty')::numeric=0 and((p_data->>'salesValue')::numeric>0 or(p_data->>'salesArea')::numeric>0)or(p_data->>'quotesQty')::numeric=0 and(p_data->>'quotesValue')::numeric>0 or(p_data->>'fullQty')::numeric=0 and(p_data->>'fullValue')::numeric>0 then raise exception 'Informe as quantidades correspondentes aos valores.'using errcode='22023';end if;
foreach k in array ARRAY['habitatValue','laminatedValue','fullValue']loop if(p_data->>k)::numeric>(p_data->>'salesValue')::numeric then raise exception 'Valor parcial excede vendas totais.'using errcode='22023';end if;end loop;
foreach k in array ARRAY['habitatArea','laminatedArea']loop if(p_data->>k)::numeric>(p_data->>'salesArea')::numeric then raise exception 'Área parcial excede área total.'using errcode='22023';end if;end loop;
if(p_data->>'fullQty')::numeric>(p_data->>'salesQty')::numeric then raise exception 'Quantidade sem desconto excede vendas totais.'using errcode='22023';end if;
select *into oldrow from public.pdi_sales_daily where id=p_id for update;
if oldrow.id is null then
if p_revision is not null then raise exception 'Registro indisponível.'using errcode='40001';end if;
insert into public.pdi_sales_daily(id,campaign_id,seller_id,work_date,data,created_by,updated_by)values(p_id,p_campaign,p_seller,p_date,p_data,auth.uid(),auth.uid())returning *into newrow;
else
if not pdi_performance_private.sales_manage()then raise exception 'Ajustes restritos à coordenação e gestão.'using errcode='42501';end if;
if oldrow.deleted or oldrow.revision is distinct from p_revision then raise exception 'O lançamento mudou. Atualize antes de ajustar.'using errcode='40001';end if;
if oldrow.campaign_id<>p_campaign or oldrow.seller_id<>p_seller or oldrow.work_date<>p_date then raise exception 'Participante e data não podem ser alterados; exclua e registre novamente.'using errcode='22023';end if;
if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;
update public.pdi_sales_daily set data=p_data,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()where id=p_id returning *into newrow;end if;
perform pdi_performance_private.record_event('sales_campaign','lancamentos',case when oldrow.id is null then'SALES_CREATED'else'SALES_UPDATED'end,p_seller,case when oldrow.id is null then null else to_jsonb(oldrow)end,to_jsonb(newrow),p_reason);return jsonb_build_object('id',newrow.id,'revision',newrow.revision);
exception when unique_violation then raise exception 'Já existe lançamento deste participante neste dia.'using errcode='23505';end $$;
create function pdi_performance_private.sales_delete(p_id uuid,p_revision integer,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$declare r public.pdi_sales_daily%rowtype;begin
if not pdi_performance_private.sales_manage()then raise exception 'Exclusão restrita à coordenação e gestão.'using errcode='42501';end if;
if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique a exclusão em 10 a 300 caracteres.'using errcode='22023';end if;
select *into r from public.pdi_sales_daily where id=p_id for update;if r.id is null or r.deleted or r.revision is distinct from p_revision then raise exception 'O lançamento mudou. Atualize os dados.'using errcode='40001';end if;
update public.pdi_sales_daily set deleted=true,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()where id=p_id;
perform pdi_performance_private.record_event('sales_campaign','lancamentos','SALES_DELETED',r.seller_id,to_jsonb(r),(select to_jsonb(x)from public.pdi_sales_daily x where id=p_id),p_reason);return jsonb_build_object('ok',true);end $$;
create function pdi_performance_private.sales_export(p_campaign uuid,p_start date,p_end date,p_seller uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$declare result jsonb;begin
if not pdi_performance_private.sales_access()or(p_seller is not null and p_seller<>auth.uid()and not pdi_performance_private.sales_manage())then raise exception 'Exportação fora do acesso.'using errcode='42501';end if;
if p_start is null or p_end is null or p_start>p_end then raise exception 'Período inválido.'using errcode='22023';end if;
if(select count(*)from public.pdi_sales_daily where campaign_id=p_campaign and not deleted and work_date between p_start and p_end and(p_seller is null or seller_id=p_seller)and(pdi_performance_private.sales_manage()or seller_id=auth.uid()))>50000 then raise exception 'Reduza o período para exportar até 50 mil registros.'using errcode='22023';end if;
select coalesce(jsonb_agg(to_jsonb(x)order by work_date,id),'[]')into result from public.pdi_sales_daily x where campaign_id=p_campaign and not deleted and work_date between p_start and p_end and(p_seller is null or seller_id=p_seller)and(pdi_performance_private.sales_manage()or seller_id=auth.uid());
perform pdi_performance_private.record_event('sales_campaign','exportacoes','SALES_CSV_REQUESTED',auth.uid(),null,jsonb_build_object('campaign',p_campaign,'from',p_start,'to',p_end,'seller',p_seller,'count',jsonb_array_length(result)),null);return result;end $$;
create function pdi_performance_private.sales_audit(p_month date,p_search text,p_offset integer,p_export boolean)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$declare result jsonb;total bigint;start_at timestamptz;end_at timestamptz;export_id uuid;begin
if not pdi_performance_private.sales_manage()then raise exception 'Log restrito à coordenação e gestão.'using errcode='42501';end if;
if p_month is null or length(coalesce(p_search,''))>150 or p_offset is null or p_offset<0 then raise exception 'Filtros inválidos.'using errcode='22023';end if;
start_at:=date_trunc('month',p_month::timestamp)at time zone'America/Manaus';end_at:=(date_trunc('month',p_month::timestamp)+interval'1 month')at time zone'America/Manaus';
select count(*)into total from public.pdi_performance_events e where module_key='sales_campaign'and occurred_at>=start_at and occurred_at<end_at and position(lower(coalesce(p_search,''))in lower(to_jsonb(e)::text))>0;
if p_export and total>50000 then raise exception 'Refine a pesquisa para exportar até 50 mil eventos.'using errcode='22023';end if;
select coalesce(jsonb_agg(to_jsonb(x)),'[]')into result from(select *from public.pdi_performance_events e where module_key='sales_campaign'and occurred_at>=start_at and occurred_at<end_at and position(lower(coalesce(p_search,''))in lower(to_jsonb(e)::text))>0 order by occurred_at desc,id limit case when p_export then 50000 else 30 end offset case when p_export then 0 else p_offset end)x;
if p_export then export_id:=pdi_performance_private.record_event('sales_campaign','exportacoes','SALES_LOG_CSV_REQUESTED',auth.uid(),null,jsonb_build_object('month',p_month,'search',p_search,'count',total),null);end if;
return jsonb_build_object('rows',result,'count',total,'export_id',export_id);end $$;
revoke all on function pdi_performance_private.sales_manage() from public,anon;grant execute on function pdi_performance_private.sales_manage() to authenticated;
revoke all on function pdi_performance_private.sales_participant(uuid) from public,anon;grant execute on function pdi_performance_private.sales_participant(uuid) to authenticated;
revoke all on function pdi_performance_private.sales_access() from public,anon;grant execute on function pdi_performance_private.sales_access() to authenticated;
revoke all on function pdi_performance_private.sales_context() from public,anon;grant execute on function pdi_performance_private.sales_context() to authenticated;
create function public.pdi_sales_context()returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_context()$$;
revoke all on function public.pdi_sales_context()from public,anon;grant execute on function public.pdi_sales_context()to authenticated;
revoke all on function pdi_performance_private.sales_rules(uuid,text,date,date,jsonb,integer,text) from public,anon;grant execute on function pdi_performance_private.sales_rules(uuid,text,date,date,jsonb,integer,text) to authenticated;
create function public.pdi_sales_rules(p_id uuid,p_name text,p_start date,p_end date,p_rules jsonb,p_revision integer,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_rules(p_id,p_name,p_start,p_end,p_rules,p_revision,p_reason)$$;
revoke all on function public.pdi_sales_rules(uuid,text,date,date,jsonb,integer,text)from public,anon;grant execute on function public.pdi_sales_rules(uuid,text,date,date,jsonb,integer,text)to authenticated;
revoke all on function pdi_performance_private.sales_save(uuid,uuid,uuid,date,jsonb,integer,integer,text) from public,anon;grant execute on function pdi_performance_private.sales_save(uuid,uuid,uuid,date,jsonb,integer,integer,text) to authenticated;
create function public.pdi_sales_save(p_id uuid,p_campaign uuid,p_seller uuid,p_date date,p_data jsonb,p_revision integer,p_campaign_revision integer,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_save(p_id,p_campaign,p_seller,p_date,p_data,p_revision,p_campaign_revision,p_reason)$$;
revoke all on function public.pdi_sales_save(uuid,uuid,uuid,date,jsonb,integer,integer,text)from public,anon;grant execute on function public.pdi_sales_save(uuid,uuid,uuid,date,jsonb,integer,integer,text)to authenticated;
revoke all on function pdi_performance_private.sales_delete(uuid,integer,text) from public,anon;grant execute on function pdi_performance_private.sales_delete(uuid,integer,text) to authenticated;
create function public.pdi_sales_delete(p_id uuid,p_revision integer,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_delete(p_id,p_revision,p_reason)$$;
revoke all on function public.pdi_sales_delete(uuid,integer,text)from public,anon;grant execute on function public.pdi_sales_delete(uuid,integer,text)to authenticated;
revoke all on function pdi_performance_private.sales_export(uuid,date,date,uuid) from public,anon;grant execute on function pdi_performance_private.sales_export(uuid,date,date,uuid) to authenticated;
create function public.pdi_sales_export(p_campaign uuid,p_start date,p_end date,p_seller uuid)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_export(p_campaign,p_start,p_end,p_seller)$$;
revoke all on function public.pdi_sales_export(uuid,date,date,uuid)from public,anon;grant execute on function public.pdi_sales_export(uuid,date,date,uuid)to authenticated;
revoke all on function pdi_performance_private.sales_audit(date,text,integer,boolean) from public,anon;grant execute on function pdi_performance_private.sales_audit(date,text,integer,boolean) to authenticated;
create function public.pdi_sales_audit(p_month date,p_search text,p_offset integer,p_export boolean)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_audit(p_month,p_search,p_offset,p_export)$$;
revoke all on function public.pdi_sales_audit(date,text,integer,boolean)from public,anon;grant execute on function public.pdi_sales_audit(date,text,integer,boolean)to authenticated;
insert into public.pdi_sales_campaigns(id,name)values('cded0000-0000-4000-8000-000000000001','Campanha de Vendas');
notify pgrst,'reload schema';
commit;
