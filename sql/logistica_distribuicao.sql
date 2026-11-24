-- Aplicado: distribuição filtrada por categoria, sem coleta de custo de reposição.
-- Amplia somente o JSON do dashboard atual; não altera tabelas nem coleta monetária.
-- Uma movimentação é uma ocorrência operacional, não um pedido distinto comprovado.
-- Reposições não têm R$: o contrato retorna NULL e informa indisponibilidade.
-- Mantém SECURITY INVOKER, search_path restrito, assert_allowed, can_view_module e o log existente.
-- As novas distribuições reutilizam as CTEs filtradas por data, veículo e colaborador.
-- Todos os registros excluídos são desconsiderados explicitamente; RLS permanece em vigor.
BEGIN;
CREATE OR REPLACE FUNCTION public.pdi_logistics_dashboard(p_start date, p_end date, p_vehicle uuid DEFAULT NULL::uuid, p_person uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY INVOKER
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 perform pdi_access_private.assert_allowed('logistics',false);

 if not pdi_performance_private.can_view_module('logistics')then raise exception 'Indicadores restritos à supervisão e gestão de Logística.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 then raise exception 'Período inválido (até 3 anos).'using errcode='22023';end if;
 with f as materialized(select id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where active and not is_deleted and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper')))and work_date between p_start and p_end and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule'))),
 movement as(select *from f where kind='movement'),replacements as(select *from f where kind='replacement'),attendance as(select *from f where kind='attendance'),maintenance as(select *from f where kind='maintenance'),schedule as(select *from f where kind='schedule'),fuel as(select *from f where kind='fuel')
 select jsonb_build_object(
 'movement',jsonb_build_object('count',(select count(*)from movement),'m2',(select case when count(*)=count(data->>'m2')then coalesce(sum((data->>'m2')::numeric),0)::text else null end from movement),'m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from movement),'km',(select coalesce(sum((data->>'km')::numeric),0)::text from movement),'collected_cents',(select coalesce(sum((data->>'collected_cents')::bigint),0)::text from movement),'spent_cents',(select coalesce(sum((data->>'spent_cents')::bigint),0)::text from movement),'fee_count',(select count(*)from movement where(data->>'fee')::boolean)),
 'replacement',jsonb_build_object('count',(select count(*)from replacements),'m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from replacements),'km',(select coalesce(sum((data->>'km')::numeric),0)::text from replacements)),
 'attendance',jsonb_build_object('count',(select count(*)from attendance),'people',(select count(distinct person_id)from attendance),'worked_minutes',(select coalesce(sum((data->>'worked_minutes')::int),0)::text from attendance),'expected_minutes',(select coalesce(sum((data->>'expected_minutes')::int),0)::text from attendance),'balance_minutes',(select coalesce(sum((data->>'balance_minutes')::int),0)::text from attendance)),
 'maintenance',jsonb_build_object('count',(select count(*)from maintenance),'cost_cents',(select coalesce(sum((data->>'cost_cents')::bigint),0)::text from maintenance)),
 'schedule',jsonb_build_object('count',(select count(*)from schedule),'estimated_cents',(select coalesce(sum((data->>'estimated_cents')::bigint),0)::text from schedule)),
 'fuel',jsonb_build_object('count',(select count(*)from fuel),'liters',(select coalesce(sum((data->>'liters')::numeric),0)::text from fuel),'cost_cents',(select coalesce(sum((data->>'cost_cents')::bigint),0)::text from fuel),'price_per_liter',(select round(sum((data->>'cost_cents')::numeric)/nullif(sum((data->>'liters')::numeric),0)/100,2)::text from fuel)),
 'alerts',jsonb_build_object('open_maintenance',(select count(*)from public.pdi_logistics_records where kind='maintenance'and active and not is_deleted and nullif(data->>'end_date','')is null and(p_vehicle is null or vehicle_id=p_vehicle)),'overdue_schedule',(select count(*)from public.pdi_logistics_records where kind='schedule'and active and not is_deleted and data->>'status'='planned'and work_date<pdi_performance_private.today_manaus()and(p_vehicle is null or vehicle_id=p_vehicle))),
 'vehicle_movement',coalesce((select jsonb_agg(jsonb_build_object('id',vehicle_id,'label',name,'value',total::text,'km',km::text,'entries',entries)order by total desc)from(select vehicle_id,max(vehicle_name_snapshot)name,sum((data->>'m2')::numeric)total,sum((data->>'km')::numeric)km,count(*)entries from movement group by vehicle_id)x),'[]'),
 'replacement_sectors',coalesce((select jsonb_agg(jsonb_build_object('label',sector,'value',count)order by count desc)from(select data->>'sector'sector,count(*)from replacements group by data->>'sector')x),'[]'),
 'attendance_people',coalesce((select jsonb_agg(jsonb_build_object('id',person_id,'label',name,'worked',worked::text,'expected',expected::text,'value',balance::text)order by balance desc)from(select person_id,max(person_name_snapshot)name,sum((data->>'worked_minutes')::int)worked,sum((data->>'expected_minutes')::int)expected,sum((data->>'balance_minutes')::int)balance from attendance group by person_id)x),'[]'),
 'maintenance_types',coalesce((select jsonb_agg(jsonb_build_object('label',type,'value',total::text))from(select data->>'maintenance_type'type,sum((data->>'cost_cents')::bigint)total from maintenance group by data->>'maintenance_type')x),'[]'),
 'schedule_dates',coalesce((select jsonb_agg(jsonb_build_object('label',work_date,'value',total::text)order by work_date)from(select work_date,sum((data->>'estimated_cents')::bigint)total from schedule group by work_date)x),'[]'),
 'fuel_vehicles',coalesce((select jsonb_agg(jsonb_build_object('id',vehicle_id,'label',name,'value',total::text)order by total desc)from(select vehicle_id,max(vehicle_name_snapshot)name,sum((data->>'cost_cents')::bigint)total from fuel group by vehicle_id)x),'[]'),
 'category_distribution',jsonb_build_object(
  'version',1,
  'quantity_basis','one_active_operational_record_is_one_occurrence_not_distinct_orders',
  'movement_types',coalesce((select jsonb_agg(jsonb_build_object(
    'key',category,'label',label,'count',entries,'m2',case when area_known=entries then area::text else null end,
    'collected_cents',case when collected_known=entries then collected::text else null end,
    'spent_cents',case when spent_known=entries then spent::text else null end)
    order by sort_order) from (
     select t.category,t.label,t.sort_order,count(m.id) entries,
      count(m.data->>'m2') area_known,coalesce(sum((m.data->>'m2')::numeric),0)area,count(m.data->>'collected_cents') collected_known,count(m.data->>'spent_cents') spent_known,
      coalesce(sum((m.data->>'collected_cents')::bigint),0) collected,
      coalesce(sum((m.data->>'spent_cents')::bigint),0) spent
     from(values('internal','Movimentações internas',1),('external','Movimentações externas',2),('unknown','Tipo não informado',3))t(category,label,sort_order)
     left join movement m on(case when m.data->>'movement_type' in('internal','external')then m.data->>'movement_type'else'unknown'end)=t.category
     group by t.category,t.label,t.sort_order
    )g where category<>'unknown'or entries>0),'[]'::jsonb),
  'activity_types',jsonb_build_array(
    jsonb_build_object('key','movement','label','Movimentações / pedidos registrados (ocorrências)',
      'count',(select count(*)from movement),'m2',(select case when count(*)=count(data->>'m2')then coalesce(sum((data->>'m2')::numeric),0)::text else null end from movement),
      'collected_cents',(select case when count(*)=count(data->>'collected_cents')then coalesce(sum((data->>'collected_cents')::bigint),0)::text else null end from movement),
      'spent_cents',(select case when count(*)=count(data->>'spent_cents')then coalesce(sum((data->>'spent_cents')::bigint),0)::text else null end from movement),
      'financial_values_available',true),
    jsonb_build_object('key','replacement','label','Reposições (ocorrências)',
      'count',(select count(*)from replacements),'m2',(select case when count(*)=count(data->>'m2')then coalesce(sum((data->>'m2')::numeric),0)::text else null end from replacements),'collected_cents',null,'spent_cents',null,
      'financial_values_available',false)),
  'replacement_value_available',false,
  'replacement_value_reason','O cadastro de reposições não possui valor monetário. Não é possível comparar movimentações e reposições em reais.',
  'movement_money_basis','collected_cents and spent_cents are operational amounts, not sales/order values'),
 'daily',coalesce((select jsonb_agg(jsonb_build_object('label',work_date,'value',total::text)order by work_date)from(select work_date,sum((data->>'m2')::numeric)total from movement group by work_date)x),'[]'))into result;
 perform pdi_performance_private.record_event('logistics','dashboard','DASHBOARD_VIEW',p_person,null,jsonb_build_object('start_date',p_start,'end_date',p_end,'vehicle_id',p_vehicle),null);return result;end $function$;

REVOKE ALL ON FUNCTION public.pdi_logistics_dashboard(date,date,uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pdi_logistics_dashboard(date,date,uuid,uuid) TO authenticated;
COMMIT;
