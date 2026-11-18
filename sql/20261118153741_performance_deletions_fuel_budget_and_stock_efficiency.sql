begin;
create or replace function pdi_performance_private.performance_manager()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select auth.uid()is not null and(pdi_performance_private.is_indicator_admin()or exists(select 1 from public.profiles where id=auth.uid()and role='gerente')or exists(select 1 from public.pdi_area_memberships where profile_id=auth.uid()and access_level='manager'))$$;
create or replace function pdi_performance_private.stock_waste_supervisor()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select auth.uid()='9af9df80-926c-42a6-a56c-ee3f1ba08e30'::uuid and exists(select 1 from public.profiles where id=auth.uid()and role='supervisor')$$;
revoke all on function pdi_performance_private.performance_manager(),pdi_performance_private.stock_waste_supervisor()from public,anon;grant execute on function pdi_performance_private.performance_manager(),pdi_performance_private.stock_waste_supervisor()to authenticated;
-- One reusable deletion-target registry on the existing module configuration.
alter table public.pdi_indicator_modules add column deletion_targets jsonb not null default '{}';
update public.pdi_indicator_modules set deletion_targets=case module_key when'pcp_m2'then'{"daily":{"table":"pdi_pcp_daily","pk":"id"},"waste":{"table":"pdi_pcp_waste","pk":"entry_id"}}'::jsonb when'cash_daily'then'{"daily":{"table":"pdi_cash_daily","pk":"id"}}'::jsonb when'logistics'then'{"records":{"table":"pdi_logistics_records","pk":"id"},"people":{"table":"pdi_logistics_people","pk":"id"},"vehicles":{"table":"pdi_logistics_vehicles","pk":"id"}}'::jsonb when'stock'then'{"records":{"table":"pdi_logistics_records","pk":"id"}}'::jsonb else deletion_targets end;
do $$declare t text;begin foreach t in array array['pdi_pcp_daily','pdi_pcp_waste','pdi_cash_daily','pdi_logistics_people','pdi_logistics_vehicles','pdi_logistics_records']loop execute format('alter table public.%I add column is_deleted boolean not null default false',t);execute format('grant select(is_deleted)on public.%I to authenticated',t);execute format('create policy performance_not_deleted on public.%I as restrictive for select to authenticated using(not is_deleted)',t);end loop;end$$;
alter table public.pdi_pcp_daily drop constraint pdi_pcp_one_entry_per_day;
create unique index pdi_pcp_one_entry_per_day on public.pdi_pcp_daily(pcp_id,work_date)where not is_deleted;
alter table public.pdi_cash_daily drop constraint pdi_cash_one_entry_per_day;
create unique index pdi_cash_one_entry_per_day on public.pdi_cash_daily(cashier_id,work_date)where not is_deleted;
drop index public.pdi_log_attendance_day_unique;
create unique index pdi_log_attendance_day_unique on public.pdi_logistics_records(person_id,work_date)where kind='attendance'and active and not is_deleted;
-- A table-wide unique profile/plate must also permit replacement of an archived catalog entry.
alter table public.pdi_logistics_people drop constraint pdi_logistics_people_profile_id_key;
create unique index pdi_log_people_profile_active on public.pdi_logistics_people(profile_id)where not is_deleted;
alter table public.pdi_logistics_vehicles drop constraint pdi_logistics_vehicles_plate_key;
create unique index pdi_log_vehicle_plate_active on public.pdi_logistics_vehicles(plate)where not is_deleted;
create or replace function pdi_performance_private.soft_delete_guard(old_row jsonb,new_row jsonb)returns boolean language plpgsql stable security invoker set search_path=pg_catalog as $$begin
 if(old_row->>'is_deleted')::boolean then raise exception 'Registro excluído não pode ser alterado.'using errcode='42501';end if;
 if old_row->'is_deleted'is distinct from new_row->'is_deleted'then
 if new_row->>'is_deleted'<>'true'or current_user in('authenticated','anon')or not pdi_performance_private.performance_manager()or(old_row-'is_deleted')is distinct from(new_row-'is_deleted')then raise exception 'Exclusão restrita à gerência e Diretoria.'using errcode='42501';end if;return true;end if;return false;end$$;
