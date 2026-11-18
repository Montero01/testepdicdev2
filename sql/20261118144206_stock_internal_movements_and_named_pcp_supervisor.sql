begin;
create or replace function pdi_performance_private.logistics_register()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select pdi_performance_private.is_indicator_admin()or coalesce(pdi_performance_private.module_level('logistics')='manager',false)or coalesce(pdi_performance_private.module_level('pcp_m2')='manager',false)$$;
alter policy log_people_read on public.pdi_logistics_people using(pdi_performance_private.logistics_read()or pdi_performance_private.logistics_register());
alter policy log_vehicle_read on public.pdi_logistics_vehicles using(pdi_performance_private.logistics_read()or pdi_performance_private.logistics_register());
CREATE OR REPLACE FUNCTION public.pdi_logistics_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$begin
 if not(pdi_performance_private.logistics_read()or pdi_performance_private.logistics_register())then raise exception 'Acesso restrito à Logística autorizada.'using errcode='42501';end if;
 return jsonb_build_object('catalog_only',not pdi_performance_private.logistics_read(),'today',pdi_performance_private.today_manaus(),'can_dashboard',pdi_performance_private.can_view_module('logistics'),'can_create',pdi_performance_private.can_operate_module('logistics'),'can_correct',pdi_performance_private.can_correct_module('logistics'),'can_register',pdi_performance_private.logistics_register(),'can_view_logs',pdi_performance_private.can_audit_module('logistics'),
 'people',(select coalesce(jsonb_agg(to_jsonb(p)order by full_name),'[]')from(select id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_people)p),
 'vehicles',(select coalesce(jsonb_agg(to_jsonb(v)order by name),'[]')from(select id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_vehicles)v));end $function$
;
CREATE OR REPLACE FUNCTION public.pdi_module_access_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ declare result jsonb;begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('module_key',m.module_key,'area_key',m.area_key,'label',m.label,'page_key',m.page_key,'area_label',a.label,
 'can_register',case when m.module_key='logistics'then pdi_performance_private.logistics_register()else false end,'can_view',pdi_performance_private.can_view_module(m.module_key),'can_correct',pdi_performance_private.can_correct_module(m.module_key),'can_collect',pdi_performance_private.can_collect_module(m.module_key),'level',pdi_performance_private.module_level(m.module_key)) order by m.module_key),'[]')into result from public.pdi_indicator_modules m join public.pdi_indicator_areas a on a.area_key=m.area_key where m.enabled and a.active;
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'is_admin',pdi_performance_private.is_indicator_admin(),'modules',result,'memberships',(select coalesce(jsonb_agg(jsonb_build_object('area_key',m.area_key,'area_label',a.label,'access_level',m.access_level)),'[]')from public.pdi_area_memberships m join public.pdi_indicator_areas a on a.area_key=m.area_key where m.profile_id=auth.uid()));end $function$
;


CREATE OR REPLACE FUNCTION pdi_performance_private.can_correct_module(p_module text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ select(p_module<>'pcp_m2'or auth.uid()='a9df7b33-c304-4d05-a3d4-b7bd44383d67'::uuid)and p_module<>'cash_daily' and coalesce(pdi_performance_private.module_level(p_module)='supervisor',false) and not pdi_performance_private.is_indicator_admin()
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('employee','colaborador','supervisor')) $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.can_record_pcp_waste()
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ select not pdi_performance_private.is_indicator_admin() and (coalesce(pdi_performance_private.module_level('pcp_m2')='manager',false)or pdi_performance_private.can_correct_module('pcp_m2')) $function$
;

