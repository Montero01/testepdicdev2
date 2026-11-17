begin;
alter table public.pdi_indicator_modules drop constraint pdi_indicator_modules_collector_rule_check;
alter table public.pdi_indicator_modules add constraint pdi_indicator_modules_collector_rule_check check(collector_rule in('pcp','cash','logistics','none'));
alter table public.pdi_audit_exports drop constraint pdi_audit_exports_module_key_check;
alter table public.pdi_audit_exports add constraint pdi_audit_exports_module_key_check check(module_key in('pcp_m2','cash_daily','logistics'));
insert into public.pdi_indicator_areas(area_key,label)values('logistica','Logística');
insert into public.pdi_indicator_modules(module_key,area_key,label,page_key,collector_rule,enabled)values('logistics','logistica','Logística','logistics','logistics',true);
create or replace function pdi_performance_private.logistics_read()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select pdi_performance_private.can_view_module('logistics')or pdi_performance_private.can_collect_module('logistics')$$;
create or replace function pdi_performance_private.logistics_register()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select pdi_performance_private.is_indicator_admin()or coalesce(pdi_performance_private.module_level('logistics')='manager',false)$$;
revoke all on function pdi_performance_private.logistics_read(),pdi_performance_private.logistics_register()from public,anon;grant execute on function pdi_performance_private.logistics_read(),pdi_performance_private.logistics_register()to authenticated;
create table public.pdi_logistics_people(id uuid primary key default gen_random_uuid(),full_name text not null check(length(btrim(full_name))between 2 and 120),kind text not null check(kind in('driver','helper','other')),profile_id uuid unique references public.profiles(id)on delete restrict,expected_minutes int not null default 480 check(expected_minutes between 0 and 1440),active boolean not null default true,notes text not null default ''check(length(notes)<=1000),revision int not null default 1,created_at timestamptz not null default now(),created_by uuid,updated_at timestamptz not null default now(),updated_by uuid,reason text);
create table public.pdi_logistics_vehicles(id uuid primary key default gen_random_uuid(),name text not null check(length(btrim(name))between 2 and 100),plate text not null unique check(plate~'^[A-Z]{3}([0-9]{4}|[0-9][A-Z][0-9]{2})$'),model text not null check(length(btrim(model))between 1 and 100),brand text not null default ''check(length(brand)<=80),model_year int check(model_year between 1900 and 2200),acquired_on date,active boolean not null default true,notes text not null default ''check(length(notes)<=1000),revision int not null default 1,created_at timestamptz not null default now(),created_by uuid,updated_at timestamptz not null default now(),updated_by uuid,reason text);
create table public.pdi_logistics_records(id uuid primary key default gen_random_uuid(),kind text not null check(kind in('movement','replacement','attendance','maintenance','schedule','fuel')),work_date date not null,vehicle_id uuid references public.pdi_logistics_vehicles(id)on delete restrict,person_id uuid references public.pdi_logistics_people(id)on delete restrict,data jsonb not null,vehicle_name_snapshot text,plate_snapshot text,person_name_snapshot text,active boolean not null default true,revision int not null default 1,created_at timestamptz not null default now(),created_by uuid,updated_at timestamptz not null default now(),updated_by uuid,reason text);
create index pdi_log_records_kind_date_idx on public.pdi_logistics_records(kind,work_date desc,id);
create index pdi_log_records_vehicle_idx on public.pdi_logistics_records(vehicle_id,work_date);
create index pdi_log_records_person_idx on public.pdi_logistics_records(person_id,work_date);
create unique index pdi_log_attendance_day_unique on public.pdi_logistics_records(person_id,work_date)where kind='attendance'and active;
-- Só a equipe autorizada vê os dados operacionais. Cadastros não criam contas Auth.
alter table public.pdi_logistics_people enable row level security;alter table public.pdi_logistics_vehicles enable row level security;alter table public.pdi_logistics_records enable row level security;
revoke all on public.pdi_logistics_people,public.pdi_logistics_vehicles,public.pdi_logistics_records from public,anon,authenticated;
grant insert,update on public.pdi_logistics_people,public.pdi_logistics_vehicles,public.pdi_logistics_records to authenticated;
grant select(id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by)on public.pdi_logistics_people to authenticated;
grant select(id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by)on public.pdi_logistics_vehicles to authenticated;
grant select(id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by)on public.pdi_logistics_records to authenticated;
create policy log_people_read on public.pdi_logistics_people for select to authenticated using(pdi_performance_private.logistics_read());
create policy log_people_insert on public.pdi_logistics_people for insert to authenticated with check(pdi_performance_private.logistics_register());
create policy log_people_update on public.pdi_logistics_people for update to authenticated using(pdi_performance_private.logistics_register())with check(pdi_performance_private.logistics_register());
create policy log_vehicle_read on public.pdi_logistics_vehicles for select to authenticated using(pdi_performance_private.logistics_read());
create policy log_vehicle_insert on public.pdi_logistics_vehicles for insert to authenticated with check(pdi_performance_private.logistics_register());
create policy log_vehicle_update on public.pdi_logistics_vehicles for update to authenticated using(pdi_performance_private.logistics_register())with check(pdi_performance_private.logistics_register());
create policy log_record_read on public.pdi_logistics_records for select to authenticated using(pdi_performance_private.logistics_read());
create policy log_record_insert on public.pdi_logistics_records for insert to authenticated with check(pdi_performance_private.can_operate_module('logistics'));
create policy log_record_update on public.pdi_logistics_records for update to authenticated using(pdi_performance_private.can_correct_module('logistics'))with check(pdi_performance_private.can_correct_module('logistics'));
create or replace function pdi_performance_private.log_number(j jsonb,k text,lo numeric,hi numeric,decimals int,required boolean default true)
returns numeric language plpgsql immutable security invoker set search_path=pg_catalog as $$declare n numeric;begin
 if j->>k is null then if required then raise exception 'Campo obrigatório: %',k using errcode='22023';end if;return null;end if;
 if jsonb_typeof(j->k)not in('string','number')then raise exception 'Número inválido: %',k using errcode='22023';end if;
 begin n:=(j->>k)::numeric;exception when invalid_text_representation then raise exception 'Número inválido: %',k using errcode='22023';end;
 if n::text in('NaN','Infinity','-Infinity')or n<lo or n>hi or scale(n)>decimals then raise exception 'Valor fora do limite ou precisão inválida: %',k using errcode='22023';end if;return n;end $$;