revoke all on function pdi_performance_private.soft_delete_guard(jsonb,jsonb)from public,anon;grant execute on function pdi_performance_private.soft_delete_guard(jsonb,jsonb)to authenticated;
create or replace function pdi_performance_private.delete_performance(p_module text,p_entity text,p_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path=pg_catalog as $$declare cfg jsonb;t text;pk text;before_row jsonb;k uuid;begin
 if not pdi_performance_private.performance_manager()then raise exception 'Exclusão restrita à gerência e Diretoria.'using errcode='42501';end if;
 if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique a exclusão em 10 a 300 caracteres.'using errcode='22023';end if;
 select deletion_targets->p_entity into cfg from public.pdi_indicator_modules where module_key=p_module and enabled;
 t:=cfg->>'table';pk:=cfg->>'pk';if t is null or pk not in('id','entry_id')or t!~'^pdi_[a-z0-9_]+$'then raise exception 'Processo não habilitado para exclusão.'using errcode='22023';end if;
 execute format('select to_jsonb(x)from public.%I x where %I=$1 and not is_deleted for update',t,pk)into before_row using p_id;
 if before_row is null or(p_module='stock'and before_row->>'origin_module'<>'stock')then raise exception 'Registro não encontrado neste processo.'using errcode='22023';end if;
 execute format('update public.%I set is_deleted=true where %I=$1',t,pk)using p_id;
 k:=pdi_performance_private.record_event(case when p_module='stock'then'logistics'else p_module end,'exclusao','PERFORMANCE_DELETED',coalesce((before_row->>'pcp_id')::uuid,(before_row->>'cashier_id')::uuid,(before_row->>'person_id')::uuid),before_row,jsonb_build_object('record_id',p_id,'table',t,'module',p_module,'is_deleted',true),p_reason);return k;end$$;
revoke all on function pdi_performance_private.delete_performance(text,text,uuid,text)from public,anon;grant execute on function pdi_performance_private.delete_performance(text,text,uuid,text)to authenticated;
create or replace function public.pdi_delete_performance(p_module text,p_entity text,p_id uuid,p_reason text)returns uuid language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.delete_performance(p_module,p_entity,p_id,p_reason)$$;
revoke all on function public.pdi_delete_performance(text,text,uuid,text)from public,anon;grant execute on function public.pdi_delete_performance(text,text,uuid,text)to authenticated;
alter table public.pdi_logistics_records drop constraint pdi_logistics_records_kind_check;
alter table public.pdi_logistics_records add constraint pdi_logistics_records_kind_check check(kind in('movement','replacement','attendance','maintenance','schedule','fuel','fuel_budget','stock_waste'));
create index pdi_log_active_work_date on public.pdi_logistics_records(work_date,kind)where active and not is_deleted;
create unique index pdi_fuel_budget_month on public.pdi_logistics_records(work_date)where kind='fuel_budget'and active and not is_deleted;
create unique index pdi_stock_waste_entry on public.pdi_logistics_records((data->>'stock_entry'))where kind='stock_waste'and active and not is_deleted;
alter policy log_record_read on public.pdi_logistics_records using(pdi_performance_private.logistics_read()or(origin_module='stock'and(pdi_performance_private.stock_waste_supervisor()or pdi_performance_private.performance_manager()or((created_by=(select auth.uid())or kind='stock_waste')and pdi_performance_private.stock_operator())))or(kind='fuel_budget'and pdi_performance_private.performance_manager()));
alter policy log_record_insert on public.pdi_logistics_records with check(pdi_performance_private.can_operate_module('logistics')or(origin_module='stock'and pdi_performance_private.stock_operator())or(kind='fuel_budget'and pdi_performance_private.performance_manager())or(kind='stock_waste'and pdi_performance_private.stock_waste_supervisor()));
alter policy log_record_update on public.pdi_logistics_records using(pdi_performance_private.can_correct_module('logistics')or(kind='fuel_budget'and pdi_performance_private.performance_manager())or(kind='stock_waste'and pdi_performance_private.stock_waste_supervisor()))with check(pdi_performance_private.can_correct_module('logistics')or(kind='fuel_budget'and pdi_performance_private.performance_manager())or(kind='stock_waste'and pdi_performance_private.stock_waste_supervisor()));

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
 if new.m2_saved is null or new.m2_saved::text in ('NaN','Infinity','-Infinity') or new.m2_saved<0 or new.m2_saved>=1000000000 or scale(new.m2_saved)>3 then
   raise exception 'Informe uma quantidade válida de m², com até 3 casas decimais.' using errcode='22023';
 end if;
 if new.m2_analyzed is null or new.m2_analyzed::text in('NaN','Infinity','-Infinity') or new.m2_analyzed<0 or new.m2_analyzed>=1000000000 or scale(new.m2_analyzed)>3 then
 raise exception 'Informe os m² analisados, com até 3 casas decimais.' using errcode='22023';end if;
 if new.m2_saved>new.m2_analyzed then raise exception 'Os m² salvos não podem superar os analisados.' using errcode='22023';end if;
 if exists(select 1 from public.pdi_pcp_waste w where w.entry_id=new.id and w.m2_wasted+new.m2_saved>new.m2_analyzed)then raise exception 'Analisado deve comportar os m² salvos e o desperdício já registrado.' using errcode='22023';end if;
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
   if p.id is null or lower(btrim(coalesce(p.position,'')))<>'pcp' then
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
end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_cash_daily()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare p public.profiles%rowtype; uid uuid:=auth.uid(); trusted boolean;
 caller text:=coalesce(current_setting('role',true),'none');
 plan jsonb; canonical jsonb:='[]'; total numeric; amount numeric; n numeric; last_amount numeric; installment_sum numeric:=0;
begin
 if tg_op='INSERT'and new.is_deleted then raise exception 'Não é permitido inserir registro excluído.'using errcode='42501';end if;
 if tg_op='UPDATE'and pdi_performance_private.soft_delete_guard(to_jsonb(old),to_jsonb(new))then new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();new.revision:=old.revision+1;return new;end if;
 
 trusted:=caller='service_role' or (caller in ('none','postgres') and session_user in ('postgres','supabase_admin'));
 if tg_op='DELETE' then
   if not trusted then raise exception 'Fechamentos não podem ser excluídos pelo aplicativo.' using errcode='42501'; end if;
   return old;
 end if;
 if uid is null and not trusted then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 if tg_op='INSERT' then
   select * into p from public.profiles where id=new.cashier_id;
   if p.id is null or not pdi_performance_private.is_cash_position(p.position) then raise exception 'Colaborador sem cargo de Caixa.' using errcode='42501'; end if;
   if not trusted and not pdi_performance_private.can_operate_module('cash_daily') then raise exception 'Gerência e Diretoria possuem acesso somente de consulta.' using errcode='42501'; end if;
   if not trusted and (new.cashier_id<>uid or new.work_date is distinct from pdi_performance_private.today_manaus()) then raise exception 'Registre somente o próprio fechamento de hoje.' using errcode='42501'; end if;
   new.cashier_name_snapshot:=coalesce(p.full_name,'Op. de Caixa'); new.sector_snapshot:=p.sector;
   new.created_at:=clock_timestamp(); new.created_by:=uid; new.revision:=1; new.edit_reason:=null;
 else
   if new.id is distinct from old.id or new.cashier_id is distinct from old.cashier_id or new.work_date is distinct from old.work_date
     or new.created_at is distinct from old.created_at or new.created_by is distinct from old.created_by
     or new.cashier_name_snapshot is distinct from old.cashier_name_snapshot or new.sector_snapshot is distinct from old.sector_snapshot then
     raise exception 'A identidade, data e origem do fechamento não podem ser alteradas.' using errcode='22023'; end if;
   if not trusted and not pdi_performance_private.can_correct_module('cash_daily') then raise exception 'Correção restrita à supervisão do setor.' using errcode='42501'; end if;
   if length(btrim(coalesce(new.edit_reason,'')))<10 or length(new.edit_reason)>300 then raise exception 'Informe uma justificativa de 10 a 300 caracteres.' using errcode='22023'; end if;
 end if;
 if new.installment_plans is null or jsonb_typeof(new.installment_plans)<>'array' or jsonb_array_length(new.installment_plans)>200 then raise exception 'Lista de parcelamentos inválida (máximo 200).' using errcode='22023'; end if;
 for plan in select * from jsonb_array_elements(new.installment_plans) loop
   if jsonb_typeof(plan)<>'object' or jsonb_typeof(plan->'total_cents') is distinct from 'number'
     or jsonb_typeof(plan->'installment_cents') is distinct from 'number' or jsonb_typeof(plan->'count') is distinct from 'number' then
     raise exception 'Preencha total, valor da parcela e quantidade de cada parcelamento.' using errcode='22023'; end if;
   total:=(plan->>'total_cents')::numeric; amount:=(plan->>'installment_cents')::numeric; n:=(plan->>'count')::numeric;
   if total<>trunc(total) or amount<>trunc(amount) or n<>trunc(n) or total<=0 or total>99999999999 or amount<=0 or amount>99999999999 or n<2 or n>120 then
     raise exception 'Parcelamento inválido: valores em centavos e quantidade de 2 a 120.' using errcode='22023'; end if;
   last_amount:=total-amount*(n-1);
   if amount<floor(total/n) or amount>ceil(total/n) or last_amount<=0 then
     raise exception 'O valor das parcelas não corresponde ao total. Só são permitidos ajustes de centavos na última parcela.' using errcode='22023'; end if;
   installment_sum:=installment_sum+total;
   canonical:=canonical||jsonb_build_array(jsonb_build_object('total_cents',total::bigint,'installment_cents',amount::bigint,'count',n::integer,'last_installment_cents',last_amount::bigint));
 end loop;
 if installment_sum>99999999999 then raise exception 'Total parcelado excede o limite técnico.' using errcode='22023'; end if;
 new.installment_plans:=canonical; new.credit_installment_cents:=installment_sum::bigint;
 if new.result_cents is null or new.cash_cents is null or new.credit_cash_cents is null or new.debit_cents is null or new.pix_cents is null
   or least(new.result_cents,new.cash_cents,new.credit_cash_cents,new.debit_cents,new.pix_cents)<0
   or greatest(new.result_cents,new.cash_cents,new.credit_cash_cents,new.debit_cents,new.pix_cents)>99999999999
   or new.result_cents<>new.cash_cents+new.credit_cash_cents+new.credit_installment_cents+new.debit_cents+new.pix_cents then
   raise exception 'O Resultado do Dia precisa ser igual à soma de Dinheiro, Crédito à vista, Crédito parcelado, Débito e Pix.' using errcode='22023'; end if;
 if new.pdf_file_id is not null and (tg_op='INSERT' or new.pdf_file_id is distinct from old.pdf_file_id) then
   if not pdi_performance_private.cash_pdf_ready(new.pdf_file_id,new.id,new.cashier_id) then raise exception 'PDF não enviado, expirado ou não pertence a este fechamento.' using errcode='22023'; end if;
 end if;
 new.pdf_name_snapshot:=null;
 if new.pdf_file_id is not null then select f.original_name into new.pdf_name_snapshot from public.pdi_cash_files f where f.id=new.pdf_file_id; end if;
 if tg_op='UPDATE' then
   if row(new.result_cents,new.cash_cents,new.credit_cash_cents,new.credit_installment_cents,new.debit_cents,new.pix_cents,new.installment_plans,new.pdf_file_id)
     is not distinct from row(old.result_cents,old.cash_cents,old.credit_cash_cents,old.credit_installment_cents,old.debit_cents,old.pix_cents,old.installment_plans,old.pdf_file_id) then
     raise exception 'Não há alteração nos valores ou PDF.' using errcode='22023'; end if;
   new.revision:=old.revision+1;
 end if;
 new.updated_at:=clock_timestamp(); new.updated_by:=uid;
 return new;
end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_pcp_waste()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare d public.pdi_pcp_daily%rowtype;begin
 if tg_op='INSERT'and new.is_deleted then raise exception 'Não é permitido inserir registro excluído.'using errcode='42501';end if;
 if tg_op='UPDATE'and pdi_performance_private.soft_delete_guard(to_jsonb(old),to_jsonb(new))then new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();new.revision:=old.revision+1;return new;end if;
 
 if auth.uid() is null or not pdi_performance_private.can_record_pcp_waste()then raise exception 'Desperdício restrito à supervisão e gerência de Produção.' using errcode='42501';end if;
 select * into d from public.pdi_pcp_daily where id=new.entry_id for update;
 if d.id is null or d.work_date>pdi_performance_private.today_manaus()then raise exception 'Selecione um lançamento existente do PCP.' using errcode='22023';end if;
 if d.m2_analyzed is null then raise exception 'A supervisão precisa completar os m² analisados deste registro antigo.' using errcode='22023';end if;
 if new.m2_wasted is null or new.m2_wasted::text in('NaN','Infinity','-Infinity')or new.m2_wasted<0 or new.m2_wasted>=1000000000 or scale(new.m2_wasted)>3 or new.m2_wasted+d.m2_saved>d.m2_analyzed then raise exception 'O desperdício mais os m² salvos não podem superar o analisado.' using errcode='22023';end if;
 if tg_op='INSERT'then new.revision:=1;new.created_at:=clock_timestamp();new.created_by:=auth.uid();new.reason:='Registro inicial de desperdício';
 else
 if row(new.entry_id,new.created_at,new.created_by)is distinct from row(old.entry_id,old.created_at,old.created_by)then raise exception 'Origem do desperdício não pode ser alterada.' using errcode='22023';end if;
 if new.m2_wasted=old.m2_wasted then raise exception 'Não há alteração no desperdício.' using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))<10 or length(new.reason)>300 then raise exception 'Justifique a correção em 10 a 300 caracteres.' using errcode='22023';end if;
 new.revision:=old.revision+1;end if;
 new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.guard_logistics_catalog()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$begin
 if tg_op='INSERT'and new.is_deleted then raise exception 'Não é permitido inserir registro excluído.'using errcode='42501';end if;
 if tg_op='UPDATE'and pdi_performance_private.soft_delete_guard(to_jsonb(old),to_jsonb(new))then new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();new.revision:=old.revision+1;return new;end if;
 
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
 if tg_op='INSERT'and new.is_deleted then raise exception 'Não é permitido inserir registro excluído.'using errcode='42501';end if;
 if tg_op='UPDATE'and pdi_performance_private.soft_delete_guard(to_jsonb(old),to_jsonb(new))then new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();new.revision:=old.revision+1;return new;end if;
 

 if new.kind in('fuel_budget','stock_waste')then
 if new.kind='fuel_budget'and not pdi_performance_private.performance_manager()then raise exception 'Orçamento restrito à gerência e Diretoria.'using errcode='42501';end if;
 if new.kind='stock_waste'and not pdi_performance_private.stock_waste_supervisor()then raise exception 'Desperdício restrito ao Jackson.'using errcode='42501';end if;
 if new.vehicle_id is not null or new.person_id is not null or new.work_date is null or not isfinite(new.work_date)or jsonb_typeof(j)is distinct from'object'then raise exception 'Registro inválido.'using errcode='22023';end if;
 if tg_op='UPDATE'then
 if row(new.id,new.kind,new.origin_module,new.created_by,new.created_at)is distinct from row(old.id,old.kind,old.origin_module,old.created_by,old.created_at)then raise exception 'Origem do registro não pode mudar.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))not between 10 and 300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;
 new.revision:=old.revision+1;
 else new.created_by:=auth.uid();new.created_at:=clock_timestamp();new.revision:=1;new.active:=true;new.reason:=null;end if;
 if new.kind='fuel_budget'then
 if new.origin_module<>'logistics'or new.work_date<>date_trunc('month',new.work_date)::date or exists(select 1 from jsonb_object_keys(j)k where k<>'budget_cents')then raise exception 'Orçamento mensal inválido.'using errcode='22023';end if;
 n:=pdi_performance_private.log_number(j,'budget_cents',0,99999999999,0);new.data:=jsonb_build_object('budget_cents',n);
 else
 if new.origin_module<>'stock'or exists(select 1 from jsonb_object_keys(j)k where k not in('stock_entry','m2_wasted','reason'))or length(btrim(coalesce(j->>'reason','')))not between 10 and 300 then raise exception 'Informe a causa da quebra em 10 a 300 caracteres.'using errcode='22023';end if;
 n:=pdi_performance_private.log_number(j,'m2_wasted',0,999999999.999,3);
 if not exists(select 1 from public.pdi_logistics_records r where r.id=(j->>'stock_entry')::uuid and r.kind='movement'and r.origin_module='stock'and r.active and not r.is_deleted and r.work_date=new.work_date and(r.data->>'m2')::numeric>=n)then raise exception 'Desperdício deve pertencer a uma movimentação e não superar a área movimentada.'using errcode='22023';end if;
 new.data:=jsonb_build_object('stock_entry',(j->>'stock_entry')::uuid,'m2_wasted',n,'reason',btrim(j->>'reason'));end if;
 new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();return new;
 end if;
  if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 if tg_op='INSERT'then if not(pdi_performance_private.can_operate_module('logistics')or(new.origin_module='stock'and pdi_performance_private.stock_operator()))then raise exception 'Coleta restrita à Logística e supervisão autorizada.'using errcode='42501';end if;new.created_by:=auth.uid();new.created_at:=clock_timestamp();new.revision:=1;new.active:=true;
 else
 if not pdi_performance_private.can_correct_module('logistics')then raise exception 'Ajustes operacionais restritos à supervisão de Logística.'using errcode='42501';end if;
 if row(new.id,new.kind,new.created_at,new.created_by)is distinct from row(old.id,old.kind,old.created_at,old.created_by)then raise exception 'Origem e tipo do registro não podem mudar.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))<10 or length(new.reason)>300 then raise exception 'Justifique o ajuste em 10 a 300 caracteres.'using errcode='22023';end if;new.revision:=old.revision+1;end if;
 if tg_op='UPDATE'and new.origin_module is distinct from old.origin_module then raise exception 'A origem do registro não pode mudar.'using errcode='22023';end if;
 if new.origin_module='stock'then
 if tg_op='INSERT'and not pdi_performance_private.stock_operator()then raise exception 'Origem Estoque restrita ao Vitor autorizado.'using errcode='42501';end if;
 if new.kind<>'movement'or new.person_id is not null or coalesce(j->>'movement_type','')<>'internal'or j->>'fee'is distinct from'false'or coalesce(j->>'collected_cents','')<>'0'or coalesce(j->>'spent_cents','')<>'0'then raise exception 'Estoque registra somente movimentação interna do dia, sem taxa ou valores financeiros.'using errcode='22023';end if;end if;
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
 if new.origin_module='stock'and exists(select 1 from public.pdi_logistics_records r where r.kind='stock_waste'and r.active and not r.is_deleted and r.data->>'stock_entry'=new.id::text and(r.data->>'m2_wasted')::numeric>(j->>'m2')::numeric)then raise exception 'Área movimentada não pode ser menor que o desperdício registrado.'using errcode='22023';end if;
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
create or replace function pdi_performance_private.can_view_module(p_module text)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select coalesce(pdi_performance_private.module_level(p_module)in('director','manager','supervisor'),false)or(p_module='stock'and(pdi_performance_private.stock_waste_supervisor()or pdi_performance_private.performance_manager()))$$;

