-- Autorização individual permite coleta sem alterar o cargo cadastrado.
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
   if p.id is null or(not pdi_performance_private.is_cash_position(p.position)and pdi_access_private.mode('cash_daily',new.cashier_id)is distinct from'collect') then raise exception 'Colaborador sem cargo de Caixa.' using errcode='42501'; end if;
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
end $function$;