revoke all on function pdi_performance_private.log_number(jsonb,text,numeric,numeric,int,boolean)from public,anon;grant execute on function pdi_performance_private.log_number(jsonb,text,numeric,numeric,int,boolean)to authenticated;
create or replace function pdi_performance_private.guard_logistics_catalog()
returns trigger language plpgsql security invoker set search_path=pg_catalog as $$begin
 if auth.uid()is null or not pdi_performance_private.logistics_register()then raise exception 'Cadastros restritos à gerência de Logística e Diretoria.'using errcode='42501';end if;
 if tg_table_name='pdi_logistics_vehicles'then
 new.name:=btrim(new.name);new.plate:=regexp_replace(upper(btrim(new.plate)),'[-[:space:]]','','g');new.model:=btrim(new.model);
 if(new.acquired_on is not null and(not isfinite(new.acquired_on)or new.acquired_on>pdi_performance_private.today_manaus()))or(new.model_year is not null and new.model_year>extract(year from pdi_performance_private.today_manaus())::int+1)then raise exception 'Confira o ano/modelo e a data de aquisição.'using errcode='22023';end if;
 else new.full_name:=btrim(new.full_name);end if;
 if tg_op='INSERT'then new.created_by:=auth.uid();new.created_at:=clock_timestamp();new.revision:=1;new.reason:=null;
 else
 if row(new.id,new.created_at,new.created_by)is distinct from row(old.id,old.created_at,old.created_by)then raise exception 'Origem do cadastro não pode mudar.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))<10 or length(new.reason)>300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;
 if(to_jsonb(new)-array['reason','updated_at','updated_by','revision'])is not distinct from(to_jsonb(old)-array['reason','updated_at','updated_by','revision'])then raise exception 'Não há alteração no cadastro.'using errcode='22023';end if;new.revision:=old.revision+1;end if;
 new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $$;
