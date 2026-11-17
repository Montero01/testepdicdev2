begin;
drop policy if exists pdi_pcp_read on public.pdi_pcp_daily;
drop policy if exists pdi_pcp_insert on public.pdi_pcp_daily;
drop policy if exists pdi_pcp_update on public.pdi_pcp_daily;
drop policy if exists pdi_pcp_collect_guard on public.pdi_pcp_daily;
drop policy if exists pdi_pcp_correct_guard on public.pdi_pcp_daily;
create policy pdi_pcp_read on public.pdi_pcp_daily for select to authenticated using (pcp_id=(select auth.uid()) or pdi_performance_private.can_view_module('pcp_m2'));
create policy pdi_pcp_insert on public.pdi_pcp_daily for insert to authenticated with check(pcp_id=(select auth.uid()) and pdi_performance_private.can_collect_module('pcp_m2'));
create policy pdi_pcp_update on public.pdi_pcp_daily for update to authenticated using(pdi_performance_private.can_correct_module('pcp_m2')) with check(pdi_performance_private.can_correct_module('pcp_m2'));
create policy pdi_pcp_scope_guard on public.pdi_pcp_daily as restrictive for select to authenticated using(pcp_id=(select auth.uid()) or pdi_performance_private.can_view_module('pcp_m2'));
drop policy if exists pdi_cash_read on public.pdi_cash_daily;
drop policy if exists pdi_cash_insert on public.pdi_cash_daily;
drop policy if exists pdi_cash_update on public.pdi_cash_daily;
drop policy if exists pdi_cash_collect_guard on public.pdi_cash_daily;
drop policy if exists pdi_cash_correct_guard on public.pdi_cash_daily;
create policy pdi_cash_read on public.pdi_cash_daily for select to authenticated using (cashier_id=(select auth.uid()) or pdi_performance_private.can_view_module('cash_daily'));
create policy pdi_cash_insert on public.pdi_cash_daily for insert to authenticated with check(cashier_id=(select auth.uid()) and pdi_performance_private.can_collect_module('cash_daily'));
create policy pdi_cash_update on public.pdi_cash_daily for update to authenticated using(pdi_performance_private.can_correct_module('cash_daily')) with check(pdi_performance_private.can_correct_module('cash_daily'));
create policy pdi_cash_scope_guard on public.pdi_cash_daily as restrictive for select to authenticated using(cashier_id=(select auth.uid()) or pdi_performance_private.can_view_module('cash_daily'));
drop policy if exists pdi_audit_read on public.pdi_performance_audit;
create policy pdi_audit_read on public.pdi_performance_audit for select to authenticated using(pdi_performance_private.can_audit_module('pcp_m2'));
alter table public.pdi_performance_audit add column if not exists area_key_snapshot text,add column if not exists access_level_snapshot text;
drop policy if exists pdi_cash_audit_read on public.pdi_cash_audit;
create policy pdi_cash_audit_read on public.pdi_cash_audit for select to authenticated using(pdi_performance_private.can_audit_module('cash_daily'));
alter table public.pdi_cash_audit add column if not exists area_key_snapshot text,add column if not exists access_level_snapshot text;
create or replace function pdi_performance_private.guard_daily_entry()
returns trigger language plpgsql security invoker set search_path=pg_catalog
as $$
declare p public.profiles%rowtype; uid uuid:=auth.uid();
 caller_role text:=coalesce(current_setting('role',true),'none');
 trusted boolean; count_orders integer;
begin
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
 if new.order_numbers is null or array_ndims(new.order_numbers)>1 then
   raise exception 'Lista de pedidos inválida.' using errcode='22023';
 end if;
 count_orders:=cardinality(new.order_numbers);
 if count_orders>200 or exists(select 1 from unnest(new.order_numbers) o where o is null or o !~ '^[0-9]{1,20}$')
   or count_orders<>(select count(distinct o) from unnest(new.order_numbers) o) then
   raise exception 'Use até 200 números de pedidos distintos, somente dígitos, com até 20 caracteres cada.' using errcode='22023';
 end if;
 if new.m2_saved>0 and count_orders=0 then raise exception 'Informe os pedidos relacionados aos m² salvos.' using errcode='22023'; end if;
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
   if new.m2_saved=old.m2_saved and new.order_numbers=old.order_numbers then
     raise exception 'Não há alteração nos m² ou pedidos.' using errcode='22023'; end if;
   new.revision:=old.revision+1;
 end if;
 new.updated_at:=clock_timestamp(); new.updated_by:=uid;
 return new;
