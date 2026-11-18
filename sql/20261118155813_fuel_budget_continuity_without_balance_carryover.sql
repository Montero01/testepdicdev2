begin;
CREATE OR REPLACE FUNCTION pdi_performance_private.fuel_month(p_month date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 if auth.uid()is null or not(pdi_performance_private.logistics_read()or pdi_performance_private.performance_manager())then raise exception 'Abastecimento restrito à Logística e gestão.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_month<>date_trunc('month',p_month)::date then raise exception 'Mês inválido.'using errcode='22023';end if;
 with f as materialized(select kind,id,vehicle_id,vehicle_name_snapshot,data from public.pdi_logistics_records where active and not is_deleted and work_date>=p_month and work_date<(p_month+interval'1 month')::date),b as(select(data->>'budget_cents')::numeric amount,id,work_date source_month from public.pdi_logistics_records where kind='fuel_budget'and active and not is_deleted and work_date<=p_month order by work_date desc limit 1),fuel as(select *from f where kind='fuel'),ex as(select *from f where kind='movement'and data->>'movement_type'='external')
 select jsonb_build_object('month',p_month,'budget_id',(select id from b where source_month=p_month),'budget_source_month',(select source_month from b),'budget_inherited',(select source_month<p_month from b),'budget_cents',(select amount::text from b),'spent_cents',(select coalesce(sum((data->>'cost_cents')::numeric),0)::text from fuel),'balance_cents',(select(amount-(select coalesce(sum((data->>'cost_cents')::numeric),0)from fuel))::text from b),'used_percent',(select round((select coalesce(sum((data->>'cost_cents')::numeric),0)from fuel)*100/nullif(amount,0),2)::text from b),'liters',(select coalesce(sum((data->>'liters')::numeric),0)::text from fuel),'external_count',(select count(*)from ex),'external_m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from ex),'external_km',(select coalesce(sum((data->>'km')::numeric),0)::text from ex),'external_vehicles',coalesce((select jsonb_agg(to_jsonb(v)order by m2::numeric desc)from(select vehicle_id,max(vehicle_name_snapshot)name,count(*)deliveries,sum((data->>'m2')::numeric)::text m2,sum((data->>'km')::numeric)::text km from ex group by vehicle_id)v),'[]'))into result;
 result:=result||jsonb_build_object('month_days',extract(day from(p_month+interval'1 month'-interval'1 day'))::int,'elapsed_days',greatest(0,least(extract(day from(p_month+interval'1 month'-interval'1 day'))::int,pdi_performance_private.today_manaus()-p_month+1)));
 result:=result||jsonb_build_object('available_percent',round((result->>'balance_cents')::numeric*100/nullif((result->>'budget_cents')::numeric,0),2)::text,'daily_average_cents',round((result->>'spent_cents')::numeric/nullif((result->>'elapsed_days')::int,0),0)::text,'projected_spent_cents',round((result->>'spent_cents')::numeric*(result->>'month_days')::int/nullif((result->>'elapsed_days')::int,0),0)::text);
 result:=result||jsonb_build_object('projected_balance_cents',((result->>'budget_cents')::numeric-(result->>'projected_spent_cents')::numeric)::text);
 return result;end$function$
;
notify pgrst,'reload schema';commit;