revoke all on function pdi_performance_private.guard_logistics_catalog()from public,anon,authenticated;
create trigger pdi_guard_log_people before insert or update on public.pdi_logistics_people for each row execute function pdi_performance_private.guard_logistics_catalog();
create trigger pdi_guard_log_vehicles before insert or update on public.pdi_logistics_vehicles for each row execute function pdi_performance_private.guard_logistics_catalog();
create or replace function pdi_performance_private.guard_logistics_record()
returns trigger language plpgsql security invoker set search_path=pg_catalog as $$
declare j jsonb:=new.data;v public.pdi_logistics_vehicles%rowtype;p public.pdi_logistics_people%rowtype;keys text[];n numeric;x numeric;expected int;worked int;pause int:=0;seq int[];a int;b int;prev int;offset_day int:=0;start_min int;end_min int;end_day date;begin
 if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 if tg_op='INSERT'then if not pdi_performance_private.can_operate_module('logistics')then raise exception 'Coleta restrita à Logística e supervisão autorizada.'using errcode='42501';end if;new.created_by:=auth.uid();new.created_at:=clock_timestamp();new.revision:=1;new.active:=true;
 else
 if not pdi_performance_private.can_correct_module('logistics')then raise exception 'Ajustes operacionais restritos à supervisão de Logística.'using errcode='42501';end if;
 if row(new.id,new.kind,new.created_at,new.created_by)is distinct from row(old.id,old.kind,old.created_at,old.created_by)then raise exception 'Origem e tipo do registro não podem mudar.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))<10 or length(new.reason)>300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;new.revision:=old.revision+1;end if;
 if new.work_date is null or not isfinite(new.work_date)or(new.kind<>'schedule'and new.work_date>pdi_performance_private.today_manaus())then raise exception 'Data inválida para registro realizado.'using errcode='22023';end if;
 if jsonb_typeof(j)is distinct from'object'or length(coalesce(j->>'notes',''))>1000 then raise exception 'Dados ou observação inválidos.'using errcode='22023';end if;
 if new.kind<>'attendance'then
 select id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by,null::text into v from public.pdi_logistics_vehicles where id=new.vehicle_id;
 if v.id is null or(not v.active and(tg_op='INSERT'or new.vehicle_id is distinct from old.vehicle_id))then raise exception 'Selecione um veículo ativo.'using errcode='22023';end if;
 else if new.vehicle_id is not null then raise exception 'Jornada não utiliza veículo.'using errcode='22023';end if;end if;
 if new.kind in('movement','replacement','attendance','fuel')then
 select id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by,null::text into p from public.pdi_logistics_people where id=new.person_id;
 if p.id is null or(not p.active and(tg_op='INSERT'or new.person_id is distinct from old.person_id))then raise exception 'Selecione um colaborador ativo.'using errcode='22023';end if;
 if new.kind in('movement','replacement')and p.kind<>'driver'and(tg_op='INSERT'or new.person_id is distinct from old.person_id)then raise exception 'Selecione um colaborador cadastrado como motorista.'using errcode='22023';end if;
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
 if tg_op='INSERT'or new.person_id is distinct from old.person_id then new.person_name_snapshot:=p.full_name;else new.person_name_snapshot:=old.person_name_snapshot;end if;
 if tg_op='UPDATE'and row(new.work_date,new.vehicle_id,new.person_id,new.data,new.active)is not distinct from row(old.work_date,old.vehicle_id,old.person_id,old.data,old.active)then raise exception 'Não há alteração no registro.'using errcode='22023';end if;
 if tg_op='INSERT'then new.reason:=null;end if;new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $$;