end $$;
create or replace function pdi_performance_private.guard_cash_daily()
returns trigger language plpgsql security invoker set search_path=pg_catalog
as $$
declare p public.profiles%rowtype; uid uuid:=auth.uid(); trusted boolean;
 caller text:=coalesce(current_setting('role',true),'none');
 plan jsonb; canonical jsonb:='[]'; total numeric; amount numeric; n numeric; last_amount numeric; installment_sum numeric:=0;
begin
 trusted:=caller='service_role' or (caller in ('none','postgres') and session_user in ('postgres','supabase_admin'));
 if tg_op='DELETE' then
   if not trusted then raise exception 'Fechamentos não podem ser excluídos pelo aplicativo.' using errcode='42501'; end if;
   return old;
 end if;
 if uid is null and not trusted then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 if tg_op='INSERT' then
   select * into p from public.profiles where id=new.cashier_id;
   if p.id is null or not pdi_performance_private.is_cash_position(p.position) then raise exception 'Colaborador sem cargo de Caixa.' using errcode='42501'; end if;
   if not trusted and not pdi_performance_private.can_collect_module('cash_daily') then raise exception 'Gerência e Diretoria possuem acesso somente de consulta.' using errcode='42501'; end if;
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
end $$;
create or replace function pdi_performance_private.cash_file_can_upload(path text)
returns boolean language sql stable security definer set search_path=pg_catalog
as $$
 select auth.uid() is not null and exists(
   select 1 from public.pdi_cash_files f where f.storage_path=path and f.uploaded_by=auth.uid()
    and f.attached_at is null and f.expires_at>statement_timestamp() and pdi_performance_private.can_operate_module('cash_daily') and (
      exists(select 1 from public.pdi_cash_daily d where d.id=f.entry_id and d.cashier_id=f.cashier_id and pdi_performance_private.can_correct_module('cash_daily'))
      or (pdi_performance_private.can_collect_module('cash_daily') and f.cashier_id=auth.uid() and f.work_date=pdi_performance_private.today_manaus()
        and exists(select 1 from public.profiles p where p.id=auth.uid() and pdi_performance_private.is_cash_position(p.position))
        and not exists(select 1 from public.pdi_cash_daily d where d.cashier_id=f.cashier_id and d.work_date=f.work_date))
    )
 )
$$;