CREATE OR REPLACE FUNCTION public.pdi_stock_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$begin
 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock'))then raise exception 'Estoque restrito ao colaborador autorizado.'using errcode='42501';end if;
 return jsonb_build_object('can_stock_waste',pdi_performance_private.stock_waste_supervisor(),'can_delete',pdi_performance_private.performance_manager(),'today',pdi_performance_private.today_manaus(),'can_create',pdi_performance_private.stock_operator(),'name',(select full_name from public.profiles where id=auth.uid()),'vehicles',(select coalesce(jsonb_agg(to_jsonb(v)order by name),'[]')from(select id,name,plate,model from public.pdi_logistics_vehicles where active)v));end$function$
;
CREATE OR REPLACE FUNCTION public.pdi_stock_list(p_start date, p_end date, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog'
AS $function$declare result jsonb;begin
 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock'))then raise exception 'Estoque restrito.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 or p_offset<0 then raise exception 'Período inválido, até 3 anos.'using errcode='22023';end if;
 with f as materialized(select id,work_date,person_name_snapshot,vehicle_name_snapshot,plate_snapshot,data,created_at,created_by,updated_at,updated_by,revision,active from public.pdi_logistics_records where origin_module='stock'and kind='movement'and work_date between p_start and p_end)
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id limit 30 offset p_offset)x),'[]'))into result;return result;end$function$
;
CREATE OR REPLACE FUNCTION pdi_performance_private.audit_logistics()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$declare process_name text;person uuid;begin
 if tg_table_name='pdi_logistics_records'then process_name:=case new.kind when'movement'then'movimentacoes'when'replacement'then'reposicao'when'attendance'then'jornada'when'fuel_budget'then'orcamento_abastecimento'when'stock_waste'then'desperdicio_estoque'when'maintenance'then'manutencao'when'schedule'then'cronograma'else'abastecimento'end;person:=new.person_id;else process_name:='cadastros';person:=null;end if;
 perform pdi_performance_private.record_event('logistics',process_name,tg_op||'_'||upper(tg_table_name),person,case when tg_op='UPDATE'then to_jsonb(old)||jsonb_build_object('_situacao',case when old.active then'Ativo'when tg_table_name='pdi_logistics_records'then'Anulado'else'Inativo'end)else null end,to_jsonb(new)||jsonb_build_object('_situacao',case when new.active then'Ativo'when tg_table_name='pdi_logistics_records'then'Anulado'else'Inativo'end),new.reason);return new;end $function$