revoke all on function pdi_performance_private.guard_logistics_record()from public,anon,authenticated;
create trigger pdi_guard_log_records before insert or update on public.pdi_logistics_records for each row execute function pdi_performance_private.guard_logistics_record();
create or replace function pdi_performance_private.audit_logistics()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare process_name text;person uuid;begin
 if tg_table_name='pdi_logistics_records'then process_name:=case new.kind when'movement'then'movimentacoes'when'replacement'then'reposicao'when'attendance'then'jornada'when'maintenance'then'manutencao'when'schedule'then'cronograma'else'abastecimento'end;person:=new.person_id;else process_name:='cadastros';person:=null;end if;
 perform pdi_performance_private.record_event('logistics',process_name,tg_op||'_'||upper(tg_table_name),person,case when tg_op='UPDATE'then to_jsonb(old)||jsonb_build_object('_situacao',case when old.active then'Ativo'when tg_table_name='pdi_logistics_records'then'Anulado'else'Inativo'end)else null end,to_jsonb(new)||jsonb_build_object('_situacao',case when new.active then'Ativo'when tg_table_name='pdi_logistics_records'then'Anulado'else'Inativo'end),new.reason);return new;end $$;
revoke all on function pdi_performance_private.audit_logistics()from public,anon,authenticated;
create trigger pdi_audit_log_people after insert or update on public.pdi_logistics_people for each row execute function pdi_performance_private.audit_logistics();
create trigger pdi_audit_log_vehicles after insert or update on public.pdi_logistics_vehicles for each row execute function pdi_performance_private.audit_logistics();
create trigger pdi_audit_log_records after insert or update on public.pdi_logistics_records for each row execute function pdi_performance_private.audit_logistics();

create or replace function pdi_performance_private.audit_search_text(t text)returns text language sql immutable security invoker set search_path=pg_catalog as $$select translate(lower(coalesce(t,'')),'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc')$$;
revoke all on function pdi_performance_private.audit_search_text(text)from public,anon;grant execute on function pdi_performance_private.audit_search_text(text)to authenticated;

