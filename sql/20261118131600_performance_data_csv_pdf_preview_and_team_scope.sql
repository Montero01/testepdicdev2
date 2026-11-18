begin;
CREATE OR REPLACE FUNCTION public.pdi_logistics_dashboard(p_start date, p_end date, p_vehicle uuid DEFAULT NULL::uuid, p_person uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 if not pdi_performance_private.can_view_module('logistics')then raise exception 'Indicadores restritos à supervisão e gestão de Logística.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 then raise exception 'Período inválido (até 3 anos).'using errcode='22023';end if;
 with f as materialized(select id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where active and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper')))and work_date between p_start and p_end and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule'))),
 movement as(select *from f where kind='movement'),replacements as(select *from f where kind='replacement'),attendance as(select *from f where kind='attendance'),maintenance as(select *from f where kind='maintenance'),schedule as(select *from f where kind='schedule'),fuel as(select *from f where kind='fuel')
 select jsonb_build_object(
 'movement',jsonb_build_object('count',(select count(*)from movement),'m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from movement),'km',(select coalesce(sum((data->>'km')::numeric),0)::text from movement),'collected_cents',(select coalesce(sum((data->>'collected_cents')::bigint),0)::text from movement),'spent_cents',(select coalesce(sum((data->>'spent_cents')::bigint),0)::text from movement),'fee_count',(select count(*)from movement where(data->>'fee')::boolean)),
 'replacement',jsonb_build_object('count',(select count(*)from replacements),'m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from replacements),'km',(select coalesce(sum((data->>'km')::numeric),0)::text from replacements)),
 'attendance',jsonb_build_object('count',(select count(*)from attendance),'people',(select count(distinct person_id)from attendance),'worked_minutes',(select coalesce(sum((data->>'worked_minutes')::int),0)::text from attendance),'expected_minutes',(select coalesce(sum((data->>'expected_minutes')::int),0)::text from attendance),'balance_minutes',(select coalesce(sum((data->>'balance_minutes')::int),0)::text from attendance)),
 'maintenance',jsonb_build_object('count',(select count(*)from maintenance),'cost_cents',(select coalesce(sum((data->>'cost_cents')::bigint),0)::text from maintenance)),
 'schedule',jsonb_build_object('count',(select count(*)from schedule),'estimated_cents',(select coalesce(sum((data->>'estimated_cents')::bigint),0)::text from schedule)),
 'fuel',jsonb_build_object('count',(select count(*)from fuel),'liters',(select coalesce(sum((data->>'liters')::numeric),0)::text from fuel),'cost_cents',(select coalesce(sum((data->>'cost_cents')::bigint),0)::text from fuel),'price_per_liter',(select round(sum((data->>'cost_cents')::numeric)/nullif(sum((data->>'liters')::numeric),0)/100,2)::text from fuel)),
 'alerts',jsonb_build_object('open_maintenance',(select count(*)from public.pdi_logistics_records where kind='maintenance'and active and nullif(data->>'end_date','')is null and(p_vehicle is null or vehicle_id=p_vehicle)),'overdue_schedule',(select count(*)from public.pdi_logistics_records where kind='schedule'and active and data->>'status'='planned'and work_date<pdi_performance_private.today_manaus()and(p_vehicle is null or vehicle_id=p_vehicle))),
 'vehicle_movement',coalesce((select jsonb_agg(jsonb_build_object('id',vehicle_id,'label',name,'value',total::text,'km',km::text,'entries',entries)order by total desc)from(select vehicle_id,max(vehicle_name_snapshot)name,sum((data->>'m2')::numeric)total,sum((data->>'km')::numeric)km,count(*)entries from movement group by vehicle_id)x),'[]'),
 'replacement_sectors',coalesce((select jsonb_agg(jsonb_build_object('label',sector,'value',count)order by count desc)from(select data->>'sector'sector,count(*)from replacements group by data->>'sector')x),'[]'),
 'attendance_people',coalesce((select jsonb_agg(jsonb_build_object('id',person_id,'label',name,'worked',worked::text,'expected',expected::text,'value',balance::text)order by balance desc)from(select person_id,max(person_name_snapshot)name,sum((data->>'worked_minutes')::int)worked,sum((data->>'expected_minutes')::int)expected,sum((data->>'balance_minutes')::int)balance from attendance group by person_id)x),'[]'),
 'maintenance_types',coalesce((select jsonb_agg(jsonb_build_object('label',type,'value',total::text))from(select data->>'maintenance_type'type,sum((data->>'cost_cents')::bigint)total from maintenance group by data->>'maintenance_type')x),'[]'),
 'schedule_dates',coalesce((select jsonb_agg(jsonb_build_object('label',work_date,'value',total::text)order by work_date)from(select work_date,sum((data->>'estimated_cents')::bigint)total from schedule group by work_date)x),'[]'),
 'fuel_vehicles',coalesce((select jsonb_agg(jsonb_build_object('id',vehicle_id,'label',name,'value',total::text)order by total desc)from(select vehicle_id,max(vehicle_name_snapshot)name,sum((data->>'cost_cents')::bigint)total from fuel group by vehicle_id)x),'[]'),
 'daily',coalesce((select jsonb_agg(jsonb_build_object('label',work_date,'value',total::text)order by work_date)from(select work_date,sum((data->>'m2')::numeric)total from movement group by work_date)x),'[]'))into result;
 perform pdi_performance_private.record_event('logistics','dashboard','DASHBOARD_VIEW',p_person,null,jsonb_build_object('start_date',p_start,'end_date',p_end,'vehicle_id',p_vehicle),null);return result;end $function$
;
CREATE OR REPLACE FUNCTION public.pdi_logistics_list(p_kind text, p_start date, p_end date, p_vehicle uuid DEFAULT NULL::uuid, p_person uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_cancelled boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 if not pdi_performance_private.logistics_read()then raise exception 'Acesso restrito à Logística.'using errcode='42501';end if;
 if p_kind not in('movement','replacement','attendance','maintenance','schedule','fuel')or p_kind is null or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Selecione processo e período válidos, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where kind=p_kind and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper')))and work_date between p_start and p_end and(p_cancelled or active)and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule')))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.cash_file_event(p_file uuid, p_action text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare f public.pdi_cash_files%rowtype;k uuid;begin
 if auth.uid()is null or p_action not in('PDF_UPLOAD_CONFIRMED','PDF_UPLOAD_FAILED','PDF_DOWNLOAD_REQUESTED','PDF_DOWNLOAD_TRIGGERED','PDF_DOWNLOAD_FAILED','PDF_VIEW_REQUESTED','PDF_VIEW_OPENED','PDF_VIEW_FAILED')then raise exception 'Operação inválida.'using errcode='42501';end if;
 select *into f from public.pdi_cash_files where id=p_file;
 if f.id is null or not pdi_performance_private.cash_file_can_read(f.storage_path)then raise exception 'Arquivo fora do seu acesso.'using errcode='42501';end if;
 if p_action like 'PDF_UPLOAD%'and f.uploaded_by<>auth.uid()then raise exception 'Envio fora do seu usuário.'using errcode='42501';end if;
 if p_action='PDF_UPLOAD_CONFIRMED'and(f.uploaded_by<>auth.uid()or not exists(select 1 from storage.objects o where o.bucket_id='pdi-cash-pdfs'and o.name=f.storage_path and lower(o.metadata->>'mimetype')='application/pdf'and(o.metadata->>'size')::numeric=f.size_bytes))then raise exception 'Envio do PDF não confirmado no Storage.'using errcode='22023';end if;
 if(p_action like 'PDF_DOWNLOAD%'or p_action like 'PDF_VIEW%')and not exists(select 1 from storage.objects where bucket_id='pdi-cash-pdfs'and name=f.storage_path)then raise exception 'PDF indisponível.'using errcode='22023';end if;
 k:=pdi_performance_private.record_event('cash_daily','arquivos',p_action,f.cashier_id,null,jsonb_build_object('file_id',f.id,'entry_id',f.entry_id,'file_name',f.original_name,'size_bytes',f.size_bytes,'work_date',f.work_date),null);return k;end $function$
;
create or replace function public.pdi_performance_export(p_module text default 'all',p_start date default null,p_end date default null,p_subject uuid default null,p_vehicle uuid default null,p_kind text default null,p_cancelled boolean default true)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
declare result jsonb;events jsonb:='[]';m text;k uuid;c int;begin
 if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 if p_module is null or p_module not in('all','pcp_m2','cash_daily','logistics')or(p_start is null)is distinct from(p_end is null)or(p_start is not null and(not isfinite(p_start)or not isfinite(p_end)or p_start>p_end))or(p_kind is not null and p_kind not in('movement','replacement','attendance','maintenance','schedule','fuel'))then raise exception 'Filtros de exportação inválidos.'using errcode='22023';end if;
 if(p_module<>'all'and not pdi_performance_private.can_view_module(p_module))or(p_module='all'and not(pdi_performance_private.can_view_module('pcp_m2')or pdi_performance_private.can_view_module('cash_daily')or pdi_performance_private.can_view_module('logistics')))then raise exception 'Exportação restrita à gestão autorizada da área.'using errcode='42501';end if;
 with rows as(
 select 'pcp_m2'::text module,'pcp'::text process,to_jsonb(x) data from(select id,pcp_id,work_date,m2_saved,m2_analyzed,order_numbers,pcp_name_snapshot,sector_snapshot,revision,created_at,created_by,updated_at,updated_by from public.pdi_pcp_daily where p_module in('all','pcp_m2')and pdi_performance_private.can_view_module('pcp_m2')and(p_start is null or work_date between p_start and p_end)and(p_subject is null or pcp_id=p_subject))x
 union all select 'pcp_m2','desperdicio',to_jsonb(x)from(select w.entry_id,d.pcp_id,d.work_date,d.pcp_name_snapshot,w.m2_wasted,w.revision,w.created_at,w.created_by,w.updated_at,w.updated_by from public.pdi_pcp_waste w join public.pdi_pcp_daily d on d.id=w.entry_id where p_module in('all','pcp_m2')and pdi_performance_private.can_view_module('pcp_m2')and(p_start is null or d.work_date between p_start and p_end)and(p_subject is null or d.pcp_id=p_subject))x
 union all select 'cash_daily','fechamento',to_jsonb(x)from(select id,cashier_id,work_date,result_cents,cash_cents,credit_cash_cents,credit_installment_cents,debit_cents,pix_cents,installment_plans,pdf_file_id,pdf_name_snapshot,cashier_name_snapshot,sector_snapshot,revision,created_at,created_by,updated_at,updated_by from public.pdi_cash_daily where p_module in('all','cash_daily')and pdi_performance_private.can_view_module('cash_daily')and(p_start is null or work_date between p_start and p_end)and(p_subject is null or cashier_id=p_subject))x
 union all select 'logistics',x.kind,to_jsonb(x)from(select id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where p_module in('all','logistics')and pdi_performance_private.can_view_module('logistics')and(p_start is null or work_date between p_start and p_end)and(p_kind is null or kind=p_kind)and(p_cancelled or active)and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_subject is null or person_id=p_subject or kind in('maintenance','schedule'))and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper'))))x
 union all select 'logistics','cadastro_colaborador',to_jsonb(x)from(select id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_people where p_module in('all','logistics')and pdi_performance_private.can_view_module('logistics')and p_kind is null and(p_subject is null or id=p_subject))x
 union all select 'logistics','cadastro_veiculo',to_jsonb(x)from(select id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_vehicles where p_module in('all','logistics')and pdi_performance_private.can_view_module('logistics')and p_kind is null and(p_vehicle is null or id=p_vehicle))x
 )select coalesce(jsonb_agg(to_jsonb(r)order by module,process,data->>'work_date',coalesce(data->>'id',data->>'entry_id')),'[]')into result from rows r;
 if jsonb_array_length(result)>50000 then raise exception 'Mais de 50.000 linhas: exporte por período ou área. Nenhum arquivo parcial foi gerado.'using errcode='54000';end if;
 foreach m in array array['pcp_m2','cash_daily','logistics']loop
 if p_module in('all',m)and pdi_performance_private.can_view_module(m)then
 select count(*)into c from jsonb_array_elements(result)r where r->>'module'=m;
 k:=pdi_performance_private.record_event(m,'exportacao_dados','DATA_CSV_GENERATED',p_subject,null,jsonb_build_object('rows',c,'start_date',p_start,'end_date',p_end,'person_id',p_subject,'vehicle_id',p_vehicle,'kind',p_kind,'include_cancelled',p_cancelled),null);
 events:=events||jsonb_build_array(jsonb_build_object('id',k,'module',m));end if;end loop;
 return jsonb_build_object('rows',result,'count',jsonb_array_length(result),'events',events,'generated_at',statement_timestamp());end $$;
revoke all on function public.pdi_performance_export(text,date,date,uuid,uuid,text,boolean)from public,anon;grant execute on function public.pdi_performance_export(text,date,date,uuid,uuid,text,boolean)to authenticated;
create or replace function pdi_performance_private.performance_export_dispatched(p_event uuid)returns uuid language plpgsql security definer set search_path=pg_catalog as $$declare e public.pdi_performance_events%rowtype;k uuid;begin
 if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 select *into e from public.pdi_performance_events where id=p_event and actor_id=auth.uid()and action='DATA_CSV_GENERATED';
 if e.id is null or not pdi_performance_private.can_view_module(e.module_key)then raise exception 'Exportação fora do seu acesso.'using errcode='42501';end if;
 k:=pdi_performance_private.record_event(e.module_key,'exportacao_dados','DATA_CSV_DOWNLOAD_TRIGGERED',e.subject_id,null,jsonb_build_object('export_event_id',e.id,'filters',e.after_data),null);return k;end$$;
revoke all on function pdi_performance_private.performance_export_dispatched(uuid)from public,anon;grant execute on function pdi_performance_private.performance_export_dispatched(uuid)to authenticated;
create or replace function public.pdi_performance_export_dispatched(p_event uuid)returns uuid language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.performance_export_dispatched(p_event)$$;
revoke all on function public.pdi_performance_export_dispatched(uuid)from public,anon;grant execute on function public.pdi_performance_export_dispatched(uuid)to authenticated;
notify pgrst,'reload schema';commit;