;
create or replace function public.pdi_performance_permissions()returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select jsonb_build_object('can_delete',pdi_performance_private.performance_manager(),'can_budget',pdi_performance_private.performance_manager(),'can_stock_waste',pdi_performance_private.stock_waste_supervisor(),'deletion_modules',(select coalesce(jsonb_object_agg(module_key,deletion_targets),'{}')from public.pdi_indicator_modules where enabled))$$;
revoke all on function public.pdi_performance_permissions()from public,anon;grant execute on function public.pdi_performance_permissions()to authenticated;
drop function public.pdi_stock_save(uuid,uuid,text,text,text);
create function public.pdi_stock_save(p_id uuid,p_vehicle uuid,p_m2 text,p_km text,p_notes text default '',p_day date default null)returns uuid language plpgsql security invoker set search_path=pg_catalog as $$declare k uuid;begin
 if not pdi_performance_private.stock_operator()then raise exception 'Registro de Estoque restrito ao Vitor autorizado.'using errcode='42501';end if;
 insert into public.pdi_logistics_records(id,kind,origin_module,work_date,vehicle_id,person_id,data)values(p_id,'movement','stock',coalesce(p_day,pdi_performance_private.today_manaus()),p_vehicle,null,jsonb_build_object('movement_type','internal','m2',p_m2,'km',p_km,'fee',false,'collected_cents',0,'spent_cents',0,'notes',p_notes))returning id into k;return k;end$$;