CREATE OR REPLACE FUNCTION public.pdi_audit_query(p_module text, p_month date, p_search text DEFAULT ''::text, p_subject uuid DEFAULT NULL::uuid, p_offset integer DEFAULT 0, p_export boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare payload jsonb;n int;export_id uuid;start_at timestamptz;end_at timestamptz;begin
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

CREATE OR REPLACE FUNCTION public.pdi_audit_export_history(p_module text, p_month date, p_search text DEFAULT ''::text, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ declare result jsonb;begin
 if auth.uid()is null or p_module not in('pcp_m2','cash_daily','logistics')or not pdi_performance_private.can_audit_module(p_module)then raise exception 'Consulta restrita à gestão da área.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_offset<0 or length(coalesce(p_search,''))>150 then raise exception 'Filtro inválido.'using errcode='22023';end if;
 with f as materialized(select *from public.pdi_audit_exports e where module_key=p_module and reference_month=p_month and(coalesce(p_search,'')=''or strpos(pdi_performance_private.audit_search_text(concat_ws(' ',e.actor_name,e.actor_email,e.actor_id::text,e.search_text)),pdi_performance_private.audit_search_text(p_search))>0))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by created_at desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $function$;

CREATE OR REPLACE FUNCTION pdi_performance_private.can_collect_module(p_module text)
 RETURNS boolean
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$ select auth.uid() is not null and not pdi_performance_private.is_indicator_admin()
 and coalesce(pdi_performance_private.module_level(p_module),'')<>'manager' and exists(
 select 1 from public.profiles p join public.pdi_indicator_modules m on m.module_key=p_module join public.pdi_indicator_areas r on r.area_key=m.area_key
 where p.id=auth.uid() and p.role in('employee','colaborador','supervisor') and (p.role<>'supervisor' or pdi_performance_private.can_correct_module(p_module)) and m.enabled and r.active
 and case m.collector_rule when 'pcp' then lower(btrim(coalesce(p.position,'')))='pcp' when 'cash' then pdi_performance_private.is_cash_position(p.position) when 'logistics' then translate(lower(coalesce(p.position,'')),'í','i')like'%logistica%' else false end) $function$;

CREATE OR REPLACE FUNCTION pdi_performance_private.record_audit_export(p_module text, p_month date, p_search text, p_subject uuid, p_count integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$ declare k uuid;p public.profiles%rowtype;begin
 if auth.uid()is null or not pdi_performance_private.can_audit_module(p_module)or p_module not in('pcp_m2','cash_daily','logistics')then raise exception 'Exportação restrita à gerência da área e Diretoria.'using errcode='42501';end if;
 select *into p from public.profiles where id=auth.uid();insert into public.pdi_audit_exports(module_key,reference_month,search_text,subject_id,row_count,actor_id,actor_name,actor_email,actor_role)values(p_module,p_month,left(coalesce(p_search,''),150),p_subject,p_count,auth.uid(),coalesce(p.full_name,'Usuário'),coalesce((select u.email from auth.users u where u.id=auth.uid()),p.email),pdi_performance_private.module_level(p_module))returning id into k;return k;end $function$;

CREATE OR REPLACE FUNCTION pdi_performance_private.audit_profile_performance_access()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare m record;begin
 for m in select module_key from public.pdi_indicator_modules where module_key in('pcp_m2','cash_daily','logistics')loop
 perform pdi_performance_private.record_event(m.module_key,'acessos','PROFILE_PERFORMANCE_ACCESS_CHANGED',new.id,jsonb_build_object('id',old.id,'role',old.role,'sector',old.sector,'position',old.position,'is_master',old.is_master),jsonb_build_object('id',new.id,'role',new.role,'sector',new.sector,'position',new.position,'is_master',new.is_master),null);end loop;return new;end $function$;

create or replace function public.pdi_logistics_context()
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$begin
 if not pdi_performance_private.logistics_read()then raise exception 'Acesso restrito à Logística autorizada.'using errcode='42501';end if;
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'can_dashboard',pdi_performance_private.can_view_module('logistics'),'can_create',pdi_performance_private.can_operate_module('logistics'),'can_correct',pdi_performance_private.can_correct_module('logistics'),'can_register',pdi_performance_private.logistics_register(),'can_view_logs',pdi_performance_private.can_audit_module('logistics'),
 'people',(select coalesce(jsonb_agg(to_jsonb(p)order by full_name),'[]')from(select id,full_name,kind,profile_id,expected_minutes,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_people)p),
 'vehicles',(select coalesce(jsonb_agg(to_jsonb(v)order by name),'[]')from(select id,name,plate,model,brand,model_year,acquired_on,active,notes,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_vehicles)v));end $$;
revoke all on function public.pdi_logistics_context()from public,anon;grant execute on function public.pdi_logistics_context()to authenticated;
create or replace function public.pdi_logistics_list(p_kind text,p_start date,p_end date,p_vehicle uuid default null,p_person uuid default null,p_offset int default 0,p_cancelled boolean default false)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$declare result jsonb;begin
 if not pdi_performance_private.logistics_read()then raise exception 'Acesso restrito à Logística.'using errcode='42501';end if;
 if p_kind not in('movement','replacement','attendance','maintenance','schedule','fuel')or p_kind is null or p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Selecione processo e período válidos, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where kind=p_kind and work_date between p_start and p_end and(p_cancelled or active)and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule')))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $$;
revoke all on function public.pdi_logistics_list(text,date,date,uuid,uuid,int,boolean)from public,anon;grant execute on function public.pdi_logistics_list(text,date,date,uuid,uuid,int,boolean)to authenticated;
create or replace function public.pdi_logistics_save(p_id uuid,p_kind text,p_day date,p_vehicle uuid,p_person uuid,p_data jsonb,p_revision int default null,p_active boolean default true,p_reason text default null)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$declare r record;begin
 if p_revision is null then
 begin insert into public.pdi_logistics_records(id,kind,work_date,vehicle_id,person_id,data)values(p_id,p_kind,p_day,p_vehicle,p_person,p_data)returning id,revision into r;
 exception when unique_violation then
 select id,revision into r from public.pdi_logistics_records where id=p_id and created_by=auth.uid()and kind=p_kind;
 if r.id is null then raise exception 'Já existe um apontamento de jornada para esse colaborador/dia ou identificação duplicada.'using errcode='23505';end if;
 return jsonb_build_object('id',r.id,'revision',r.revision,'already_saved',true);end;
 else
 update public.pdi_logistics_records set work_date=p_day,vehicle_id=p_vehicle,person_id=p_person,data=p_data,active=p_active,reason=p_reason where id=p_id and kind=p_kind and revision=p_revision returning id,revision into r;
 if r.id is null then raise exception 'Registro alterado por outra pessoa ou fora do seu acesso. Atualize antes de ajustar.'using errcode='40001';end if;end if;
 return jsonb_build_object('id',r.id,'revision',r.revision,'already_saved',false);end $$;
revoke all on function public.pdi_logistics_save(uuid,text,date,uuid,uuid,jsonb,int,boolean,text)from public,anon;grant execute on function public.pdi_logistics_save(uuid,text,date,uuid,uuid,jsonb,int,boolean,text)to authenticated;
create or replace function public.pdi_logistics_dashboard(p_start date,p_end date,p_vehicle uuid default null,p_person uuid default null)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$declare result jsonb;begin
 if not pdi_performance_private.can_view_module('logistics')then raise exception 'Indicadores restritos à supervisão e gestão de Logística.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 then raise exception 'Período inválido (até 3 anos).'using errcode='22023';end if;
 with f as materialized(select id,kind,work_date,vehicle_id,person_id,data,vehicle_name_snapshot,plate_snapshot,person_name_snapshot,active,revision,created_at,created_by,updated_at,updated_by from public.pdi_logistics_records where active and work_date between p_start and p_end and(p_vehicle is null or vehicle_id=p_vehicle or kind='attendance')and(p_person is null or person_id=p_person or kind in('maintenance','schedule'))),
 movement as(select *from f where kind='movement'),replacements as(select *from f where kind='replacement'),attendance as(select *from f where kind='attendance'),maintenance as(select *from f where kind='maintenance'),schedule as(select *from f where kind='schedule'),fuel as(select *from f where kind='fuel')
 select jsonb_build_object(
 'movement',jsonb_build_object('count',(select count(*)from movement),'m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from movement),'km',(select coalesce(sum((data->>'km')::numeric),0)::text from movement),'collected_cents',(select coalesce(sum((data->>'collected_cents')::bigint),0)::text from movement),'spent_cents',(select coalesce(sum((data->>'spent_cents')::bigint),0)::text from movement),'fee_count',(select count(*)from movement where(data->>'fee')::boolean)),
 'replacement',jsonb_build_object('count',(select count(*)from replacements),'m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from replacements),'km',(select coalesce(sum((data->>'km')::numeric),0)::text from replacements)),
 'attendance',jsonb_build_object('count',(select count(*)from attendance),'people',(select count(distinct person_id)from attendance),'worked_minutes',(select coalesce(sum((data->>'worked_minutes')::int),0)::text from attendance),'expected_minutes',(select coalesce(sum((data->>'expected_minutes')::int),0)::text from attendance),'balance_minutes',(select coalesce(sum((data->>'balance_minutes')::int),0)::text from attendance)),
 'maintenance',jsonb_build_object('count',(select count(*)from maintenance),'cost_cents',(select coalesce(sum((data->>'cost_cents')::bigint),0)::text from maintenance)),
 'schedule',jsonb_build_object('count',(select count(*)from schedule),'estimated_cents',(select coalesce(sum((data->>'estimated_cents')::bigint),0)::text from schedule)),
 'fuel',jsonb_build_object('count',(select count(*)from fuel),'liters',(select coalesce(sum((data->>'liters')::numeric),0)::text from fuel),'cost_cents',(select coalesce(sum((data->>'cost_cents')::bigint),0)::text from fuel),'price_per_liter',(select round(sum((data->>'cost_cents')::numeric)/nullif(sum((data->>'liters')::numeric),0)/100,2)::text from fuel)),
 'alerts',jsonb_build_object('open_maintenance',(select count(*)from public.pdi_logistics_records where kind='maintenance'and active and nullif(data->>'end_date','')is null and(p_vehicle is null or vehicle_id=p_vehicle)),'overdue_schedule',(select count(*)from public.pdi_logistics_records where kind='schedule'and active and data->>'status'='planned'and work_date<pdi_performance_private.today_manaus()and(p_vehicle is null or vehicle_id=p_vehicle))),
 'vehicle_movement',coalesce((select jsonb_agg(jsonb_build_object('id',vehicle_id,'label',name,'value',total::text)order by total desc)from(select vehicle_id,max(vehicle_name_snapshot)name,sum((data->>'m2')::numeric)total from movement group by vehicle_id)x),'[]'),
 'replacement_sectors',coalesce((select jsonb_agg(jsonb_build_object('label',sector,'value',count)order by count desc)from(select data->>'sector'sector,count(*)from replacements group by data->>'sector')x),'[]'),
 'attendance_people',coalesce((select jsonb_agg(jsonb_build_object('id',person_id,'label',name,'worked',worked::text,'expected',expected::text,'value',balance::text)order by balance desc)from(select person_id,max(person_name_snapshot)name,sum((data->>'worked_minutes')::int)worked,sum((data->>'expected_minutes')::int)expected,sum((data->>'balance_minutes')::int)balance from attendance group by person_id)x),'[]'),
 'maintenance_types',coalesce((select jsonb_agg(jsonb_build_object('label',type,'value',total::text))from(select data->>'maintenance_type'type,sum((data->>'cost_cents')::bigint)total from maintenance group by data->>'maintenance_type')x),'[]'),
 'schedule_dates',coalesce((select jsonb_agg(jsonb_build_object('label',work_date,'value',total::text)order by work_date)from(select work_date,sum((data->>'estimated_cents')::bigint)total from schedule group by work_date)x),'[]'),
 'fuel_vehicles',coalesce((select jsonb_agg(jsonb_build_object('id',vehicle_id,'label',name,'value',total::text)order by total desc)from(select vehicle_id,max(vehicle_name_snapshot)name,sum((data->>'cost_cents')::bigint)total from fuel group by vehicle_id)x),'[]'),
 'daily',coalesce((select jsonb_agg(jsonb_build_object('label',work_date,'value',total::text)order by work_date)from(select work_date,sum((data->>'m2')::numeric)total from movement group by work_date)x),'[]'))into result;
 perform pdi_performance_private.record_event('logistics','dashboard','DASHBOARD_VIEW',p_person,null,jsonb_build_object('start_date',p_start,'end_date',p_end,'vehicle_id',p_vehicle),null);return result;end $$;
revoke all on function public.pdi_logistics_dashboard(date,date,uuid,uuid)from public,anon;grant execute on function public.pdi_logistics_dashboard(date,date,uuid,uuid)to authenticated;

notify pgrst,'reload schema';
commit;
