-- Indicadores, filtros, exportação e exclusão aceitam desperdício pendente do diário.
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_daily_entry()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare p public.profiles%rowtype; uid uuid:=auth.uid();
 caller_role text:=coalesce(current_setting('role',true),'none');
 trusted boolean; count_orders integer;
begin
 if tg_op='INSERT'and new.is_deleted then raise exception 'Não é permitido inserir registro excluído.'using errcode='42501';end if;
 if tg_op='UPDATE'and pdi_performance_private.soft_delete_guard(to_jsonb(old),to_jsonb(new))then new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();new.revision:=old.revision+1;return new;end if;
 
 trusted:=caller_role='service_role' or (caller_role in ('none','postgres') and session_user in ('postgres','supabase_admin'));
 if tg_op='DELETE' then
   if not trusted then raise exception 'Lançamentos não podem ser excluídos pelo aplicativo.' using errcode='42501'; end if;
   return old;
 end if;
 if uid is null and not trusted then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 -- O tipo numeric do banco preserva milésimos de m². NaN/infinito são recusados explicitamente.
 perform pg_advisory_xact_lock(hashtextextended('pcp-waste:'||new.pcp_id::text||':'||new.work_date::text,0));
 if new.m2_saved is null or new.m2_saved::text in ('NaN','Infinity','-Infinity') or new.m2_saved<0 or new.m2_saved>=1000000000 or scale(new.m2_saved)>3 then
   raise exception 'Informe uma quantidade válida de m², com até 3 casas decimais.' using errcode='22023';
 end if;
 if new.m2_analyzed is null or new.m2_analyzed::text in('NaN','Infinity','-Infinity') or new.m2_analyzed<0 or new.m2_analyzed>=1000000000 or scale(new.m2_analyzed)>3 then
 raise exception 'Informe os m² analisados, com até 3 casas decimais.' using errcode='22023';end if;
 if new.m2_saved>new.m2_analyzed then raise exception 'Os m² salvos não podem superar os analisados.' using errcode='22023';end if;
 if exists(select 1 from public.pdi_pcp_waste w where w.pcp_id=new.pcp_id and w.work_date=new.work_date and not w.is_deleted and w.m2_wasted+new.m2_saved>new.m2_analyzed)then raise exception 'Analisado deve comportar os m² salvos e o desperdício já registrado.' using errcode='22023';end if;
 if new.order_numbers is null or array_ndims(new.order_numbers)>1 then
   raise exception 'Lista de pedidos inválida.' using errcode='22023';
 end if;
 count_orders:=cardinality(new.order_numbers);
 if count_orders>200 or exists(select 1 from unnest(new.order_numbers) o where o is null or o !~ '^[0-9]{1,20}$')
   or count_orders<>(select count(distinct o) from unnest(new.order_numbers) o) then
   raise exception 'Use até 200 números de pedidos distintos, somente dígitos, com até 20 caracteres cada.' using errcode='22023';
 end if;
 if (new.m2_saved>0 or new.m2_analyzed>0) and count_orders=0 then raise exception 'Informe os pedidos relacionados aos m² salvos.' using errcode='22023'; end if;
 if tg_op='INSERT' then
   select * into p from public.profiles where id=new.pcp_id;
   if p.id is null or(lower(btrim(coalesce(p.position,'')))<>'pcp'and pdi_access_private.mode('pcp_m2',new.pcp_id)is distinct from'collect') then
     raise exception 'O colaborador precisa ter position PCP.' using errcode='42501'; end if;
   if not trusted and not pdi_performance_private.can_collect_module('pcp_m2') then raise exception 'Gerência e Diretoria possuem acesso somente de consulta.' using errcode='42501'; end if;
   if not trusted and (new.pcp_id<>uid or new.work_date is distinct from pdi_performance_private.today_manaus()) then
     raise exception 'O PCP registra somente o próprio resultado de hoje.' using errcode='42501'; end if;
   new.pcp_name_snapshot:=coalesce(p.full_name,'PCP'); new.sector_snapshot:=p.sector;
   new.created_at:=clock_timestamp(); new.created_by:=uid;
   new.revision:=1; new.edit_reason:=null;
 else
   if new.id is distinct from old.id or new.pcp_id is distinct from old.pcp_id or new.work_date is distinct from old.work_date
     or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by
     or new.pcp_name_snapshot is distinct from old.pcp_name_snapshot or new.sector_snapshot is distinct from old.sector_snapshot then
     raise exception 'A identidade, data e origem do lançamento não podem ser alteradas.' using errcode='22023'; end if;
   if not trusted and not pdi_performance_private.can_correct_module('pcp_m2') then
     raise exception 'Somente a supervisão do setor pode corrigir o lançamento.' using errcode='42501'; end if;
   if length(btrim(coalesce(new.edit_reason,'')))<10 or length(new.edit_reason)>300 then
     raise exception 'Informe uma justificativa de 10 a 300 caracteres.' using errcode='22023'; end if;
   if new.m2_saved=old.m2_saved and new.order_numbers=old.order_numbers and new.m2_analyzed is not distinct from old.m2_analyzed then
     raise exception 'Não há alteração nos m² ou pedidos.' using errcode='22023'; end if;
   new.revision:=old.revision+1;
 end if;
 new.updated_at:=clock_timestamp(); new.updated_by:=uid;
 return new;