revoke all on function public.pdi_stock_save(uuid,uuid,text,text,text,date)from public,anon;grant execute on function public.pdi_stock_save(uuid,uuid,text,text,text,date)to authenticated;
create or replace function public.pdi_fuel_budget_save(p_month date,p_cents bigint,p_reason text default null)returns uuid language plpgsql security invoker set search_path=pg_catalog as $$declare k uuid;rev int;begin
 if not pdi_performance_private.performance_manager()then raise exception 'Orçamento restrito à gerência e Diretoria.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_month<>date_trunc('month',p_month)::date then raise exception 'Selecione um mês válido.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('fuel_budget:'||p_month::text,0));select id,revision into k,rev from public.pdi_logistics_records where kind='fuel_budget'and work_date=p_month and active;
 if k is null then insert into public.pdi_logistics_records(kind,work_date,origin_module,data)values('fuel_budget',p_month,'logistics',jsonb_build_object('budget_cents',p_cents))returning id into k;
 else update public.pdi_logistics_records set data=jsonb_build_object('budget_cents',p_cents),reason=p_reason where id=k and revision=rev;end if;return k;end$$;
revoke all on function public.pdi_fuel_budget_save(date,bigint,text)from public,anon;grant execute on function public.pdi_fuel_budget_save(date,bigint,text)to authenticated;
create or replace function public.pdi_stock_waste_save(p_entry uuid,p_m2 text,p_reason text)returns uuid language plpgsql security invoker set search_path=pg_catalog as $$declare d record;k uuid;begin
 if not pdi_performance_private.stock_waste_supervisor()then raise exception 'Desperdício do Estoque restrito ao supervisor Jackson.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(hashtextextended('stock_waste:'||p_entry::text,0));select id,work_date into d from public.pdi_logistics_records where id=p_entry and origin_module='stock'and kind='movement'and active;
 if d.id is null then raise exception 'Selecione uma movimentação ativa do Estoque.'using errcode='22023';end if;
 select id into k from public.pdi_logistics_records where kind='stock_waste'and active and data->>'stock_entry'=p_entry::text;
 if k is null then insert into public.pdi_logistics_records(kind,origin_module,work_date,data)values('stock_waste','stock',d.work_date,jsonb_build_object('stock_entry',p_entry,'m2_wasted',p_m2,'reason',p_reason))returning id into k;
 else update public.pdi_logistics_records set data=jsonb_build_object('stock_entry',p_entry,'m2_wasted',p_m2,'reason',p_reason),reason=p_reason where id=k;end if;return k;end$$;
