begin;
alter table public.pdi_sales_daily add column import_source jsonb;
create index pdi_sales_import_orders_idx on public.pdi_sales_daily using gin((import_source->'orders')) where not deleted;
create or replace function pdi_performance_private.sales_save(p_id uuid,p_campaign uuid,p_seller uuid,p_date date,p_data jsonb,p_revision integer,p_campaign_revision integer,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
if not pdi_performance_private.sales_manage()and(oldrow.seller_id is distinct from auth.uid()or exists(select 1 from jsonb_each(p_data)e where oldrow.data->e.key is distinct from e.value and jsonb_typeof(oldrow.data->e.key)is distinct from 'null'))then raise exception 'Você pode apenas complementar os indicadores pendentes do próprio lançamento.'using errcode='42501';end if;
if oldrow.deleted or oldrow.revision is distinct from p_revision then raise exception 'O lançamento mudou. Atualize antes de ajustar.'using errcode='40001';end if;
if oldrow.campaign_id<>p_campaign or oldrow.seller_id<>p_seller or oldrow.work_date<>p_date then raise exception 'Participante e data não podem ser alterados; exclua e registre novamente.'using errcode='22023';end if;
if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;
update public.pdi_sales_daily set data=p_data,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid()where id=p_id returning *into newrow;end if;
perform pdi_performance_private.record_event('sales_campaign','lancamentos',case when oldrow.id is null then'SALES_CREATED'else'SALES_UPDATED'end,p_seller,case when oldrow.id is null then null else to_jsonb(oldrow)end,to_jsonb(newrow),p_reason);return jsonb_build_object('id',newrow.id,'revision',newrow.revision);
exception when unique_violation then raise exception 'Já existe lançamento deste participante neste dia.'using errcode='23505';end $$;

create function pdi_performance_private.sales_import(p_campaign uuid,p_campaign_revision integer,p_file_name text,p_file_hash text,p_rows jsonb,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c public.pdi_sales_campaigns%rowtype;r jsonb;g jsonb;oldrow public.pdi_sales_daily%rowtype;newrow public.pdi_sales_daily%rowtype;metrics jsonb;dataj jsonb;sourcej jsonb;k text;n numeric;d date;sid uuid;created integer:=0;updated integer:=0;unchanged integer:=0;total_count integer:=0;batch uuid:=gen_random_uuid();begin
if not pdi_performance_private.sales_manage()then raise exception 'Importação restrita à coordenação, gerência e Diretoria.'using errcode='42501';end if;
if p_file_name is null or length(p_file_name)not between 1 and 200 or p_file_hash is null or p_file_hash!~'^[a-f0-9]{64}$'or p_reason is null or length(btrim(p_reason))not between 10 and 300 or p_rows is null or jsonb_typeof(p_rows)<>'array'then raise exception 'Arquivo, justificativa ou lote inválido.'using errcode='22023';end if;
if jsonb_array_length(p_rows)not between 1 and 2000 then raise exception 'Importe de 1 a 2.000 lançamentos diários por vez.'using errcode='22023';end if;
select *into c from public.pdi_sales_campaigns where id=p_campaign for update;if c.id is null or c.revision is distinct from p_campaign_revision then raise exception 'A campanha mudou. Gere a prévia novamente.'using errcode='40001';end if;
if c.start_date is null then raise exception 'Configure as datas da campanha antes de importar.'using errcode='22023';end if;
if(select count(*)from jsonb_array_elements(p_rows)x)<>(select count(distinct(x->>'seller',x->>'date'))from jsonb_array_elements(p_rows)x)then raise exception 'Participante e data repetidos no lote.'using errcode='22023';end if;
if exists(select 1 from jsonb_array_elements(p_rows)x where jsonb_typeof(x->'orders')is distinct from 'array')then raise exception 'Rastreio dos pedidos inválido.'using errcode='22023';end if;
if(select count(*)from jsonb_array_elements(p_rows)x cross join lateral jsonb_array_elements_text(x->'orders')o)<>(select count(distinct o.value)from jsonb_array_elements(p_rows)x cross join lateral jsonb_array_elements_text(x->'orders')o)then raise exception 'Pedido repetido entre os lançamentos do lote.'using errcode='22023';end if;
for r in select value from jsonb_array_elements(p_rows)order by value->>'seller',value->>'date'loop
sid:=(r->>'seller')::uuid;d:=(r->>'date')::date;if sid is null or d is null or not pdi_performance_private.sales_participant(sid)or d<c.start_date or d>c.end_date or d>pdi_performance_private.today_manaus()then raise exception 'Participante ou data fora da campanha.'using errcode='22023';end if;
metrics:=r->'metrics';if jsonb_typeof(metrics)is distinct from 'object'or(select count(*)from jsonb_object_keys(metrics))<>5 then raise exception 'Matriz de indicadores importados inválida.'using errcode='22023';end if;
foreach k in array ARRAY['salesQty','salesValue','salesArea','fullQty','fullValue']loop if jsonb_typeof(metrics->k)is distinct from 'number'then raise exception 'Indicador numérico obrigatório: %',k using errcode='22023';end if;n:=(metrics->>k)::numeric;if n<0 or n>1000000000000 or n<>trunc(n)then raise exception 'Indicador fora do limite: %',k using errcode='22023';end if;end loop;
if(metrics->>'salesQty')::numeric<1 or(metrics->>'fullQty')::numeric>(metrics->>'salesQty')::numeric or(metrics->>'fullValue')::numeric>(metrics->>'salesValue')::numeric or(metrics->>'fullQty')::numeric=0 and(metrics->>'fullValue')::numeric>0 or jsonb_array_length(r->'orders')<>(metrics->>'salesQty')::numeric or jsonb_array_length(r->'orders')>50000 then raise exception 'Quantidade, valor ou rastreio de pedidos inconsistente.'using errcode='22023';end if;
if exists(select 1 from jsonb_array_elements_text(r->'orders')o where o.value!~'^[0-9]{1,20}$')then raise exception 'Número de pedido inválido.'using errcode='22023';end if;
if exists(select 1 from public.pdi_sales_daily x where x.campaign_id=p_campaign and not x.deleted and(x.seller_id<>sid or x.work_date<>d)and(x.import_source->'orders')?|array(select jsonb_array_elements_text(r->'orders')))then raise exception 'Há pedidos já vinculados a outro vendedor ou data. Revise o vínculo antes de importar.'using errcode='22023';end if;
select *into oldrow from public.pdi_sales_daily where campaign_id=p_campaign and seller_id=sid and work_date=d and not deleted for update;
if oldrow.id is not null and(oldrow.id::text is distinct from r->>'expected_id'or oldrow.revision is distinct from(r->>'expected_revision')::integer)or oldrow.id is null and r->>'expected_id'is not null then raise exception 'Há lançamentos alterados desde a prévia. Leia o XLS novamente.'using errcode='40001';end if;
sourcej:=jsonb_build_object('file_name',p_file_name,'file_sha256',p_file_hash,'orders',r->'orders','metrics',metrics);
if oldrow.id is not null and oldrow.data@>metrics and oldrow.import_source is not distinct from sourcej then unchanged:=unchanged+1;continue;end if;
if oldrow.id is null then
dataj:='{"habitatValue":null,"habitatArea":null,"laminatedValue":null,"laminatedArea":null,"quotesQty":null,"quotesValue":null,"errorsQty":null,"errorsValue":null,"errorsArea":null,"customers":null,"bitrix":null,"notes":""}'::jsonb||metrics;
insert into public.pdi_sales_daily(campaign_id,seller_id,work_date,data,created_by,updated_by,import_source)values(p_campaign,sid,d,dataj,auth.uid(),auth.uid(),sourcej)returning *into newrow;created:=created+1;
else
dataj:=oldrow.data||metrics;
if(dataj->>'habitatValue')::numeric>(dataj->>'salesValue')::numeric or(dataj->>'laminatedValue')::numeric>(dataj->>'salesValue')::numeric or(dataj->>'habitatArea')::numeric>(dataj->>'salesArea')::numeric or(dataj->>'laminatedArea')::numeric>(dataj->>'salesArea')::numeric then raise exception 'As vendas importadas ficaram abaixo dos valores manuais de Habitat/Laminado. Revise antes de importar.'using errcode='22023';end if;
update public.pdi_sales_daily set data=dataj,revision=revision+1,updated_at=clock_timestamp(),updated_by=auth.uid(),import_source=sourcej where id=oldrow.id returning *into newrow;updated:=updated+1;end if;
perform pdi_performance_private.record_event('sales_campaign','importacoes',case when oldrow.id is null then'SALES_XLS_CREATED'else'SALES_XLS_UPDATED'end,sid,case when oldrow.id is null then null else to_jsonb(oldrow)end,to_jsonb(newrow)||jsonb_build_object('import_batch',batch),p_reason);total_count:=total_count+(metrics->>'salesQty')::integer;
end loop;
perform pdi_performance_private.record_event('sales_campaign','importacoes','SALES_XLS_IMPORTED',auth.uid(),null,jsonb_build_object('batch',batch,'file_name',p_file_name,'file_sha256',p_file_hash,'created',created,'updated',updated,'unchanged',unchanged,'orders_changed',total_count),p_reason);
return jsonb_build_object('batch',batch,'created',created,'updated',updated,'unchanged',unchanged);end $$;
revoke all on function pdi_performance_private.sales_import(uuid,integer,text,text,jsonb,text)from public,anon;grant execute on function pdi_performance_private.sales_import(uuid,integer,text,text,jsonb,text)to authenticated;
create function public.pdi_sales_import(p_campaign uuid,p_campaign_revision integer,p_file_name text,p_file_hash text,p_rows jsonb,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.sales_import(p_campaign,p_campaign_revision,p_file_name,p_file_hash,p_rows,p_reason)$$;
revoke all on function public.pdi_sales_import(uuid,integer,text,text,jsonb,text)from public,anon;grant execute on function public.pdi_sales_import(uuid,integer,text,text,jsonb,text)to authenticated;
notify pgrst,'reload schema';commit;