alter table public.pdi_logistics_records add column origin_module text not null default 'logistics'check(origin_module in('logistics','stock'));
grant select(origin_module)on public.pdi_logistics_records to authenticated;
insert into public.pdi_indicator_areas(area_key,label)values('estoque','Estoque');
insert into public.pdi_indicator_modules(module_key,area_key,label,page_key,collector_rule,enabled)values('stock','estoque','Estoque · movimentações internas','stock','none',true);
create or replace function pdi_performance_private.stock_operator()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select auth.uid()='5635f102-f21e-41c8-a046-4f70dc005216'::uuid and exists(select 1 from public.profiles where id=auth.uid()and role in('employee','colaborador'))and exists(select 1 from public.pdi_indicator_modules m join public.pdi_indicator_areas a using(area_key)where module_key='stock'and enabled and a.active)$$;
revoke all on function pdi_performance_private.stock_operator()from public,anon;grant execute on function pdi_performance_private.stock_operator()to authenticated;
alter policy log_vehicle_read on public.pdi_logistics_vehicles using(pdi_performance_private.logistics_read()or pdi_performance_private.logistics_register()or pdi_performance_private.stock_operator());
alter policy log_record_read on public.pdi_logistics_records using(pdi_performance_private.logistics_read()or(origin_module='stock'and created_by=(select auth.uid())and pdi_performance_private.stock_operator()));
alter policy log_record_insert on public.pdi_logistics_records with check(pdi_performance_private.can_operate_module('logistics')or(origin_module='stock'and pdi_performance_private.stock_operator()));
create or replace function public.pdi_stock_context()returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$begin
 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock'))then raise exception 'Estoque restrito ao colaborador autorizado.'using errcode='42501';end if;
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'can_create',pdi_performance_private.stock_operator(),'name',(select full_name from public.profiles where id=auth.uid()),'vehicles',(select coalesce(jsonb_agg(to_jsonb(v)order by name),'[]')from(select id,name,plate,model from public.pdi_logistics_vehicles where active)v));end$$;
create or replace function public.pdi_stock_list(p_start date,p_end date,p_offset int default 0)returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$declare result jsonb;begin
 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock'))then raise exception 'Estoque restrito.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Período inválido, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,work_date,person_name_snapshot,vehicle_name_snapshot,plate_snapshot,data,created_at,created_by,updated_at,updated_by,revision,active from public.pdi_logistics_records where origin_module='stock'and work_date between p_start and p_end)
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id limit 30 offset p_offset)x),'[]'))into result;return result;end$$;
create or replace function public.pdi_stock_save(p_id uuid,p_vehicle uuid,p_m2 text,p_km text,p_notes text default '')returns uuid language plpgsql security invoker set search_path=pg_catalog as $$declare k uuid;begin
 if not pdi_performance_private.stock_operator()then raise exception 'Registro de Estoque restrito ao Vitor autorizado.'using errcode='42501';end if;
 insert into public.pdi_logistics_records(id,kind,origin_module,work_date,vehicle_id,person_id,data)values(p_id,'movement','stock',pdi_performance_private.today_manaus(),p_vehicle,null,jsonb_build_object('movement_type','internal','m2',p_m2,'km',p_km,'fee',false,'collected_cents',0,'spent_cents',0,'notes',p_notes))returning id into k;return k;end$$;
revoke all on function public.pdi_stock_context(),public.pdi_stock_list(date,date,int),public.pdi_stock_save(uuid,uuid,text,text,text)from public,anon;
grant execute on function public.pdi_stock_context(),public.pdi_stock_list(date,date,int),public.pdi_stock_save(uuid,uuid,text,text,text)to authenticated;