revoke all on function public.pdi_stock_waste_save(uuid,text,text)from public,anon;grant execute on function public.pdi_stock_waste_save(uuid,text,text)to authenticated;
create or replace function pdi_performance_private.fuel_month(p_month date)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare result jsonb;begin
 if auth.uid()is null or not(pdi_performance_private.logistics_read()or pdi_performance_private.performance_manager())then raise exception 'Abastecimento restrito à Logística e gestão.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_month<>date_trunc('month',p_month)::date then raise exception 'Mês inválido.'using errcode='22023';end if;
 with f as materialized(select kind,id,vehicle_id,vehicle_name_snapshot,data from public.pdi_logistics_records where active and not is_deleted and work_date>=p_month and work_date<(p_month+interval'1 month')::date),b as(select(data->>'budget_cents')::numeric amount,id from f where kind='fuel_budget'),fuel as(select *from f where kind='fuel'),ex as(select *from f where kind='movement'and data->>'movement_type'='external')
 select jsonb_build_object('month',p_month,'budget_id',(select id from b),'budget_cents',(select amount::text from b),'spent_cents',(select coalesce(sum((data->>'cost_cents')::numeric),0)::text from fuel),'balance_cents',(select(amount-(select coalesce(sum((data->>'cost_cents')::numeric),0)from fuel))::text from b),'used_percent',(select round((select coalesce(sum((data->>'cost_cents')::numeric),0)from fuel)*100/nullif(amount,0),2)::text from b),'liters',(select coalesce(sum((data->>'liters')::numeric),0)::text from fuel),'external_count',(select count(*)from ex),'external_m2',(select coalesce(sum((data->>'m2')::numeric),0)::text from ex),'external_km',(select coalesce(sum((data->>'km')::numeric),0)::text from ex),'external_vehicles',coalesce((select jsonb_agg(to_jsonb(v)order by m2::numeric desc)from(select vehicle_id,max(vehicle_name_snapshot)name,count(*)deliveries,sum((data->>'m2')::numeric)::text m2,sum((data->>'km')::numeric)::text km from ex group by vehicle_id)v),'[]'))into result;return result;end$$;