create or replace function pdi_performance_private.cash_reserve_pdf(p_entry uuid,p_cashier uuid,p_day date,p_name text,p_size bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog
as $$
declare uid uuid:=auth.uid(); d public.pdi_cash_daily%rowtype; p public.profiles%rowtype; f public.pdi_cash_files%rowtype; clean_name text; sector text;
begin
 if uid is null then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 if not pdi_performance_private.can_operate_module('cash_daily') then raise exception 'Gerência e Diretoria não podem enviar anexos ou corrigir fechamentos.' using errcode='42501'; end if;
 if p_entry is null or p_cashier is null or p_day is null then raise exception 'Identificação do fechamento inválida.' using errcode='22023'; end if;
 clean_name:=regexp_replace(btrim(coalesce(p_name,'')),'[[:cntrl:]/\\]','_','g');
 if length(clean_name)<5 or length(clean_name)>180 or clean_name !~* '\.pdf$' or p_size is null or p_size<8 or p_size>10485760 then
   raise exception 'Use um PDF de até 10 MB, com nome de até 180 caracteres.' using errcode='22023'; end if;
 select * into d from public.pdi_cash_daily where id=p_entry;
 if d.id is not null then
   if d.cashier_id<>p_cashier or d.work_date<>p_day or not pdi_performance_private.can_correct_module('cash_daily') then
     raise exception 'Você não pode substituir o PDF deste fechamento.' using errcode='42501'; end if;
   sector:=d.sector_snapshot;
 else
   select * into p from public.profiles where id=p_cashier;
   if p_cashier<>uid or p_day<>pdi_performance_private.today_manaus() or not pdi_performance_private.is_cash_position(p.position)
     or exists(select 1 from public.pdi_cash_daily x where x.cashier_id=p_cashier and x.work_date=p_day) then
     raise exception 'Somente a operadora registra o próprio fechamento de hoje.' using errcode='42501'; end if;
   sector:=p.sector;
 end if;
 f.id:=gen_random_uuid();
 insert into public.pdi_cash_files(id,entry_id,cashier_id,work_date,sector_snapshot,uploaded_by,storage_path,original_name,size_bytes)
 values(f.id,p_entry,p_cashier,p_day,sector,uid,p_cashier::text||'/'||p_entry::text||'/'||f.id::text||'.pdf',clean_name,p_size) returning * into f;
 return jsonb_build_object('id',f.id,'path',f.storage_path,'name',f.original_name,'size',f.size_bytes);
end $$;
create or replace function pdi_performance_private.cash_reserve_pdf(p_entry uuid,p_cashier uuid,p_day date,p_name text,p_size bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog
as $$
declare uid uuid:=auth.uid(); d public.pdi_cash_daily%rowtype; p public.profiles%rowtype; f public.pdi_cash_files%rowtype; clean_name text; sector text;
begin
 if uid is null then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 if not pdi_performance_private.can_operate_module('cash_daily') then raise exception 'Gerência e Diretoria não podem enviar anexos ou corrigir fechamentos.' using errcode='42501'; end if;
 if p_entry is null or p_cashier is null or p_day is null then raise exception 'Identificação do fechamento inválida.' using errcode='22023'; end if;
 clean_name:=regexp_replace(btrim(coalesce(p_name,'')),'[[:cntrl:]/\\]','_','g');
 if length(clean_name)<5 or length(clean_name)>180 or clean_name !~* '\.pdf$' or p_size is null or p_size<8 or p_size>10485760 then
   raise exception 'Use um PDF de até 10 MB, com nome de até 180 caracteres.' using errcode='22023'; end if;
 select * into d from public.pdi_cash_daily where id=p_entry;
 if d.id is not null then
   if d.cashier_id<>p_cashier or d.work_date<>p_day or not pdi_performance_private.can_correct_module('cash_daily') then
     raise exception 'Você não pode substituir o PDF deste fechamento.' using errcode='42501'; end if;
   sector:=d.sector_snapshot;
 else
   select * into p from public.profiles where id=p_cashier;
   if not pdi_performance_private.can_collect_module('cash_daily') or p_cashier<>uid or p_day<>pdi_performance_private.today_manaus() or not pdi_performance_private.is_cash_position(p.position)
     or exists(select 1 from public.pdi_cash_daily x where x.cashier_id=p_cashier and x.work_date=p_day) then
     raise exception 'Somente a operadora registra o próprio fechamento de hoje.' using errcode='42501'; end if;
   sector:=p.sector;
 end if;
 f.id:=gen_random_uuid();
 insert into public.pdi_cash_files(id,entry_id,cashier_id,work_date,sector_snapshot,uploaded_by,storage_path,original_name,size_bytes)
 values(f.id,p_entry,p_cashier,p_day,sector,uid,p_cashier::text||'/'||p_entry::text||'/'||f.id::text||'.pdf',clean_name,p_size) returning * into f;
 return jsonb_build_object('id',f.id,'path',f.storage_path,'name',f.original_name,'size',f.size_bytes);
end $$;
create or replace function pdi_performance_private.cash_pdf_ready(p_file_id uuid,p_entry_id uuid,p_cashier_id uuid)
returns boolean language sql stable security definer set search_path=pg_catalog
as $$
 select auth.uid() is not null and pdi_performance_private.can_operate_module('cash_daily') and exists(
  select 1 from public.pdi_cash_files f join storage.objects o on o.bucket_id='pdi-cash-pdfs' and o.name=f.storage_path
  where f.id=p_file_id and f.entry_id=p_entry_id and f.cashier_id=p_cashier_id and f.uploaded_by=auth.uid()
   and f.attached_at is null and f.expires_at>statement_timestamp()
   and lower(o.metadata->>'mimetype')='application/pdf' and (o.metadata->>'size')::numeric=f.size_bytes
 )
$$;

create or replace function pdi_performance_private.guard_cash_daily()
returns trigger language plpgsql security invoker set search_path=pg_catalog
as $$
declare p public.profiles%rowtype; uid uuid:=auth.uid(); trusted boolean;
 caller text:=coalesce(current_setting('role',true),'none');
 plan jsonb; canonical jsonb:='[]'; total numeric; amount numeric; n numeric; last_amount numeric; installment_sum numeric:=0;
begin
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
end $$;
create or replace function pdi_performance_private.cash_file_can_read(path text)
returns boolean language sql stable security definer set search_path=pg_catalog
as $$
 select auth.uid() is not null and exists(
   select 1 from public.pdi_cash_files f where f.storage_path=path and (
     (f.attached_at is null and f.uploaded_by=auth.uid() and f.expires_at>statement_timestamp()
       and (f.cashier_id=auth.uid() or pdi_performance_private.can_view_module('cash_daily')))
     or (exists(select 1 from public.pdi_cash_daily d where d.id=f.entry_id and d.pdf_file_id=f.id)
       and (f.cashier_id=auth.uid() or pdi_performance_private.can_view_module('cash_daily')))
     or (f.attached_at is not null and pdi_performance_private.can_audit_module('cash_daily'))
   )
 )
$$;
revoke all on function pdi_performance_private.cash_file_can_read(text) from public,anon;
grant execute on function pdi_performance_private.cash_file_can_read(text) to authenticated;
create or replace function pdi_performance_private.cash_file_can_upload(path text)
returns boolean language sql stable security definer set search_path=pg_catalog
as $$
 select auth.uid() is not null and exists(
   select 1 from public.pdi_cash_files f where f.storage_path=path and f.uploaded_by=auth.uid()
    and f.attached_at is null and f.expires_at>statement_timestamp() and pdi_performance_private.can_collect_performance() and (
      exists(select 1 from public.pdi_cash_daily d where d.id=f.entry_id and d.cashier_id=f.cashier_id and pdi_performance_private.can_correct_sector(d.sector_snapshot))
      or (f.cashier_id=auth.uid() and f.work_date=pdi_performance_private.today_manaus()
        and exists(select 1 from public.profiles p where p.id=auth.uid() and pdi_performance_private.is_cash_position(p.position))
        and not exists(select 1 from public.pdi_cash_daily d where d.cashier_id=f.cashier_id and d.work_date=f.work_date))
    )
 )
$$;
revoke all on function pdi_performance_private.cash_file_can_upload(text) from public,anon;
grant execute on function pdi_performance_private.cash_file_can_upload(text) to authenticated;
drop policy if exists pdi_cash_file_read on public.pdi_cash_files;
create policy pdi_cash_file_read on public.pdi_cash_files for select to authenticated using(pdi_performance_private.cash_file_can_read(storage_path));

create or replace function pdi_performance_private.cash_reserve_pdf(p_entry uuid,p_cashier uuid,p_day date,p_name text,p_size bigint)
returns jsonb language plpgsql security definer set search_path=pg_catalog
as $$
declare uid uuid:=auth.uid(); d public.pdi_cash_daily%rowtype; p public.profiles%rowtype; f public.pdi_cash_files%rowtype; clean_name text; sector text;
begin
 if uid is null then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 if not pdi_performance_private.can_collect_performance() then raise exception 'Gerência e Diretoria não podem enviar anexos ou corrigir fechamentos.' using errcode='42501'; end if;
 if p_entry is null or p_cashier is null or p_day is null then raise exception 'Identificação do fechamento inválida.' using errcode='22023'; end if;
 clean_name:=regexp_replace(btrim(coalesce(p_name,'')),'[[:cntrl:]/\\]','_','g');
 if length(clean_name)<5 or length(clean_name)>180 or clean_name !~* '\.pdf$' or p_size is null or p_size<8 or p_size>10485760 then
   raise exception 'Use um PDF de até 10 MB, com nome de até 180 caracteres.' using errcode='22023'; end if;
 select * into d from public.pdi_cash_daily where id=p_entry;
 if d.id is not null then
   if d.cashier_id<>p_cashier or d.work_date<>p_day or not pdi_performance_private.can_correct_sector(d.sector_snapshot) then
     raise exception 'Você não pode substituir o PDF deste fechamento.' using errcode='42501'; end if;
   sector:=d.sector_snapshot;
 else
   select * into p from public.profiles where id=p_cashier;
   if p_cashier<>uid or p_day<>pdi_performance_private.today_manaus() or not pdi_performance_private.is_cash_position(p.position)
     or exists(select 1 from public.pdi_cash_daily x where x.cashier_id=p_cashier and x.work_date=p_day) then
     raise exception 'Somente a operadora registra o próprio fechamento de hoje.' using errcode='42501'; end if;
   sector:=p.sector;
 end if;
 f.id:=gen_random_uuid();
 insert into public.pdi_cash_files(id,entry_id,cashier_id,work_date,sector_snapshot,uploaded_by,storage_path,original_name,size_bytes)
 values(f.id,p_entry,p_cashier,p_day,sector,uid,p_cashier::text||'/'||p_entry::text||'/'||f.id::text||'.pdf',clean_name,p_size) returning * into f;
 return jsonb_build_object('id',f.id,'path',f.storage_path,'name',f.original_name,'size',f.size_bytes);
end $$;
drop policy if exists pdi_cash_pdf_collector_guard on storage.objects;
create policy pdi_cash_pdf_collector_guard on storage.objects as restrictive for insert to authenticated with check(bucket_id<>'pdi-cash-pdfs' or pdi_performance_private.can_operate_module('cash_daily'));
create or replace function pdi_performance_private.audit_daily_entry()
returns trigger language plpgsql security definer set search_path=pg_catalog
as $$
declare row_data public.pdi_pcp_daily%rowtype; a public.profiles%rowtype;
begin
 if tg_op='DELETE' then row_data:=old; else row_data:=new; end if;
 select * into a from public.profiles where id=auth.uid();
 insert into public.pdi_performance_audit(entry_id,pcp_id,sector_snapshot,action,actor_id,actor_name,actor_role,database_actor,reason,before_data,after_data,area_key_snapshot,access_level_snapshot)
 values(row_data.id,row_data.pcp_id,row_data.sector_snapshot,tg_op,auth.uid(),coalesce(a.full_name,'Operação administrativa'),a.role,
   session_user||'/'||coalesce(current_setting('role',true),'none'),case when tg_op='UPDATE' then new.edit_reason else null end,
   case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
   case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end,'producao',pdi_performance_private.module_level('pcp_m2'));
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
create or replace function pdi_performance_private.audit_cash_daily()
returns trigger language plpgsql security definer set search_path=pg_catalog
as $$
declare d public.pdi_cash_daily%rowtype; a public.profiles%rowtype;
begin
 if tg_op='DELETE' then d:=old; else d:=new; end if;
 select * into a from public.profiles where id=auth.uid();
 if tg_op<>'DELETE' and new.pdf_file_id is not null then update public.pdi_cash_files set attached_at=coalesce(attached_at,clock_timestamp()) where id=new.pdf_file_id; end if;
 insert into public.pdi_cash_audit(entry_id,cashier_id,sector_snapshot,action,actor_id,actor_name,actor_role,database_actor,reason,before_data,after_data,area_key_snapshot,access_level_snapshot)
 values(d.id,d.cashier_id,d.sector_snapshot,tg_op,auth.uid(),coalesce(a.full_name,'Operação administrativa'),a.role,session_user||'/'||coalesce(current_setting('role',true),'none'),
   case when tg_op='UPDATE' then new.edit_reason else null end,
   case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end,
   case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end,'financeiro',pdi_performance_private.module_level('cash_daily'));
 if tg_op='DELETE' then return old; else return new; end if;
end $$;
create or replace function public.pdi_desempenho_context() returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$
 declare people jsonb; manage boolean:=pdi_performance_private.can_view_module('pcp_m2');correction boolean:=pdi_performance_private.can_correct_module('pcp_m2');a public.profiles%rowtype;begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501';end if;
 select * into a from public.profiles where id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'sector',p.sector)order by p.full_name),'[]')into people from public.profiles p where lower(btrim(coalesce(p.position,'')))='pcp' and(p.id=auth.uid() or manage);
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'can_manage',manage,'can_correct',correction,'can_collect',pdi_performance_private.can_collect_module('pcp_m2'),'dashboard_only',manage and not correction,'can_view_logs',pdi_performance_private.can_audit_module('pcp_m2'),'global_access',pdi_performance_private.is_indicator_admin(),'pcps',people,'position',a.position,'is_pcp',lower(btrim(coalesce(a.position,'')))='pcp','is_cashier',pdi_performance_private.is_cash_position(a.position));end $$;
create or replace function public.pdi_cash_context() returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$
 declare people jsonb; manage boolean:=pdi_performance_private.can_view_module('cash_daily');correction boolean:=pdi_performance_private.can_correct_module('cash_daily');a public.profiles%rowtype;begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501';end if;
 select * into a from public.profiles where id=auth.uid();
 select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',p.full_name,'sector',p.sector)order by p.full_name),'[]')into people from public.profiles p where pdi_performance_private.is_cash_position(p.position) and(p.id=auth.uid() or manage);
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'can_manage',manage,'can_correct',correction,'can_collect',pdi_performance_private.can_collect_module('cash_daily'),'dashboard_only',manage and not correction,'can_view_logs',pdi_performance_private.can_audit_module('cash_daily'),'global_access',pdi_performance_private.is_indicator_admin(),'cashiers',people,'position',a.position,'is_pcp',lower(btrim(coalesce(a.position,'')))='pcp','is_cashier',pdi_performance_private.is_cash_position(a.position));end $$;
create or replace function public.pdi_pcp_dashboard(p_start_date date,p_end_date date,p_pcp_id uuid default null)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog
as $$
declare a public.profiles%rowtype; global_access boolean; payload jsonb;
begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 select * into a from public.profiles where id=auth.uid();
 global_access:=coalesce(a.is_master,false) or lower(btrim(coalesce(a.role,''))) in ('master','diretor','diretoria');
 if a.id is null or not pdi_performance_private.can_view_module('pcp_m2') then
   raise exception 'Dashboard restrito à supervisão e gestão.' using errcode='42501';
 end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date) or not isfinite(p_end_date) or p_start_date>p_end_date then
   raise exception 'Selecione um período válido.' using errcode='22023';
 end if;
 -- RLS permanece ativa. O escopo explícito também evita que a exceção de
 -- leitura dos próprios registros inclua um setor antigo de um gestor-PCP.
 with filtered as materialized (
   select d.id,d.pcp_id,d.work_date,d.m2_saved,d.pcp_name_snapshot,d.updated_at
   from public.pdi_pcp_daily d
   where d.work_date between p_start_date and p_end_date
     and (p_pcp_id is null or d.pcp_id=p_pcp_id)
     
 ), grouped as (
   select f.pcp_id,sum(f.m2_saved) as total_m2,count(*) as entries,
     (array_agg(f.pcp_name_snapshot order by f.work_date desc,f.updated_at desc,f.id desc))[1] as name
   from filtered f group by f.pcp_id
 ), ranked as (
   select g.*,dense_rank() over(order by g.total_m2 desc) as place,
     coalesce(round(g.total_m2/nullif(sum(g.total_m2) over(),0)*100,2),0) as share_percent,
     coalesce(round(g.total_m2/nullif(max(g.total_m2) over(),0)*100,2),0) as bar_percent
   from grouped g
 )
 select jsonb_build_object(
   'start_date',p_start_date,'end_date',p_end_date,'pcp_id',p_pcp_id,'updated_at',statement_timestamp(),
   'total_m2',coalesce(sum(r.total_m2),0)::text,
   'pcp_count',count(*),'entry_count',coalesce(sum(r.entries),0),
   'ranking',coalesce(jsonb_agg(jsonb_build_object(
     'pcp_id',r.pcp_id,'name',r.name,'total_m2',r.total_m2::text,'entry_count',r.entries,
     'place',r.place,'share_percent',r.share_percent::text,'bar_percent',r.bar_percent::text
   ) order by r.total_m2 desc,r.name,r.pcp_id),'[]'::jsonb)
 ) into payload from ranked r;
 return payload;
