begin;
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_logistics_catalog()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$begin
 if auth.uid()is null or not pdi_performance_private.logistics_register()then raise exception 'Cadastros restritos à gerência de Logística e Diretoria.'using errcode='42501';end if;
 if tg_table_name='pdi_logistics_vehicles'then
 new.name:=btrim(new.name);new.plate:=regexp_replace(upper(btrim(new.plate)),'[-[:space:]]','','g');new.model:=btrim(new.model);
 if(new.acquired_on is not null and(not isfinite(new.acquired_on)or new.acquired_on>pdi_performance_private.today_manaus()))or(new.model_year is not null and new.model_year>extract(year from pdi_performance_private.today_manaus())::int+1)then raise exception 'Confira o ano/modelo e a data de aquisição.'using errcode='22023';end if;
 else new.full_name:=btrim(new.full_name);if new.kind='other'then new.expected_minutes:=0;end if;end if;
 if tg_op='INSERT'then new.created_by:=auth.uid();new.created_at:=clock_timestamp();new.revision:=1;new.reason:=null;
 else
 if row(new.id,new.created_at,new.created_by)is distinct from row(old.id,old.created_at,old.created_by)then raise exception 'Origem do cadastro não pode mudar.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))<10 or length(new.reason)>300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;
 if(to_jsonb(new)-array['reason','updated_at','updated_by','revision'])is not distinct from(to_jsonb(old)-array['reason','updated_at','updated_by','revision'])then raise exception 'Não há alteração no cadastro.'using errcode='22023';end if;new.revision:=old.revision+1;end if;
 new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_logistics_record()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
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
 if tg_op='INSERT'or new.person_id is distinct from old.person_id then new.person_name_snapshot:=p.full_name;else new.person_name_snapshot:=old.person_name_snapshot;end if;
 if tg_op='UPDATE'and row(new.work_date,new.vehicle_id,new.person_id,new.data,new.active)is not distinct from row(old.work_date,old.vehicle_id,old.person_id,old.data,old.active)then raise exception 'Não há alteração no registro.'using errcode='22023';end if;
 if tg_op='INSERT'then new.reason:=null;end if;new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $function$
;
notify pgrst,'reload schema';commit;