revoke all on function pdi_performance_private.fuel_month(date)from public,anon;grant execute on function pdi_performance_private.fuel_month(date)to authenticated;
create or replace function public.pdi_fuel_month(p_month date)returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select pdi_performance_private.fuel_month(p_month)$$;
revoke all on function public.pdi_fuel_month(date)from public,anon;grant execute on function public.pdi_fuel_month(date)to authenticated;
create or replace function public.pdi_stock_dashboard(p_start date,p_end date)returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$declare result jsonb;begin
 if not(pdi_performance_private.stock_operator()or pdi_performance_private.can_view_module('stock')or pdi_performance_private.stock_waste_supervisor())then raise exception 'Indicadores do Estoque restritos.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_end-p_start>1095 then raise exception 'Período inválido.'using errcode='22023';end if;
 with f as materialized(select id,work_date,data from public.pdi_logistics_records where origin_module='stock'and kind='movement'and active and work_date between p_start and p_end),w as materialized(select(data->>'stock_entry')::uuid entry_id,(data->>'m2_wasted')::numeric waste,id,data->>'reason'reason from public.pdi_logistics_records where kind='stock_waste'and active),joined as(select f.*,w.waste,w.id waste_id,w.reason from f left join w on w.entry_id=f.id)
 select jsonb_build_object('m2',coalesce(sum((data->>'m2')::numeric),0)::text,'movements',count(*),'wasted_m2',sum(waste)::text,'pending',count(*)filter(where waste is null),'complete_m2',sum((data->>'m2')::numeric)filter(where waste is not null)::text,'efficiency',round((sum((data->>'m2')::numeric-waste)filter(where waste is not null))*100/nullif(sum((data->>'m2')::numeric)filter(where waste is not null),0),2)::text,'daily',coalesce((select jsonb_agg(to_jsonb(x)order by date)from(select work_date date,count(*)movements,sum((data->>'m2')::numeric)::text m2 from f group by work_date)x),'[]'),'top_days',coalesce((select jsonb_agg(to_jsonb(x)order by movements desc,m2::numeric desc,date)from(select work_date date,count(*)movements,sum((data->>'m2')::numeric)::text m2 from f group by work_date order by count(*)desc,sum((data->>'m2')::numeric)desc,work_date limit 10)x),'[]'),'waste_entries',coalesce((select jsonb_agg(jsonb_build_object('id',id,'entry_id',entry_id,'m2_wasted',waste::text,'reason',reason))from w where entry_id in(select id from f)),'[]'))into result from joined;return result;end$$;