end $$;
create or replace function public.pdi_cash_dashboard(p_start_date date,p_end_date date,p_cashier_id uuid default null)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog
as $$
declare a public.profiles%rowtype; g boolean; result jsonb;
begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 select * into a from public.profiles where id=auth.uid();
 g:=coalesce(a.is_master,false) or lower(btrim(coalesce(a.role,''))) in ('master','diretor','diretoria');
 if a.id is null or not pdi_performance_private.can_view_module('cash_daily') then raise exception 'Dashboard restrito à gestão.' using errcode='42501'; end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date) or not isfinite(p_end_date) or p_start_date>p_end_date then raise exception 'Período inválido.' using errcode='22023'; end if;
 select jsonb_build_object('result_cents',coalesce(sum(d.result_cents),0)::text,'cash_cents',coalesce(sum(d.cash_cents),0)::text,'credit_cash_cents',coalesce(sum(d.credit_cash_cents),0)::text,
 'credit_installment_cents',coalesce(sum(d.credit_installment_cents),0)::text,'debit_cents',coalesce(sum(d.debit_cents),0)::text,'pix_cents',coalesce(sum(d.pix_cents),0)::text,
 'entry_count',count(*),'cashier_count',count(distinct d.cashier_id),'updated_at',statement_timestamp()) into result
 from public.pdi_cash_daily d where d.work_date between p_start_date and p_end_date and (p_cashier_id is null or d.cashier_id=p_cashier_id)
 ;
 return result;