end $function$;

CREATE OR REPLACE FUNCTION public.pdi_pcp_dashboard(p_start_date date, p_end_date date, p_pcp_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare payload jsonb;begin
 perform pdi_access_private.assert_allowed('pcp_m2',false);

 if not pdi_performance_private.can_view_module('pcp_m2')then raise exception 'Dashboard restrito à gestão de Produção.' using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date)or not isfinite(p_end_date)or p_start_date>p_end_date then raise exception 'Período inválido.' using errcode='22023';end if;
 with f as materialized(select d.id,coalesce(d.pcp_id,w.pcp_id)pcp_id,coalesce(d.work_date,w.work_date)work_date,coalesce(d.pcp_name_snapshot,w.pcp_name_snapshot)pcp_name_snapshot,d.m2_saved,d.m2_analyzed,greatest(d.updated_at,w.updated_at)updated_at,w.m2_wasted from public.pdi_pcp_daily d full join public.pdi_pcp_waste w on w.entry_id=d.id where coalesce(d.work_date,w.work_date)between p_start_date and p_end_date and(p_pcp_id is null or coalesce(d.pcp_id,w.pcp_id)=p_pcp_id)),
 g as(select pcp_id,(array_agg(pcp_name_snapshot order by work_date desc,updated_at desc))[1]name,count(*)entry_count,sum(m2_saved)saved,sum(m2_analyzed)analyzed,sum(m2_wasted)wasted,count(*)filter(where m2_analyzed is null or m2_wasted is null)pending,
 case when count(*)filter(where m2_analyzed is null or m2_wasted is null)=0 then round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)end utilization from f group by pcp_id),
 r as(select g.*,dense_rank()over(order by saved desc nulls last)place from g)
 select jsonb_build_object('total_m2',(select case when count(*)=0 then '0'else sum(m2_saved)::text end from f),'total_analyzed',(select sum(m2_analyzed)::text from f),'total_wasted',(select sum(m2_wasted)::text from f),
 'entry_count',(select count(*)from f),'pcp_count',(select count(*)from g),'pending_count',(select count(*)from f where m2_analyzed is null or m2_wasted is null),
 'composition',(select jsonb_build_object('analyzed',sum(m2_analyzed)::text,'saved',sum(m2_saved)::text,'wasted',sum(m2_wasted)::text,'regular',(sum(m2_analyzed)-sum(m2_saved)-sum(m2_wasted))::text,'entries',count(*))from f where m2_analyzed is not null and m2_wasted is not null),'can_record_waste',pdi_performance_private.can_record_pcp_waste(),
 'utilization_percent',(select round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null and m2_wasted is not null),
 'waste_percent',(select round(sum(m2_wasted)*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null and m2_wasted is not null),
 'recovery_percent',(select round(sum(m2_saved)*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null),
 'ranking',coalesce((select jsonb_agg(jsonb_build_object('pcp_id',pcp_id,'name',name,'total_m2',saved::text,'total_analyzed',analyzed::text,'total_wasted',wasted::text,'entry_count',entry_count,'pending_count',pending,'utilization_percent',utilization::text,'place',place,'share_percent',coalesce(round(saved*100/nullif((select sum(saved)from g),0),2),0)::text,'bar_percent',coalesce(round(saved*100/nullif((select max(saved)from g),0),2),0)::text)order by saved desc nulls last,name)from r),'[]'),
 'daily',coalesce((select jsonb_agg(jsonb_build_object('date',work_date,'saved',saved::text,'analyzed',analyzed::text,'wasted',wasted::text,'pending_count',pending,'utilization_percent',utilization::text)order by work_date)from(select work_date,sum(m2_saved)saved,sum(m2_analyzed)analyzed,sum(m2_wasted)wasted,count(*)filter(where m2_analyzed is null or m2_wasted is null)pending,case when count(*)filter(where m2_analyzed is null or m2_wasted is null)=0 then round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)end utilization from f group by work_date)x),'[]'),'updated_at',statement_timestamp())into payload;
 perform pdi_performance_private.record_event('pcp_m2','dashboard','DASHBOARD_VIEW',p_pcp_id,null,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'source','pdi_pcp_dashboard'),null);
 return payload;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_pcp_waste_entries(p_start_date date, p_end_date date, p_pcp_id uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ declare result jsonb;begin
 perform pdi_access_private.assert_allowed('pcp_m2',false);

 if not(pdi_performance_private.can_view_module('pcp_m2')or pdi_performance_private.can_collect_module('pcp_m2'))then raise exception 'Acesso restrito à gestão de Produção.' using errcode='42501';end if;
 if p_offset<0 or p_start_date is null or p_end_date is null or p_start_date>p_end_date then raise exception 'Filtro inválido.' using errcode='22023';end if;
 with f as materialized(select coalesce(d.id,w.id)id,w.id waste_id,coalesce(d.pcp_id,w.pcp_id)pcp_id,coalesce(d.work_date,w.work_date)work_date,coalesce(d.pcp_name_snapshot,w.pcp_name_snapshot)pcp_name_snapshot,d.m2_analyzed,d.m2_saved,w.m2_wasted,w.revision as waste_revision,w.entry_id,w.notes as waste_notes from public.pdi_pcp_daily d full join public.pdi_pcp_waste w on w.entry_id=d.id where coalesce(d.work_date,w.work_date)between p_start_date and p_end_date and(p_pcp_id is null or coalesce(d.pcp_id,w.pcp_id)=p_pcp_id))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id limit 30 offset p_offset)x),'[]'))into result;return result;end $function$;