revoke all on function public.pdi_stock_dashboard(date,date)from public,anon;grant execute on function public.pdi_stock_dashboard(date,date)to authenticated;

create or replace function pdi_performance_private.deletion_list(p_module text,p_entity text,p_start date,p_end date,p_offset int)returns jsonb language plpgsql stable security definer set search_path=pg_catalog as $$declare cfg jsonb;t text;pk text;result jsonb;date_filter text;origin_filter text:='';extra text:='';begin
 if not pdi_performance_private.performance_manager()then raise exception 'Exclusão restrita à gerência e Diretoria.'using errcode='42501';end if;
 if p_start is null or p_end is null or not isfinite(p_start)or not isfinite(p_end)or p_start>p_end or p_offset<0 then raise exception 'Período inválido.'using errcode='22023';end if;
 select deletion_targets->p_entity into cfg from public.pdi_indicator_modules where module_key=p_module and enabled;t:=cfg->>'table';pk:=cfg->>'pk';if t is null or pk not in('id','entry_id')or t!~'^pdi_[a-z0-9_]+$'then raise exception 'Processo inválido.'using errcode='22023';end if;
 if p_entity in('people','vehicles')then date_filter:='true';elsif p_entity='waste'then date_filter:='exists(select 1 from public.pdi_pcp_daily d where d.id=x.entry_id and not d.is_deleted and d.work_date between $1 and $2)';else date_filter:='x.work_date between $1 and $2';end if;
 if p_entity='waste'then extra:='||coalesce((select jsonb_build_object(''work_date'',d.work_date,''pcp_name_snapshot'',d.pcp_name_snapshot)from public.pdi_pcp_daily d where d.id=x.entry_id),''{}''::jsonb)';end if;
 if p_module='stock'then origin_filter:='and x.origin_module=''stock''';end if;
 execute format($q$with f as materialized(select %I record_id,to_jsonb(x)%s r from public.%I x where not is_deleted and %s %s),mapped as(select record_id,jsonb_build_object('id',record_id,'date',r->>'work_date','label',coalesce(r->>'pcp_name_snapshot',r->>'cashier_name_snapshot',r->>'vehicle_name_snapshot',r->>'person_name_snapshot',r->>'full_name',r->>'name',r->>'kind','Registro'),'kind',r->>'kind','revision',r->'revision','m2',coalesce(r->>'m2_saved',r->>'m2_wasted',r->'data'->>'m2',r->'data'->>'m2_wasted'),'plate',coalesce(r->>'plate',r->>'plate_snapshot'))d from f)select jsonb_build_object('count',(select count(*)from mapped),'rows',coalesce((select jsonb_agg(d)from(select d from mapped order by d->>'date'desc,record_id limit 30 offset $3)y),'[]'))$q$,pk,extra,t,date_filter,origin_filter)into result using p_start,p_end,p_offset;return result;end$$;
revoke all on function pdi_performance_private.deletion_list(text,text,date,date,int)from public,anon;grant execute on function pdi_performance_private.deletion_list(text,text,date,date,int)to authenticated;
create or replace function public.pdi_deletion_list(p_module text,p_entity text,p_start date,p_end date,p_offset int default 0)returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select pdi_performance_private.deletion_list(p_module,p_entity,p_start,p_end,p_offset)$$;
revoke all on function public.pdi_deletion_list(text,text,date,date,int)from public,anon;grant execute on function public.pdi_deletion_list(text,text,date,date,int)to authenticated;

notify pgrst,'reload schema';commit;