end $$;
create or replace function public.pdi_performance_series(p_module text,p_start_date date,p_end_date date) returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$
 declare result jsonb;begin
 if auth.uid() is null or not pdi_performance_private.can_view_module(p_module) then raise exception 'Indicadores restritos à gestão da área.' using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date) or not isfinite(p_end_date) or p_start_date>p_end_date or p_end_date-p_start_date>1095 then raise exception 'Selecione até 3 anos.' using errcode='22023';end if;
 if p_module='pcp_m2' then
 select jsonb_build_object('days',coalesce(jsonb_agg(jsonb_build_object('date',x.work_date,'value',x.total::text,'entries',x.entries)order by x.work_date),'[]'))into result from(select work_date,sum(m2_saved)total,count(*)entries from public.pdi_pcp_daily where work_date between p_start_date and p_end_date group by work_date)x;
 elsif p_module='cash_daily' then
 select jsonb_build_object('days',coalesce(jsonb_agg(jsonb_build_object('date',x.work_date,'value',x.total::text,'entries',x.entries)order by x.work_date),'[]'))into result from(select work_date,sum(result_cents)total,count(*)entries from public.pdi_cash_daily where work_date between p_start_date and p_end_date group by work_date)x;
 else raise exception 'Módulo sem indicadores configurados.' using errcode='22023';end if;
 return result;end $$;
 revoke all on function public.pdi_performance_series(text,date,date) from public,anon;grant execute on function public.pdi_performance_series(text,date,date) to authenticated;
 notify pgrst,'reload schema';commit;