CREATE OR REPLACE FUNCTION public.pdi_logistics_list(p_kind text, p_start date, p_end date, p_vehicle uuid DEFAULT NULL::uuid, p_person uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_cancelled boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 if not pdi_performance_private.logistics_read()then raise exception 'Acesso restrito à Logística.'using errcode='42501';end if;
 if p_kind not in('movement','replacement','attendance','maintenance','schedule','fuel')or p_kind is null or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Selecione processo e período válidos, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,kind,origin_module,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where kind=p_kind and(kind<>'attendance'or exists(select 1 from public.pdi_logistics_people p where p.id=person_id and p.kind in('driver','helper')))and work_date between p_start and p_end and(p_cancelled or active)and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule')))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $function$
;
CREATE OR REPLACE FUNCTION public.pdi_performance_export(p_module text DEFAULT 'all'::text, p_start date DEFAULT NULL::date, p_end date DEFAULT NULL::date, p_subject uuid DEFAULT NULL::uuid, p_vehicle uuid DEFAULT NULL::uuid, p_kind text DEFAULT NULL::text, p_cancelled boolean DEFAULT true)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare result jsonb;events jsonb:='[]';m text;k uuid;c int;begin
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
 return jsonb_build_object('rows',result,'count',jsonb_array_length(result),'events',events,'generated_at',statement_timestamp());end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.can_collect_module(p_module text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ select case when p_module='stock'then pdi_performance_private.stock_operator()else auth.uid() is not null and not pdi_performance_private.is_indicator_admin()
 and coalesce(pdi_performance_private.module_level(p_module),'')<>'manager' and exists(
 select 1 from public.profiles p join public.pdi_indicator_modules m on m.module_key=p_module join public.pdi_indicator_areas r on r.area_key=m.area_key
 where p.id=auth.uid() and p.role in('employee','colaborador','supervisor') and (p.role<>'supervisor' or pdi_performance_private.can_correct_module(p_module)) and m.enabled and r.active
 and case m.collector_rule when 'pcp' then lower(btrim(coalesce(p.position,'')))='pcp' when 'cash' then pdi_performance_private.is_cash_position(p.position) when 'logistics' then translate(lower(coalesce(p.position,'')),'í','i')like'%logistica%' else false end) end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_logistics_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare j jsonb:=new.data;v public.pdi_logistics_vehicles%rowtype;p public.pdi_logistics_people%rowtype;keys text[];n numeric;x numeric;expected int;worked int;pause int:=0;seq int[];a int;b int;prev int;offset_day int:=0;start_min int;end_min int;end_day date;begin
 if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 if tg_op='INSERT'then if not(pdi_performance_private.can_operate_module('logistics')or(new.origin_module='stock'and pdi_performance_private.stock_operator()))then raise exception 'Coleta restrita à Logística e supervisão autorizada.'using errcode='42501';end if;new.created_by:=auth.uid();new.created_at:=clock_timestamp();new.revision:=1;new.active:=true;
 else
 if not pdi_performance_private.can_correct_module('logistics')then raise exception 'Ajustes operacionais restritos à supervisão de Logística.'using errcode='42501';end if;
 if row(new.id,new.kind,new.created_at,new.created_by)is distinct from row(old.id,old.kind,old.created_at,old.created_by)then raise exception 'Origem e tipo do registro não podem mudar.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))<10 or length(new.reason)>300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;new.revision:=old.revision+1;end if;
 if tg_op='UPDATE'and new.origin_module is distinct from old.origin_module then raise exception 'A origem do registro não pode mudar.'using errcode='22023';end if;
 if new.origin_module='stock'then
 if tg_op='INSERT'and not pdi_performance_private.stock_operator()then raise exception 'Origem Estoque restrita ao Vitor autorizado.'using errcode='42501';end if;
 if new.kind<>'movement'or new.person_id is not null or coalesce(j->>'movement_type','')<>'internal'or j->>'fee'is distinct from'false'or coalesce(j->>'collected_cents','')<>'0'or coalesce(j->>'spent_cents','')<>'0'or(tg_op='INSERT'and new.work_date<>pdi_performance_private.today_manaus())then raise exception 'Estoque registra somente movimentação interna do dia, sem taxa ou valores financeiros.'using errcode='22023';end if;end if;
 if new.work_date is null or not isfinite(new.work_date)or(new.kind<>'schedule'and new.work_date>pdi_performance_private.today_manaus())then raise exception 'Data inválida para registro realizado.'using errcode='22023';end if;
 if jsonb_typeof(j)is distinct from'object'or length(coalesce(j->>'notes',''))>1000 then raise exception 'Dados ou observação inválidos.'using errcode='22023';end if;
 if new.kind<>'attendance'then
 select id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by,null::text into v from public.pdi_logistics_vehicles where id=new.vehicle_id;
 if v.id is null or(not v.active and(tg_op='INSERT'or new.vehicle_id is distinct from old.vehicle_id))then raise exception 'Selecione um veículo ativo.'using errcode='22023';end if;
 else if new.vehicle_id is not null then raise exception 'Jornada não utiliza veículo.'using errcode='22023';end if;end if;
 if new.kind in('movement','replacement','attendance','fuel')and new.origin_module<>'stock'then
 select id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by,null::text into p from public.pdi_logistics_people where id=new.person_id;
 if p.id is null or(not p.active and(tg_op='INSERT'or new.person_id is distinct from old.person_id))then raise exception 'Selecione um colaborador ativo.'using errcode='22023';end if;
 if new.kind in('movement','replacement')and p.kind not in('driver','other')and(tg_op='INSERT'or new.person_id is distinct from old.person_id)then raise exception 'Selecione um motorista ou colaborador de outro setor.'using errcode='22023';end if;
 if new.kind='attendance'and p.kind not in('driver','helper')and(tg_op='INSERT'or new.person_id is distinct from old.person_id)then raise exception 'Controle de ponto exclusivo de motoristas e ajudantes da Logística.'using errcode='22023';end if;
 elsif new.person_id is not null then raise exception 'Este registro não utiliza colaborador.'using errcode='22023';end if;
 case new.kind
 when'movement'then keys:=array['movement_type','m2','km','fee','collected_cents','spent_cents','notes'];
 when'replacement'then keys:=array['sector','other_reason','m2','km','notes'];
 when'attendance'then keys:=array['entry','lunch_out','lunch_in','exit','notes','expected_minutes','worked_minutes','balance_minutes','next_day'];
 when'maintenance'then keys:=array['maintenance_type','service','cost_cents','end_date','notes'];
 when'schedule'then keys:=array['maintenance_type','estimated_cents','status','service','notes'];
 when'fuel'then keys:=array['liters','cost_cents','notes'];
 else raise exception 'Tipo de registro inválido.'using errcode='22023';end case;
 if exists(select 1 from jsonb_object_keys(j)k where not(k=any(keys)))then raise exception 'Campo não permitido para este processo.'using errcode='22023';end if;
 if new.kind in('movement','replacement')then
 n:=pdi_performance_private.log_number(j,'m2',0,999999999.999,3);x:=pdi_performance_private.log_number(j,'km',0,999999999.999,3);j:=j||jsonb_build_object('m2',n,'km',x);
 if new.kind='movement'then
 if coalesce(j->>'movement_type','')not in('internal','external')or jsonb_typeof(j->'fee')is distinct from'boolean'then raise exception 'Informe tipo de movimentação e se há taxa.'using errcode='22023';end if;
 n:=pdi_performance_private.log_number(j,'collected_cents',0,99999999999,0);x:=pdi_performance_private.log_number(j,'spent_cents',0,99999999999,0);
 if not(j->>'fee')::boolean and n<>0 then raise exception 'Sem taxa, o arrecadado deve ser zero.'using errcode='22023';end if;j:=j||jsonb_build_object('collected_cents',n,'spent_cents',x);
 else
 if coalesce(j->>'sector','')not in('comercial','producao','transporte','almoxarifado','outros')or length(coalesce(j->>'other_reason',''))>150 or(j->>'sector'='outros'and length(btrim(coalesce(j->>'other_reason','')))<3)then raise exception 'Informe o setor; para Outros, detalhe em até 150 caracteres.'using errcode='22023';end if;
 end if;
 elsif new.kind='attendance'then
 a:=pdi_performance_private.log_number(j,'entry',0,1439,0)::int;b:=pdi_performance_private.log_number(j,'exit',0,1439,0)::int;
 if(j->>'lunch_out'is null)is distinct from(j->>'lunch_in'is null)then raise exception 'Preencha os dois horários de almoço ou nenhum.'using errcode='22023';end if;
 if j->>'lunch_out'is null then seq:=array[a,b];else seq:=array[a,pdi_performance_private.log_number(j,'lunch_out',0,1439,0)::int,pdi_performance_private.log_number(j,'lunch_in',0,1439,0)::int,b];end if;
 prev:=a;start_min:=a;for a in 2..cardinality(seq)loop
 n:=seq[a]+offset_day*1440;if n<prev then offset_day:=offset_day+1;n:=seq[a]+offset_day*1440;end if;
 if offset_day>1 or n-start_min>1440 then raise exception 'Horários fora de ordem ou jornada superior a 24 horas.'using errcode='22023';end if;
 if cardinality(seq)=4 and a=3 then pause:=n-prev;end if;prev:=n::int;end loop;end_min:=prev;worked:=end_min-start_min-pause;
 if tg_op='UPDATE'and new.person_id=old.person_id then expected:=(old.data->>'expected_minutes')::int;else expected:=p.expected_minutes;end if;
 j:=jsonb_build_object('entry',seq[1],'lunch_out',case when cardinality(seq)=4 then seq[2]else null end,'lunch_in',case when cardinality(seq)=4 then seq[3]else null end,'exit',seq[cardinality(seq)],'expected_minutes',expected,'worked_minutes',worked,'balance_minutes',worked-expected,'next_day',offset_day=1,'notes',coalesce(j->>'notes',''));
 elsif new.kind in('maintenance','schedule')then
 if coalesce(j->>'maintenance_type','')not in('corrective','preventive')or length(coalesce(j->>'service',''))>500 then raise exception 'Informe o tipo e um serviço de até 500 caracteres.'using errcode='22023';end if;
 if new.kind='maintenance'then
 if length(btrim(coalesce(j->>'service','')))=0 then raise exception 'Informe o serviço realizado.'using errcode='22023';end if;
 n:=pdi_performance_private.log_number(j,'cost_cents',0,99999999999,0);j:=j||jsonb_build_object('cost_cents',n);
 if nullif(j->>'end_date','')is not null then begin end_day:=(j->>'end_date')::date;exception when invalid_datetime_format or datetime_field_overflow then raise exception 'Data final inválida.'using errcode='22023';end;
 if not isfinite(end_day)or end_day<new.work_date or end_day>pdi_performance_private.today_manaus()then raise exception 'A data final deve ser entre o início e hoje.'using errcode='22023';end if;end if;j:=j||jsonb_build_object('end_date',end_day);
 else n:=pdi_performance_private.log_number(j,'estimated_cents',0,99999999999,0);if coalesce(j->>'status','')not in('planned','completed')or(j->>'status'='completed'and new.work_date>pdi_performance_private.today_manaus())then raise exception 'Informe a situação do cronograma.'using errcode='22023';end if;j:=j||jsonb_build_object('estimated_cents',n);end if;
 elsif new.kind='fuel'then n:=pdi_performance_private.log_number(j,'liters',0.001,999999.999,3);x:=pdi_performance_private.log_number(j,'cost_cents',0,99999999999,0);j:=j||jsonb_build_object('liters',n,'cost_cents',x);
 end if;
 new.data:=j||jsonb_build_object('notes',coalesce(j->>'notes',''));
 if tg_op='INSERT'or new.vehicle_id is distinct from old.vehicle_id then new.vehicle_name_snapshot:=v.name;new.plate_snapshot:=v.plate;else new.vehicle_name_snapshot:=old.vehicle_name_snapshot;new.plate_snapshot:=old.plate_snapshot;end if;
 if tg_op='INSERT'or new.person_id is distinct from old.person_id then new.person_name_snapshot:=case when new.origin_module='stock'then(select full_name from public.profiles where id=auth.uid())else p.full_name end;else new.person_name_snapshot:=old.person_name_snapshot;end if;
 if tg_op='UPDATE'and row(new.work_date,new.vehicle_id,new.person_id,new.data,new.active)is not distinct from row(old.work_date,old.vehicle_id,old.person_id,old.data,old.active)then raise exception 'Não há alteração no registro.'using errcode='22023';end if;
 if tg_op='INSERT'then new.reason:=null;end if;new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $function$
;
notify pgrst,'reload schema';commit;