CREATE OR REPLACE FUNCTION pdi_performance_private.delete_performance(p_module text, p_entity text, p_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare cfg jsonb;t text;pk text;before_row jsonb;k uuid;child_id uuid;begin
 if not pdi_performance_private.performance_manager()then raise exception 'Exclusão restrita à gerência e Diretoria.'using errcode='42501';end if;
 if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique a exclusão em 10 a 300 caracteres.'using errcode='22023';end if;
 select deletion_targets->p_entity into cfg from public.pdi_indicator_modules where module_key=p_module and enabled;
 t:=cfg->>'table';pk:=cfg->>'pk';if t is null or pk not in('id','entry_id')or t!~'^pdi_[a-z0-9_]+$'then raise exception 'Processo não habilitado para exclusão.'using errcode='22023';end if;
 execute format('select to_jsonb(x)from public.%I x where %I=$1 and not is_deleted for update',t,pk)into before_row using p_id;
 if before_row is null or(p_module='stock'and before_row->>'origin_module'<>'stock')then raise exception 'Registro não encontrado neste processo.'using errcode='22023';end if;
 execute format('update public.%I set is_deleted=true where %I=$1',t,pk)using p_id;
 if t='pdi_pcp_daily'then for child_id in select id from public.pdi_pcp_waste where entry_id=p_id and not is_deleted loop perform pdi_performance_private.delete_performance('pcp_m2','waste',child_id,p_reason);end loop;end if;
 if t='pdi_logistics_records'and before_row->>'kind'='movement'and before_row->>'origin_module'='stock'then for child_id in select id from public.pdi_logistics_records where kind='stock_waste'and not is_deleted and data->>'stock_entry'=p_id::text loop perform pdi_performance_private.delete_performance('stock','records',child_id,p_reason);end loop;end if;
 k:=pdi_performance_private.record_event(case when p_module='stock'then'logistics'else p_module end,'exclusao','PERFORMANCE_DELETED',coalesce((before_row->>'pcp_id')::uuid,(before_row->>'cashier_id')::uuid,(before_row->>'person_id')::uuid),before_row,jsonb_build_object('record_id',p_id,'table',t,'module',p_module,'is_deleted',true),p_reason);return k;end$function$;

CREATE OR REPLACE FUNCTION public.pdi_performance_export(p_module text DEFAULT 'all'::text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_subject uuid DEFAULT NULL::uuid, p_vehicle uuid DEFAULT NULL::uuid, p_kind text DEFAULT NULL::text, p_cancelled boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;events jsonb:='[]';m text;k uuid;c int;begin
 if p_module<>'all'then perform pdi_access_private.assert_allowed(p_module,false);end if;

 if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 if p_module is null or p_module not in('all','pcp_m2','cash_daily','logistics')or(p_start is null)is distinct from(p_end is null)or(p_start is not null and(not isfinite(p_start)or not isfinite(p_end)or p_start>p_end))or(p_kind is not null and p_kind not in('movement','replacement','attendance','maintenance','schedule','fuel'))then raise exception 'Filtros de exportação inválidos.'using errcode='22023';end if;
 if(p_module<>'all'and not pdi_performance_private.can_view_module(p_module))or(p_module='all'and not(pdi_performance_private.can_view_module('pcp_m2')or pdi_performance_private.can_view_module('cash_daily')or pdi_performance_private.can_view_module('logistics')))then raise exception 'Exportação restrita à gestão autorizada da área.'using errcode='42501';end if;
 with rows as(
 select 'pcp_m2'::text module,'pcp'::text process,to_jsonb(x) data from(select id,pcp_id,work_date,m2_saved,m2_analyzed,order_numbers,pcp_name_snapshot,sector_snapshot,revision,created_at,created_by,updated_at,updated_by from public.pdi_pcp_daily where p_module in('all','pcp_m2')and pdi_performance_private.can_view_module('pcp_m2')and(p_start is null or work_date between p_start and p_end)and(p_subject is null or pcp_id=p_subject))x
 union all select 'pcp_m2','desperdicio',to_jsonb(x)from(select w.id,w.entry_id,w.pcp_id,w.work_date,w.pcp_name_snapshot,w.m2_wasted,w.notes,w.revision,w.created_at,w.created_by,w.updated_at,w.updated_by,(w.entry_id is null)pending_daily from public.pdi_pcp_waste w where p_module in('all','pcp_m2')and pdi_performance_private.can_view_module('pcp_m2')and(p_start is null or w.work_date between p_start and p_end)and(p_subject is null or w.pcp_id=p_subject))x
 union all select 'cash_daily','fechamento',to_jsonb(x)from(select id,cashier_id,work_date,result_cents,cash_cents,credit_cash_cents,credit_installment_cents,debit_cents,pix_cents,installment_plans,pdf_file_id,pdf_name_snapshot,cashier_name_snapshot,sector_snapshot,revision,created_at,created_by,updated_at,updated_by from public.pdi_cash_daily where p_module in('all','cash_daily')and pdi_performance_private.can_view_module('cash_daily')and(p_start is null or work_date between p_start and p_end)and(p_subject is null or cashier_id=p_subject))x
 union all select 'logistics',x.kind,to_jsonb(x)from(select id,kind,origin_module,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where p_module in('all','logistics')and pdi_performance_private.can_view_module('logistics')and(p_start is null or work_date between p_start and p_end)and(p_kind is null or kind=p_kind)and(p_cancelled or active)and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_subject is null or person_id=p_subject or kind in('maintenance','schedule'))and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper'))))x
 union all select 'logistics','cadastro_colaborador',to_jsonb(x)from(select id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_people where p_module in('all','logistics')and pdi_performance_private.can_view_module('logistics')and p_kind is null and(p_subject is null or id=p_subject))x
 union all select 'logistics','cadastro_veiculo',to_jsonb(x)from(select id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_vehicles where p_module in('all','logistics')and pdi_performance_private.can_view_module('logistics')and p_kind is null and(p_vehicle is null or id=p_vehicle))x
 )select coalesce(jsonb_agg(to_jsonb(r)order by module,process,data->>'work_date',coalesce(data->>'id',data->>'entry_id')),'[]')into result from rows r;
 if jsonb_array_length(result)>50000 then raise exception 'Mais de 50.000 linhas: exporte por período ou área. Nenhum arquivo parcial foi gerado.'using errcode='54000';end if;
 foreach m in array array['pcp_m2','cash_daily','logistics']loop
 if p_module in('all',m)and pdi_performance_private.can_view_module(m)then
 select count(*)into c from jsonb_array_elements(result)r where r->>'module'=m;
 k:=pdi_performance_private.record_event(m,'exportacao_dados','DATA_CSV_GENERATED',p_subject,null,jsonb_build_object('rows',c,'start_date',p_start,'end_date',p_end,'person_id',p_subject,'vehicle_id',p_vehicle,'kind',p_kind,'include_cancelled',p_cancelled),null);
 events:=events||jsonb_build_array(jsonb_build_object('id',k,'module',m));end if;end loop;
 return jsonb_build_object('rows',result,'count',jsonb_array_length(result),'events',events,'generated_at',statement_timestamp());end $function$;
