-- Aplicado após autorização explícita da Diretoria; permissões anteriores preservadas.
CREATE OR REPLACE FUNCTION public.pdi_audit_export_history(p_module text, p_month date, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ declare result jsonb;begin
 if p_module<>'all'then perform pdi_access_private.assert_allowed(p_module,false);end if;

 if auth.uid()is null or p_module not in('pcp_m2','cash_daily','logistics')or not pdi_performance_private.can_audit_module(p_module)then raise exception 'Consulta restrita à gestão da área.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_offset<0 or length(coalesce(p_search,''))>150 then raise exception 'Filtro inválido.'using errcode='22023';end if;
 with f as materialized(select *from public.pdi_audit_exports e where module_key=p_module and reference_month=p_month and(coalesce(p_search,'')=''or strpos(pdi_performance_private.audit_search_text(concat_ws(' ',e.actor_name,e.actor_email,e.actor_id::text,e.search_text)),pdi_performance_private.audit_search_text(p_search))>0))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by created_at desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_audit_query(p_module text, p_month date, p_search text DEFAULT ''::text, p_subject uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_export boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare payload jsonb;n int;export_id uuid;start_at timestamptz;end_at timestamptz;begin
 if p_module<>'all'then perform pdi_access_private.assert_allowed(p_module,false);end if;

 if auth.uid()is null or p_module not in('pcp_m2','cash_daily','logistics')or not pdi_performance_private.can_audit_module(p_module)then raise exception 'Log restrito à gerência da área e Diretoria.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or extract(day from p_month)<>1 or p_offset<0 or length(coalesce(p_search,''))>150 then raise exception 'Mês ou pesquisa inválida.'using errcode='22023';end if;
 start_at:=p_month::timestamp at time zone 'America/Manaus';end_at:=(p_month+interval'1 month')at time zone 'America/Manaus';
 with events as materialized(
 select a.id,a.module_key,a.action,a.actor_id,a.actor_name,a.actor_role,p.email actor_email,a.database_actor,a.occurred_at,a.reason,a.before_data,a.after_data,a.pcp_id subject_id,case when a.module_key='pcp_waste'then'desperdicio'else'pcp'end process from public.pdi_performance_audit a left join public.profiles p on p.id=a.actor_id where p_module='pcp_m2'and a.occurred_at>=start_at and a.occurred_at<end_at and(p_subject is null or a.pcp_id=p_subject)
 union all select a.id,'cash_daily',a.action,a.actor_id,a.actor_name,a.actor_role,p.email,a.database_actor,a.occurred_at,a.reason,a.before_data,a.after_data,a.cashier_id,'caixa' from public.pdi_cash_audit a left join public.profiles p on p.id=a.actor_id where p_module='cash_daily'and a.occurred_at>=start_at and a.occurred_at<end_at and(p_subject is null or a.cashier_id=p_subject)

 union all select e.id,e.module_key,e.action,e.actor_id,e.actor_name,e.actor_role,e.actor_email,e.database_actor,e.occurred_at,e.reason,e.before_data,e.after_data,e.subject_id,e.process from public.pdi_performance_events e where e.module_key=p_module and e.occurred_at>=start_at and e.occurred_at<end_at and(p_subject is null or e.subject_id=p_subject)
 union all select e.id,e.module_key,'CSV_GENERATED',e.actor_id,e.actor_name,e.actor_role,e.actor_email,'application',e.created_at,null,null,to_jsonb(e),e.subject_id,'exportacao' from public.pdi_audit_exports e where e.module_key=p_module and e.created_at>=start_at and e.created_at<end_at and(p_subject is null or e.subject_id=p_subject)
 union all select e.id,e.module_key,'CSV_DOWNLOAD_TRIGGERED',e.actor_id,e.actor_name,e.actor_role,e.actor_email,'application',e.download_triggered_at,null,null,to_jsonb(e),e.subject_id,'exportacao' from public.pdi_audit_exports e where e.module_key=p_module and e.download_triggered_at>=start_at and e.download_triggered_at<end_at and(p_subject is null or e.subject_id=p_subject)

 union all select a.id,p_module,case when a.action='REVOKE'then'DELETE_PDI_AREA_MEMBERSHIPS'when a.before_data is null then'INSERT_PDI_AREA_MEMBERSHIPS'else'UPDATE_PDI_AREA_MEMBERSHIPS'end,a.actor_id,p.full_name,p.role,p.email,'legacy_access',a.occurred_at,null,a.before_data,a.after_data,coalesce(a.after_data->>'profile_id',a.before_data->>'profile_id')::uuid,'acessos' from public.pdi_area_access_audit a left join public.profiles p on p.id=a.actor_id where pdi_performance_private.is_indicator_admin()and a.occurred_at>=start_at and a.occurred_at<end_at and coalesce(a.after_data->>'area_key',a.before_data->>'area_key')=(select area_key from public.pdi_indicator_modules where module_key=p_module)and(p_subject is null or coalesce(a.after_data->>'profile_id',a.before_data->>'profile_id')::uuid=p_subject)and not exists(select 1 from public.pdi_performance_events e where e.module_key=p_module and e.process='acessos'and e.actor_id is not distinct from a.actor_id and e.before_data is not distinct from a.before_data and e.after_data is not distinct from a.after_data)
 ),filtered as materialized(select *from events e where coalesce(p_search,'')=''or strpos(pdi_performance_private.audit_search_text(concat_ws(' ',e.actor_name,e.actor_email,e.actor_id::text,e.action,e.process,e.reason,e.before_data::text,e.after_data::text)),pdi_performance_private.audit_search_text(p_search))>0)
 select jsonb_build_object('count',(select count(*)from filtered),'month',p_month,'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from filtered order by occurred_at desc,id desc limit(case when p_export then 50001 else 30 end)offset(case when p_export then 0 else p_offset end))x),'[]'))into payload;
 n:=(payload->>'count')::int;if p_export then
 if n>50000 then raise exception 'Mais de 50 mil eventos: refine a pesquisa ou selecione um colaborador.'using errcode='22023';end if;
 export_id:=pdi_performance_private.record_audit_export(p_module,p_month,p_search,p_subject,n);payload:=payload||jsonb_build_object('export_id',export_id);end if;return payload;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_cash_dashboard(p_start_date date, p_end_date date, p_cashier_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 perform pdi_access_private.assert_allowed('cash_daily',false);

 if auth.uid()is null or not pdi_performance_private.can_view_module('cash_daily')then raise exception 'Dashboard restrito à gestão financeira autorizada.'using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date)or not isfinite(p_end_date)or p_start_date>p_end_date then raise exception 'Período inválido.'using errcode='22023';end if;
 with filtered as materialized(select d.id,d.cashier_id,d.cashier_name_snapshot,d.work_date,d.updated_at,d.result_cents,d.cash_cents,d.credit_cash_cents,d.credit_installment_cents,d.debit_cents,d.pix_cents from public.pdi_cash_daily d where d.work_date between p_start_date and p_end_date and(p_cashier_id is null or d.cashier_id=p_cashier_id))
 select jsonb_build_object('result_cents',coalesce(sum(result_cents),0)::text,'cash_cents',coalesce(sum(cash_cents),0)::text,'credit_cash_cents',coalesce(sum(credit_cash_cents),0)::text,'credit_installment_cents',coalesce(sum(credit_installment_cents),0)::text,'debit_cents',coalesce(sum(debit_cents),0)::text,'pix_cents',coalesce(sum(pix_cents),0)::text,'entry_count',count(*),'cashier_count',count(distinct cashier_id),'updated_at',statement_timestamp(),
 'daily',coalesce((select jsonb_agg(to_jsonb(x)order by x.date)from(select work_date as date,sum(result_cents)::text result_cents,sum(cash_cents)::text cash_cents,sum(credit_cash_cents)::text credit_cash_cents,sum(credit_installment_cents)::text credit_installment_cents,sum(debit_cents)::text debit_cents,sum(pix_cents)::text pix_cents,count(*)entries from filtered group by work_date)x),'[]'),
 'cashiers',coalesce((select jsonb_agg(to_jsonb(x)order by x.name,x.id)from(select cashier_id as id,(array_agg(cashier_name_snapshot order by work_date desc,updated_at desc,id))[1]name,sum(result_cents)::text result_cents,count(*)entries,round(sum(result_cents)/nullif(count(*),0),0)::text avg_cents from filtered group by cashier_id)x),'[]'))into result from filtered;
 perform pdi_performance_private.record_event('cash_daily','dashboard','DASHBOARD_VIEW',p_cashier_id,null,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'source','pdi_cash_dashboard'),null);return result;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_cash_file_event(p_file_id uuid, p_action text)
 RETURNS uuid
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.cash_file_event(p_file_id,p_action) where pdi_access_private.assert_allowed('cash_daily',false) $function$;

CREATE OR REPLACE FUNCTION public.pdi_cash_reserve_pdf(p_entry_id uuid, p_cashier_id uuid, p_work_date date, p_original_name text, p_size_bytes bigint)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.cash_reserve_pdf(p_entry_id,p_cashier_id,p_work_date,p_original_name,p_size_bytes) where pdi_access_private.assert_allowed('cash_daily',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_delete_performance(p_module text, p_entity text, p_id uuid, p_reason text)
 RETURNS uuid
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.delete_performance(p_module,p_entity,p_id,p_reason) where pdi_access_private.assert_allowed(p_module,true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_deletion_list(p_module text, p_entity text, p_start date, p_end date, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.deletion_list(p_module,p_entity,p_start,p_end,p_offset) where pdi_access_private.assert_allowed(p_module,false) $function$;

CREATE OR REPLACE FUNCTION public.pdi_eg_command(p_action text, p_id uuid DEFAULT NULL::uuid, p_data jsonb DEFAULT '{}'::jsonb, p_revision integer DEFAULT NULL::integer, p_reason text DEFAULT NULL::text, p_request_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_eg_private.request(p_action,p_id,p_data,p_revision,p_reason,p_request_id) where pdi_access_private.assert_allowed('erika_glass',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_eg_export_log(p_kind text, p_count integer, p_filters jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_eg_private.export_log(p_kind,p_count,p_filters) where pdi_access_private.assert_allowed('erika_glass',false) $function$;

CREATE OR REPLACE FUNCTION public.pdi_eg_photo(p_action text, p_visit uuid, p_phase text DEFAULT NULL::text, p_path text DEFAULT NULL::text, p_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_eg_private.photo(p_action,p_visit,p_phase,p_path,p_name) where pdi_access_private.assert_allowed('erika_glass',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_fuel_budget_save(p_month date, p_cents bigint, p_reason text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare k uuid;rev int;begin
 perform pdi_access_private.assert_allowed('logistics',true);

 if not pdi_performance_private.performance_manager()then raise exception 'Orçamento restrito à gerência e Diretoria.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_month<>date_trunc('month',p_month)::date then raise exception 'Selecione um mês válido.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('fuel_budget:'||p_month::text,0));select id,revision into k,rev from public.pdi_logistics_records where kind='fuel_budget'and work_date=p_month and active;
 if k is null then insert into public.pdi_logistics_records(kind,work_date,origin_module,data)values('fuel_budget',p_month,'logistics',jsonb_build_object('budget_cents',p_cents))returning id into k;
 else update public.pdi_logistics_records set data=jsonb_build_object('budget_cents',p_cents),reason=p_reason where id=k and revision=rev;end if;return k;end$function$;

CREATE OR REPLACE FUNCTION public.pdi_fuel_month(p_month date)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.fuel_month(p_month) where pdi_access_private.assert_allowed('logistics',false) $function$;

CREATE OR REPLACE FUNCTION public.pdi_logistics_dashboard(p_start date, p_end date, p_vehicle uuid DEFAULT NULL::uuid, p_person uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 perform pdi_access_private.assert_allowed('logistics',false);

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
 perform pdi_performance_private.record_event('logistics','dashboard','DASHBOARD_VIEW',p_person,null,jsonb_build_object('start_date',p_start,'end_date',p_end,'vehicle_id',p_vehicle),null);return result;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_logistics_list(p_kind text, p_start date, p_end date, p_vehicle uuid DEFAULT NULL::uuid, p_person uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_cancelled boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 perform pdi_access_private.assert_allowed('logistics',false);

 if not pdi_performance_private.logistics_read()then raise exception 'Acesso restrito à Logística.'using errcode='42501';end if;
 if p_kind not in('movement','replacement','attendance','maintenance','schedule','fuel')or p_kind is null or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Selecione processo e período válidos, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,kind,origin_module,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where kind=p_kind and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper')))and work_date between p_start and p_end and(p_cancelled or active)and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule')))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_logistics_save(p_id uuid, p_kind text, p_day date, p_vehicle uuid, p_person uuid, p_data jsonb, p_revision integer DEFAULT NULL::integer, p_active boolean DEFAULT true, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare r record;begin
 perform pdi_access_private.assert_allowed('logistics',true);

 if p_revision is null then
 begin insert into public.pdi_logistics_records(id,kind,work_date,vehicle_id,person_id,data)values(p_id,p_kind,p_day,p_vehicle,p_person,p_data)returning id,revision into r;
 exception when unique_violation then
 select id,revision into r from public.pdi_logistics_records where id=p_id and created_by=auth.uid()and kind=p_kind;
 if r.id is null then raise exception 'Já existe um apontamento de jornada para esse colaborador/dia ou identificação duplicada.'using errcode='23505';end if;
 return jsonb_build_object('id',r.id,'revision',r.revision,'already_saved',true);end;
 else
 update public.pdi_logistics_records set work_date=p_day,vehicle_id=p_vehicle,person_id=p_person,data=p_data,active=p_active,reason=p_reason where id=p_id and kind=p_kind and revision=p_revision returning id,revision into r;
 if r.id is null then raise exception 'Registro alterado por outra pessoa ou fora do seu acesso. Atualize antes de ajustar.'using errcode='40001';end if;end if;
 return jsonb_build_object('id',r.id,'revision',r.revision,'already_saved',false);end $function$;

CREATE OR REPLACE FUNCTION public.pdi_pcp_dashboard(p_start_date date, p_end_date date, p_pcp_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare payload jsonb;begin
 perform pdi_access_private.assert_allowed('pcp_m2',false);

 if not pdi_performance_private.can_view_module('pcp_m2')then raise exception 'Dashboard restrito à gestão de Produção.' using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date)or not isfinite(p_end_date)or p_start_date>p_end_date then raise exception 'Período inválido.' using errcode='22023';end if;
 with f as materialized(select d.id,d.pcp_id,d.work_date,d.pcp_name_snapshot,d.m2_saved,d.m2_analyzed,d.updated_at,w.m2_wasted from public.pdi_pcp_daily d left join public.pdi_pcp_waste w on w.entry_id=d.id where d.work_date between p_start_date and p_end_date and(p_pcp_id is null or d.pcp_id=p_pcp_id)),
 g as(select pcp_id,(array_agg(pcp_name_snapshot order by work_date desc,updated_at desc))[1]name,count(*)entry_count,sum(m2_saved)saved,sum(m2_analyzed)analyzed,sum(m2_wasted)wasted,count(*)filter(where m2_analyzed is null or m2_wasted is null)pending,
 case when count(*)filter(where m2_analyzed is null or m2_wasted is null)=0 then round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)end utilization from f group by pcp_id),
 r as(select g.*,dense_rank()over(order by saved desc)place from g)
 select jsonb_build_object('total_m2',coalesce((select sum(m2_saved)from f),0)::text,'total_analyzed',(select sum(m2_analyzed)::text from f),'total_wasted',(select sum(m2_wasted)::text from f),
 'entry_count',(select count(*)from f),'pcp_count',(select count(*)from g),'pending_count',(select count(*)from f where m2_analyzed is null or m2_wasted is null),
 'composition',(select jsonb_build_object('analyzed',sum(m2_analyzed)::text,'saved',sum(m2_saved)::text,'wasted',sum(m2_wasted)::text,'regular',(sum(m2_analyzed)-sum(m2_saved)-sum(m2_wasted))::text,'entries',count(*))from f where m2_analyzed is not null and m2_wasted is not null),'can_record_waste',pdi_performance_private.can_record_pcp_waste(),
 'utilization_percent',(select round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null and m2_wasted is not null),
 'waste_percent',(select round(sum(m2_wasted)*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null and m2_wasted is not null),
 'recovery_percent',(select round(sum(m2_saved)*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null),
 'ranking',coalesce((select jsonb_agg(jsonb_build_object('pcp_id',pcp_id,'name',name,'total_m2',saved::text,'total_analyzed',analyzed::text,'total_wasted',wasted::text,'entry_count',entry_count,'pending_count',pending,'utilization_percent',utilization::text,'place',place,'share_percent',coalesce(round(saved*100/nullif((select sum(saved)from g),0),2),0)::text,'bar_percent',coalesce(round(saved*100/nullif((select max(saved)from g),0),2),0)::text)order by saved desc,name)from r),'[]'),
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
 with f as materialized(select d.id,d.pcp_id,d.work_date,d.pcp_name_snapshot,d.m2_analyzed,d.m2_saved,w.m2_wasted,w.revision as waste_revision from public.pdi_pcp_daily d left join public.pdi_pcp_waste w on w.entry_id=d.id where d.work_date between p_start_date and p_end_date and(p_pcp_id is null or d.pcp_id=p_pcp_id))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id limit 30 offset p_offset)x),'[]'))into result;return result;end $function$;

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
 union all select 'pcp_m2','desperdicio',to_jsonb(x)from(select w.entry_id,d.pcp_id,d.work_date,d.pcp_name_snapshot,w.m2_wasted,w.revision,w.created_at,w.created_by,w.updated_at,w.updated_by from public.pdi_pcp_waste w join public.pdi_pcp_daily d on d.id=w.entry_id where p_module in('all','pcp_m2')and pdi_performance_private.can_view_module('pcp_m2')and(p_start is null or d.work_date between p_start and p_end)and(p_subject is null or d.pcp_id=p_subject))x
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

CREATE OR REPLACE FUNCTION public.pdi_performance_series(p_module text, p_start_date date, p_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
 declare result jsonb;begin
 if p_module<>'all'then perform pdi_access_private.assert_allowed(p_module,false);end if;

 if auth.uid() is null or not pdi_performance_private.can_view_module(p_module) then raise exception 'Indicadores restritos à gestão da área.' using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date) or not isfinite(p_end_date) or p_start_date>p_end_date or p_end_date-p_start_date>1095 then raise exception 'Selecione até 3 anos.' using errcode='22023';end if;
 if p_module='pcp_m2' then
 select jsonb_build_object('days',coalesce(jsonb_agg(jsonb_build_object('date',x.work_date,'value',x.total::text,'entries',x.entries)order by x.work_date),'[]'))into result from(select work_date,sum(m2_saved)total,count(*)entries from public.pdi_pcp_daily where work_date between p_start_date and p_end_date group by work_date)x;
 elsif p_module='cash_daily' then
 select jsonb_build_object('days',coalesce(jsonb_agg(jsonb_build_object('date',x.work_date,'value',x.total::text,'entries',x.entries)order by x.work_date),'[]'))into result from(select work_date,sum(result_cents)total,count(*)entries from public.pdi_cash_daily where work_date between p_start_date and p_end_date group by work_date)x;
 else raise exception 'Módulo sem indicadores configurados.' using errcode='22023';end if;
 perform pdi_performance_private.record_event(p_module,'dashboard','DASHBOARD_VIEW',null,null,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'source','pdi_performance_series'),null);
 return result;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_audit(p_month date, p_search text, p_offset integer, p_export boolean)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_audit(p_month,p_search,p_offset,p_export) where pdi_access_private.assert_allowed('sales_campaign',false) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_delete(p_id uuid, p_revision integer, p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_delete(p_id,p_revision,p_reason) where pdi_access_private.assert_allowed('sales_campaign',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_evaluation_settings(p_campaign uuid, p_revision integer, p_scope text, p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_evaluation_settings(p_campaign,p_revision,p_scope,p_reason) where pdi_access_private.assert_allowed('sales_campaign',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_export(p_campaign uuid, p_start date, p_end date, p_seller uuid)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_export(p_campaign,p_start,p_end,p_seller) where pdi_access_private.assert_allowed('sales_campaign',false) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_import(p_campaign uuid, p_campaign_revision integer, p_file_name text, p_file_hash text, p_rows jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_import(p_campaign,p_campaign_revision,p_file_name,p_file_hash,p_rows,p_reason) where pdi_access_private.assert_allowed('sales_campaign',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_rules(p_id uuid, p_name text, p_start date, p_end date, p_rules jsonb, p_revision integer, p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_rules(p_id,p_name,p_start,p_end,p_rules,p_revision,p_reason) where pdi_access_private.assert_allowed('sales_campaign',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_save(p_id uuid, p_campaign uuid, p_seller uuid, p_date date, p_data jsonb, p_revision integer, p_campaign_revision integer, p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_save(p_id,p_campaign,p_seller,p_date,p_data,p_revision,p_campaign_revision,p_reason) where pdi_access_private.assert_allowed('sales_campaign',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_sales_targets_save(p_campaign uuid, p_seller uuid, p_month date, p_targets bigint[], p_verified text[], p_revision integer, p_campaign_revision integer, p_reason text)
 RETURNS jsonb
 LANGUAGE sql
 SET search_path TO 'pg_catalog'
AS $function$ select pdi_performance_private.sales_targets_save(p_campaign,p_seller,p_month,p_targets,p_verified,p_revision,p_campaign_revision,p_reason) where pdi_access_private.assert_allowed('sales_campaign',true) $function$;

CREATE OR REPLACE FUNCTION public.pdi_stock_dashboard(p_start date, p_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 perform pdi_access_private.assert_allowed('stock',false);

 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock')or pdi_performance_private.stock_waste_supervisor())then raise exception 'Indicadores do Estoque restritos.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 then raise exception 'Período inválido.'using errcode='22023';end if;
 with f as materialized(select id,work_date,data from public.pdi_logistics_records where origin_module='stock'and kind='movement'and active and work_date between p_start and p_end),w as materialized(select(data->>'stock_entry')::uuid entry_id,(data->>'m2_wasted')::numeric waste,id,data->>'reason'reason from public.pdi_logistics_records where kind='stock_waste'and active),joined as(select f.*,w.waste,w.id waste_id,w.reason from f left join w on w.entry_id=f.id)
 select jsonb_build_object('m2',coalesce(sum((data->>'m2')::numeric),0)::text,'movements',count(*),'wasted_m2',sum(waste)::text,'pending',count(*)filter(where waste is null),'complete_m2',sum((data->>'m2')::numeric)filter(where waste is not null)::text,'efficiency',round((sum((data->>'m2')::numeric-waste)filter(where waste is not null))*100/nullif(sum((data->>'m2')::numeric)filter(where waste is not null),0),2)::text,'daily',coalesce((select jsonb_agg(to_jsonb(x)order by date)from(select work_date date,count(*)movements,sum((data->>'m2')::numeric)::text m2 from f group by work_date)x),'[]'),'top_days',coalesce((select jsonb_agg(to_jsonb(x)order by movements desc,m2::numeric desc,date)from(select work_date date,count(*)movements,sum((data->>'m2')::numeric)::text m2 from f group by work_date order by count(*)desc,sum((data->>'m2')::numeric)desc,work_date limit 10)x),'[]'),'waste_entries',coalesce((select jsonb_agg(jsonb_build_object('id',id,'entry_id',entry_id,'m2_wasted',waste::text,'reason',reason))from w where entry_id in(select id from f)),'[]'))into result from joined;return result;end$function$;

CREATE OR REPLACE FUNCTION public.pdi_stock_list(p_start date, p_end date, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 perform pdi_access_private.assert_allowed('stock',false);

 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock'))then raise exception 'Estoque restrito.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Período inválido, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,work_date,person_name_snapshot,vehicle_name_snapshot,plate_snapshot,data,created_at,created_by,updated_at,updated_by,revision,active from public.pdi_logistics_records where origin_module='stock'and kind='movement'and work_date between p_start and p_end)
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id limit 30 offset p_offset)x),'[]'))into result;return result;end$function$;

CREATE OR REPLACE FUNCTION public.pdi_stock_save(p_id uuid, p_vehicle uuid, p_m2 text, p_km text, p_notes text DEFAULT ''::text, p_day date DEFAULT NULL::date)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare k uuid;begin
 perform pdi_access_private.assert_allowed('stock',true);

 if not pdi_performance_private.stock_operator()then raise exception 'Registro de Estoque restrito ao Vitor autorizado.'using errcode='42501';end if;
 insert into public.pdi_logistics_records(id,kind,origin_module,work_date,vehicle_id,person_id,data)values(p_id,'movement','stock',coalesce(p_day,pdi_performance_private.today_manaus()),p_vehicle,null,jsonb_build_object('movement_type','internal','m2',p_m2,'km',p_km,'fee',false,'collected_cents',0,'spent_cents',0,'notes',p_notes))returning id into k;return k;end$function$;

CREATE OR REPLACE FUNCTION public.pdi_stock_waste_save(p_entry uuid, p_m2 text, p_reason text)
 RETURNS uuid
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$declare d record;k uuid;begin
 perform pdi_access_private.assert_allowed('stock',true);

 if not pdi_performance_private.stock_waste_supervisor()then raise exception 'Desperdício do Estoque restrito ao supervisor Jackson.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('stock_waste:'||p_entry::text,0));select id,work_date into d from public.pdi_logistics_records where id=p_entry and origin_module='stock'and kind='movement'and active;
 if d.id is null then raise exception 'Selecione uma movimentação ativa do Estoque.'using errcode='22023';end if;
 select id into k from public.pdi_logistics_records where kind='stock_waste'and active and data->>'stock_entry'=p_entry::text;
 if k is null then insert into public.pdi_logistics_records(kind,origin_module,work_date,data)values('stock_waste','stock',d.work_date,jsonb_build_object('stock_entry',p_entry,'m2_wasted',p_m2,'reason',p_reason))returning id into k;
 else update public.pdi_logistics_records set data=jsonb_build_object('stock_entry',p_entry,'m2_wasted',p_m2,'reason',p_reason),reason=p_reason where id=k;end if;return k;end$function$;

CREATE OR REPLACE FUNCTION public.pdi_cash_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
 declare people jsonb; manage boolean:=pdi_performance_private.can_view_module('cash_daily');correction boolean:=pdi_performance_private.can_correct_module('cash_daily');a public.profiles%rowtype;begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501';end if;
 select * into a from public.profiles where id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'sector',p.sector)order by p.full_name),'[]')into people from public.profiles p where (pdi_performance_private.is_cash_position(p.position)or pdi_access_private.mode('cash_daily',p.id)='collect') and(p.id=auth.uid() or manage);
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'can_manage',manage,'can_correct',correction,'can_collect',pdi_performance_private.can_collect_module('cash_daily'),'dashboard_only',manage and not correction,'can_view_logs',pdi_performance_private.can_audit_module('cash_daily'),'global_access',pdi_performance_private.is_indicator_admin(),'cashiers',people,'position',a.position,'is_pcp',lower(btrim(coalesce(a.position,'')))='pcp','is_cashier',pdi_performance_private.is_cash_position(a.position)or coalesce(pdi_access_private.mode('cash_daily')='collect',false));end $function$;

CREATE OR REPLACE FUNCTION public.pdi_desempenho_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$
 declare people jsonb; manage boolean:=pdi_performance_private.can_view_module('pcp_m2');correction boolean:=pdi_performance_private.can_correct_module('pcp_m2');a public.profiles%rowtype;begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501';end if;
 select * into a from public.profiles where id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'sector',p.sector)order by p.full_name),'[]')into people from public.profiles p where (lower(btrim(coalesce(p.position,'')))='pcp'or pdi_access_private.mode('pcp_m2',p.id)='collect') and(p.id=auth.uid() or manage);
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'can_manage',manage,'can_correct',correction,'can_collect',pdi_performance_private.can_collect_module('pcp_m2'),'dashboard_only',manage and not correction,'can_view_logs',pdi_performance_private.can_audit_module('pcp_m2'),'global_access',pdi_performance_private.is_indicator_admin(),'pcps',people,'position',a.position,'is_pcp',lower(btrim(coalesce(a.position,'')))='pcp'or coalesce(pdi_access_private.mode('pcp_m2')='collect',false),'is_cashier',pdi_performance_private.is_cash_position(a.position));end $function$;
