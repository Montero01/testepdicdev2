-- Fechamento compromete somente unidades acabadas disponíveis, na mesma transação do pedido.
select pg_advisory_xact_lock(763123,24);
do $$begin if exists(select 1 from public.pdi_eg_records where kind='order'and active and status='closed'and not coalesce((data->>'ready_stock_committed')::boolean,false))then raise exception 'Existem pedidos fechados anteriores sem compromisso de estoque. Revisar esses pedidos antes de aplicar a regra.';end if;end$$;
CREATE OR REPLACE FUNCTION pdi_eg_private.perform_command(p_action text, p_id uuid, p_data jsonb, p_revision integer, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare v_p jsonb:=pdi_eg_private.permissions();v_actor uuid:=auth.uid();v_before jsonb;v_after jsonb;v_rec public.pdi_eg_records%rowtype;v_prod public.pdi_eg_products%rowtype;v_company public.pdi_eg_companies%rowtype;v_id uuid:=coalesce(p_id,gen_random_uuid());v_day date;v_subject uuid;v_data jsonb:=coalesce(p_data,'{}');v_items jsonb:='[]';v_inst jsonb:='[]';v_x jsonb;v_y jsonb;v_pid uuid;v_qty bigint;v_unit bigint;v_total bigint:=0;v_paid bigint;v_cost bigint;v_status text;v_kind text;v_document text;v_n integer;v_num integer;v_due date;v_ledger record;v_existing public.pdi_eg_products%rowtype;
begin
 if v_actor is null or not(v_p->>'allowed')::boolean then raise exception 'Acesso restrito ao Erika Glass autorizado.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(763123,24);
 if length(coalesce(p_reason,''))>300 then raise exception 'Justificativa: máximo de 300 caracteres.'using errcode='22023';end if;
 if jsonb_typeof(v_data) is distinct from 'object' or octet_length(v_data::text)>2000000 then raise exception 'Dados inválidos ou acima do limite.'using errcode='22023';end if;
 if p_action in('company_save','product_save','product_import')then
  if not(v_p->>'can_manage')::boolean then raise exception 'Cadastros e importação são da coordenação e gestão.'using errcode='42501';end if;
  if p_action='product_import'then
   if jsonb_typeof(v_data->'rows') is distinct from 'array' or jsonb_array_length(v_data->'rows')not between 1 and 1000 then raise exception 'Importe de 1 a 1.000 produtos por arquivo.'using errcode='22023';end if;
   if(select count(*)<>count(distinct upper(trim(x->>'sku')))from jsonb_array_elements(v_data->'rows')x)then raise exception 'O arquivo contém SKUs repetidos.'using errcode='22023';end if;
   for v_x in select *from jsonb_array_elements(v_data->'rows')loop
    select *into v_existing from public.pdi_eg_products where lower(sku)=lower(trim(v_x->>'sku'));
    perform pdi_eg_private.command('product_save',coalesce(v_existing.id,gen_random_uuid()),case when v_existing.id is null then v_x else v_x||jsonb_build_object('components',v_existing.components)end,v_existing.revision,'Atualização por importação XLS');
   end loop;
   perform pdi_eg_private.audit('catalog',null,'IMPORT',null,jsonb_build_object('rows',jsonb_array_length(v_data->'rows'),'file',left(v_data->>'file',160)),null);
   return jsonb_build_object('imported',jsonb_array_length(v_data->'rows'));
  elsif p_action='company_save'then
   select *into v_company from public.pdi_eg_companies where id=v_id for update;v_before:=case when found then to_jsonb(v_company)else null end;
   if v_before is not null and(v_company.revision is distinct from p_revision or length(trim(coalesce(p_reason,'')))<10)then raise exception 'Atualize a página e justifique o ajuste em pelo menos 10 caracteres.'using errcode='40001';end if;
   v_document:=nullif(regexp_replace(coalesce(v_data->>'document',''),'\D','','g'),'');
   if v_document is not null and not pdi_eg_private.valid_document(v_document)then raise exception 'CPF/CNPJ inválido.'using errcode='22023';end if;
   if length(trim(coalesce(v_data->>'name','')))not between 2 and 160 or length(coalesce(v_data->>'contact_name',''))>120 or length(coalesce(v_data->>'contact_phone',''))>40 or length(coalesce(v_data->>'contact_email',''))>160 or length(coalesce(v_data->>'address',''))>500 then raise exception 'Confira os dados da empresa e o contato.'using errcode='22023';end if;
   insert into public.pdi_eg_companies(id,name,document,contact_name,contact_phone,contact_email,address,active,created_by,updated_by)values(v_id,trim(v_data->>'name'),v_document,coalesce(v_data->>'contact_name',''),coalesce(v_data->>'contact_phone',''),coalesce(v_data->>'contact_email',''),coalesce(v_data->>'address',''),coalesce((v_data->>'active')::boolean,true),v_actor,v_actor)
   on conflict(id)do update set name=excluded.name,document=excluded.document,contact_name=excluded.contact_name,contact_phone=excluded.contact_phone,contact_email=excluded.contact_email,address=excluded.address,active=excluded.active,revision=pdi_eg_companies.revision+1,updated_at=now(),updated_by=v_actor returning to_jsonb(pdi_eg_companies.*)into v_after;
   perform pdi_eg_private.audit('company',v_id,case when v_before is null then'INSERT'else'UPDATE'end,v_before,v_after,p_reason);return v_after;
  else
   select *into v_prod from public.pdi_eg_products where id=v_id for update;v_before:=case when found then to_jsonb(v_prod)else null end;
   if v_before is not null and(v_prod.revision is distinct from p_revision or length(trim(coalesce(p_reason,'')))<10)then raise exception 'Atualize a página e justifique o ajuste.'using errcode='40001';end if;
   if length(trim(coalesce(v_data->>'name','')))not between 2 and 160 or trim(coalesce(v_data->>'sku',''))!~'^[A-Za-z0-9][A-Za-z0-9._/-]{0,39}$'or coalesce(v_data->>'kind','')not in('item','kit')then raise exception 'Preencha nome, SKU e tipo (item/kit).'using errcode='22023';end if;
   v_items:=coalesce(v_data->'components','[]');if jsonb_typeof(v_items) is distinct from 'array'or jsonb_array_length(v_items)>100 then raise exception 'Composição do kit inválida.'using errcode='22023';end if;
   if v_data->>'kind'='item'and jsonb_array_length(v_items)>0 then raise exception 'Somente kits possuem componentes.'using errcode='22023';end if;
   if(select count(*)<>count(distinct x->>'product_id')from jsonb_array_elements(v_items)x)then raise exception 'Componente repetido no kit.'using errcode='22023';end if;
   for v_x in select *from jsonb_array_elements(v_items)loop
    v_qty:=pdi_eg_private.integer(v_x->'quantity');if v_qty=0 or not exists(select 1 from public.pdi_eg_products where id=(v_x->>'product_id')::uuid and id<>v_id and kind='item'and active)then raise exception 'Cada componente deve ser um item ativo com quantidade positiva.'using errcode='22023';end if;
   end loop;
   v_unit:=case when v_data->'sale_cents'is null or v_data->'sale_cents'='null'::jsonb then null else pdi_eg_private.integer(v_data->'sale_cents',99999999999)end;
   insert into public.pdi_eg_products(id,sku,name,kind,sale_cents,components,active,created_by,updated_by)values(v_id,upper(trim(v_data->>'sku')),trim(v_data->>'name'),v_data->>'kind',v_unit,v_items,coalesce((v_data->>'active')::boolean,true),v_actor,v_actor)
   on conflict(id)do update set sku=excluded.sku,name=excluded.name,kind=excluded.kind,sale_cents=excluded.sale_cents,components=excluded.components,active=excluded.active,revision=pdi_eg_products.revision+1,updated_at=now(),updated_by=v_actor returning to_jsonb(pdi_eg_products.*)into v_after;
   if v_data?'cost_cents'then
    v_cost:=case when v_data->'cost_cents'='null'::jsonb then null else pdi_eg_private.integer(v_data->'cost_cents',99999999999)end;
    if v_before is not null then v_before:=v_before||jsonb_build_object('cost_cents',(select cost_cents from public.pdi_eg_prices where product_id=v_id));end if;
    insert into public.pdi_eg_prices(product_id,cost_cents,updated_by)values(v_id,v_cost,v_actor)on conflict(product_id)do update set cost_cents=excluded.cost_cents,updated_at=now(),updated_by=v_actor;
    v_after:=v_after||jsonb_build_object('cost_cents',v_cost);
   end if;
   perform pdi_eg_private.audit('product',v_id,case when p_revision is null then'INSERT'else'UPDATE'end,v_before,v_after,p_reason);return v_after;
  end if;
 end if;
 if p_action in('report_save','visit_save','order_save','stock_entry','transfer_send','prepare')then
  v_day:=(v_data->>'date')::date;if v_day is null or not isfinite(v_day)or v_day<'2020-01-01'or v_day>pdi_performance_private.today_manaus()+1095 then raise exception 'Informe uma data válida.'using errcode='22023';end if;
  if p_action<>'visit_save'and v_day>pdi_performance_private.today_manaus()then raise exception 'Lançamentos realizados não podem ter data futura.'using errcode='22023';end if;
  v_subject:=coalesce(nullif(v_data->>'subject_id','')::uuid,v_actor);
  if v_subject<>v_actor and not(v_p->>'can_manage')::boolean then raise exception 'Registre apenas seus próprios indicadores.'using errcode='42501';end if;
  if not exists(select 1 from public.profiles where id=v_subject)then raise exception 'Colaborador inválido.'using errcode='22023';end if;
  select *into v_rec from public.pdi_eg_records where id=v_id for update;v_before:=case when found then to_jsonb(v_rec)else null end;
  if v_before is not null and(not v_rec.active or v_rec.revision is distinct from p_revision or length(trim(coalesce(p_reason,'')))<10)then raise exception 'Registro alterado/anulado. Atualize e justifique o ajuste.'using errcode='40001';end if;
  if v_before is not null and(not(v_p->>'can_manage')::boolean and(v_rec.created_by<>v_actor or v_rec.subject_id<>v_actor))then raise exception 'Ajuste fora do seu acesso.'using errcode='42501';end if;
  if p_action='report_save'then
   if not(v_p->>'can_sales')::boolean then raise exception 'Acesso restrito a Vendas E.G.'using errcode='42501';end if;
   v_kind:='report';v_qty:=pdi_eg_private.integer(v_data->'visits');v_n:=pdi_eg_private.integer(v_data->'quotes');v_total:=pdi_eg_private.integer(v_data->'quoted_cents',99999999999);v_items:=v_data->'companies';
   if jsonb_typeof(v_items) is distinct from 'array'or jsonb_array_length(v_items)<>v_qty or v_qty>100 then raise exception 'Selecione uma empresa para cada visita informada (máximo 100).'using errcode='22023';end if;
   if exists(select 1 from jsonb_array_elements_text(v_items)x where not exists(select 1 from public.pdi_eg_companies where id=x::uuid and active))then raise exception 'Empresa visitada inválida.'using errcode='22023';end if;
   if v_n=0 and v_total<>0 then raise exception 'Sem orçamentos, o valor orçado deve ser zero.'using errcode='22023';end if;
   v_data:=jsonb_build_object('visits',v_qty,'companies',v_items,'quotes',v_n,'quoted_cents',v_total,'notes',left(coalesce(v_data->>'notes',''),1500));v_status:='registered';
  elsif p_action='visit_save'then
   if not(v_p->>'can_visit')::boolean then raise exception 'Acesso restrito à promotoria/Vendas E.G.'using errcode='42501';end if;
   v_kind:='visit';if not exists(select 1 from public.pdi_eg_companies where id=(v_data->>'company_id')::uuid and active)then raise exception 'Selecione a loja/empresa da visita.'using errcode='22023';end if;
   v_status:=coalesce(v_data->>'status','planned');if v_status not in('planned','done')or(v_status='done'and v_day>pdi_performance_private.today_manaus())then raise exception 'Visita futura deve permanecer agendada.'using errcode='22023';end if;
   if length(trim(coalesce(v_data->>'activities','')))<3 then raise exception 'Descreva as atividades da visita.'using errcode='22023';end if;
   v_data:=jsonb_build_object('company_id',v_data->>'company_id','location',left(coalesce(v_data->>'location',''),500),'activities',left(v_data->>'activities',2000),'occurrence',left(coalesce(v_data->>'occurrence',''),1500),'notes',left(coalesce(v_data->>'notes',''),1500));
  elsif p_action='order_save'then
   if not(v_p->>'can_sales')::boolean then raise exception 'Acesso restrito a Vendas E.G.'using errcode='42501';end if;
   if v_before is not null then raise exception 'Pedido fechado é preservado: a gerência pode anulá-lo e registrar o pedido correto.'using errcode='22023';end if;
   v_kind:='order';select *into v_company from public.pdi_eg_companies where id=(v_data->>'company_id')::uuid and active;
   if not found or v_company.document is null or not pdi_eg_private.valid_document(v_company.document)then raise exception 'Pedido fechado exige empresa e CPF/CNPJ válidos no cadastro.'using errcode='22023';end if;
   if jsonb_typeof(v_data->'items') is distinct from 'array'or jsonb_array_length(v_data->'items')not between 1 and 200 then raise exception 'Inclua de 1 a 200 itens no pedido.'using errcode='22023';end if;
   for v_x in select *from jsonb_array_elements(v_data->'items')loop
    select *into v_prod from public.pdi_eg_products where id=(v_x->>'product_id')::uuid and active;if not found then raise exception 'Produto não cadastrado ou inativo.'using errcode='22023';end if;
    v_qty:=pdi_eg_private.integer(v_x->'quantity');v_unit:=pdi_eg_private.integer(v_x->'unit_cents',99999999999);if v_qty=0 then raise exception 'Quantidade do item deve ser positiva.'using errcode='22023';end if;
    v_total:=v_total+v_qty*v_unit;if v_total>99999999999 then raise exception 'Pedido acima do limite permitido.'using errcode='22023';end if;
    v_items:=v_items||jsonb_build_array(jsonb_build_object('product_id',v_prod.id,'sku',v_prod.sku,'name',v_prod.name,'kind',v_prod.kind,'quantity',v_qty,'unit_cents',v_unit,'total_cents',v_qty*v_unit));
   end loop;
   for v_x in select jsonb_build_object('product_id',x->>'product_id','quantity',sum((x->>'quantity')::bigint))from jsonb_array_elements(v_items)x group by x->>'product_id'loop
    v_pid:=(v_x->>'product_id')::uuid;v_qty:=(v_x->>'quantity')::bigint;
    select coalesce(sum(quantity),0)into v_paid from public.pdi_eg_stock_moves where product_id=v_pid and location='ready';
    if v_qty>v_paid then raise exception 'Estoque de acabados insuficiente para %. Disponível: %; solicitado: %. Registre o preparo antes da venda.',(select name from public.pdi_eg_products where id=v_pid),v_paid,v_qty using errcode='23514';end if;
   end loop;
   if v_total<=0 then raise exception 'O valor total do pedido deve ser positivo.'using errcode='22023';end if;
   if coalesce(v_data->>'payment','')not in('cash','boleto')then raise exception 'Selecione à vista ou boleto.'using errcode='22023';end if;
   if jsonb_typeof(v_data->'installments') is distinct from 'array'or jsonb_array_length(v_data->'installments')not between 1 and 60 then raise exception 'Defina de 1 a 60 parcelas.'using errcode='22023';end if;
   if v_data->>'payment'='cash'and jsonb_array_length(v_data->'installments')<>1 then raise exception 'À vista possui uma única previsão de recebimento.'using errcode='22023';end if;
   v_paid:=0;v_num:=0;for v_x in select *from jsonb_array_elements(v_data->'installments')loop
    v_num:=v_num+1;v_unit:=pdi_eg_private.integer(v_x->'amount_cents',99999999999);v_due:=(v_x->>'date')::date;if v_unit<=0 or v_due is null or not isfinite(v_due)or v_due<v_day then raise exception 'Parcela deve ter valor positivo e vencimento a partir do pedido.'using errcode='22023';end if;
    if v_data->>'payment'='cash'and v_due<>v_day then raise exception 'À vista deve vencer na data do pedido.'using errcode='22023';end if;
    v_inst:=v_inst||jsonb_build_array(jsonb_build_object('id',gen_random_uuid(),'number',v_num,'date',v_due,'amount_cents',v_unit));v_paid:=v_paid+v_unit;
   end loop;
   if v_paid<>v_total then raise exception 'A soma dos boletos/parcelas deve ser igual ao total do pedido.'using errcode='22023';end if;
   v_data:=jsonb_build_object('company_id',v_company.id,'company_name',v_company.name,'document',v_company.document,'items',v_items,'total_cents',v_total,'quoted_cents',pdi_eg_private.integer(coalesce(v_data->'quoted_cents',to_jsonb(v_total)),99999999999),'payment',v_data->>'payment','installments',v_inst,'ready_stock_committed',true,'notes',left(coalesce(v_data->>'notes',''),1500));v_status:='closed';
  elsif p_action in('stock_entry','transfer_send')then
   if not(v_p->>'can_stock')::boolean then raise exception 'Entrada/saída é do Jackson e da gerência/Diretoria.'using errcode='42501';end if;
   if v_before is not null then raise exception 'Movimentação de estoque não pode ser sobrescrita. Use anulação gerencial.'using errcode='22023';end if;
   v_kind:=case when p_action='stock_entry'then'stock_entry'else'transfer'end;v_status:=case when p_action='stock_entry'then'received'else'dispatched'end;
   if jsonb_typeof(v_data->'items') is distinct from 'array'or jsonb_array_length(v_data->'items')not between 1 and 200 then raise exception 'Inclua os itens e suas quantidades.'using errcode='22023';end if;
   for v_x in select *from jsonb_array_elements(v_data->'items')loop
    select *into v_prod from public.pdi_eg_products where id=(v_x->>'product_id')::uuid and active;if not found then raise exception 'Produto inválido.'using errcode='22023';end if;
    v_qty:=pdi_eg_private.integer(v_x->'quantity');if v_qty=0 then raise exception 'Quantidade deve ser positiva.'using errcode='22023';end if;
    v_items:=v_items||jsonb_build_array(jsonb_build_object('product_id',v_prod.id,'name',v_prod.name,'sku',v_prod.sku,'quantity',v_qty));
   end loop;
   v_data:=jsonb_build_object('items',v_items,'notes',left(coalesce(v_data->>'notes',''),1500));
  else
   if not(v_p->>'can_production')::boolean then raise exception 'Preparo restrito à Produção E.G. e coordenação.'using errcode='42501';end if;
   if v_before is not null then raise exception 'Preparo não pode ser sobrescrito. Use anulação gerencial.'using errcode='22023';end if;
   v_kind:='preparation';v_status:='ready';select *into v_prod from public.pdi_eg_products where id=(v_data->>'product_id')::uuid and active;if not found then raise exception 'Selecione um produto ativo.'using errcode='22023';end if;
   v_qty:=pdi_eg_private.integer(v_data->'quantity');if v_qty=0 then raise exception 'Informe quantos produtos/kits estão acabados.'using errcode='22023';end if;
   if v_prod.kind='kit'and jsonb_array_length(v_prod.components)=0 then raise exception 'Defina a composição do kit antes do preparo.'using errcode='22023';end if;
   v_data:=jsonb_build_object('product_id',v_prod.id,'product_name',v_prod.name,'quantity',v_qty,'kind',v_prod.kind,'components',v_prod.components,'notes',left(coalesce(v_data->>'notes',''),1500));
  end if;
  if v_before is not null and v_rec.kind<>v_kind then raise exception 'Tipo de registro incompatível.'using errcode='22023';end if;
  insert into public.pdi_eg_records(id,kind,work_date,company_id,subject_id,status,data,created_by,updated_by)values(v_id,v_kind,v_day,nullif(v_data->>'company_id','')::uuid,v_subject,v_status,v_data,v_actor,v_actor)
  on conflict(id)do update set work_date=excluded.work_date,company_id=excluded.company_id,subject_id=excluded.subject_id,status=excluded.status,data=excluded.data,revision=pdi_eg_records.revision+1,updated_at=now(),updated_by=v_actor returning to_jsonb(pdi_eg_records.*)into v_after;
  if p_action='order_save'then for v_x in select *from jsonb_array_elements(v_items)loop perform pdi_eg_private.move(v_id,(v_x->>'product_id')::uuid,'ready',-(v_x->>'quantity')::bigint);end loop;end if;
  if p_action in('stock_entry','transfer_send')then for v_x in select *from jsonb_array_elements(v_items)loop perform pdi_eg_private.move(v_id,(v_x->>'product_id')::uuid,'warehouse',(v_x->>'quantity')::bigint*case when p_action='stock_entry'then 1 else -1 end);end loop;end if;
  if p_action='prepare'then
   if v_prod.kind='item'then perform pdi_eg_private.move(v_id,v_prod.id,'raw',-v_qty);
   else for v_x in select *from jsonb_array_elements(v_prod.components)loop perform pdi_eg_private.move(v_id,(v_x->>'product_id')::uuid,'raw',-v_qty*(v_x->>'quantity')::bigint);end loop;end if;
   perform pdi_eg_private.move(v_id,v_prod.id,'ready',v_qty);
  end if;
  perform pdi_eg_private.audit('record',v_id,case when v_before is null then'INSERT'else'UPDATE'end,v_before,v_after,p_reason);return v_after;
 end if;
 select *into v_rec from public.pdi_eg_records where id=v_id for update;
 if p_action in('transfer_receive','order_deliver','receipt_add','occurrence_add','occurrence_resolve','void')then
  if not found or not v_rec.active then raise exception 'Registro não encontrado ou já anulado.'using errcode='22023';end if;
  if p_revision is distinct from v_rec.revision then raise exception 'Outra pessoa alterou o registro. Atualize a página.'using errcode='40001';end if;
  v_before:=to_jsonb(v_rec);
 end if;
 if p_action='transfer_receive'then
  if not(v_p->>'can_production')::boolean then raise exception 'Recebimento é da Adriane/Produção E.G.'using errcode='42501';end if;
  if v_rec.kind<>'transfer'or v_rec.status<>'dispatched'or coalesce((v_data->>'checked')::boolean,false)<>true then raise exception 'Confirme que conferiu e recebeu todos os itens da transferência pendente.'using errcode='22023';end if;
  v_day:=(v_data->>'date')::date;if v_day is null or not isfinite(v_day)or v_day<v_rec.work_date or v_day>pdi_performance_private.today_manaus()then raise exception 'A data de recebimento deve ficar entre a saída e hoje.'using errcode='22023';end if;
  for v_x in select *from jsonb_array_elements(v_rec.data->'items')loop perform pdi_eg_private.move(v_id,(v_x->>'product_id')::uuid,'raw',(v_x->>'quantity')::bigint);end loop;
  update public.pdi_eg_records set status='received',data=data||jsonb_build_object('received_on',v_day,'received_by',v_actor,'checked',true),revision=revision+1,updated_by=v_actor,updated_at=now()where id=v_id returning to_jsonb(pdi_eg_records.*)into v_after;
  if length(trim(coalesce(v_data->>'occurrence','')))>0 then
   insert into public.pdi_eg_records(kind,work_date,subject_id,parent_id,status,data,created_by,updated_by)values('occurrence',v_day,v_actor,v_id,'open',jsonb_build_object('description',left(v_data->>'occurrence',2000),'source','receipt'),v_actor,v_actor)returning id into v_pid;
   perform pdi_eg_private.audit('occurrence',v_pid,'INSERT',null,jsonb_build_object('transfer_id',v_id,'description',left(v_data->>'occurrence',2000)),null);
  end if;
 elsif p_action='order_deliver'then
  if not(v_p->>'can_manage')::boolean then raise exception 'A coordenação/gestão confirma a entrega dos pedidos.'using errcode='42501';end if;
  if v_rec.kind<>'order'or v_rec.status<>'closed'then raise exception 'Pedido já entregue ou inválido.'using errcode='22023';end if;
  v_day:=(v_data->>'date')::date;if v_day is null or not isfinite(v_day)or v_day<v_rec.work_date or v_day>pdi_performance_private.today_manaus()then raise exception 'Data de entrega inválida.'using errcode='22023';end if;
  if not coalesce((v_rec.data->>'ready_stock_committed')::boolean,false)then for v_x in select *from jsonb_array_elements(v_rec.data->'items')loop perform pdi_eg_private.move(v_id,(v_x->>'product_id')::uuid,'ready',-(v_x->>'quantity')::bigint);end loop;end if;
  update public.pdi_eg_records set status='delivered',data=data||jsonb_build_object('delivered_on',v_day,'delivered_by',v_actor),revision=revision+1,updated_by=v_actor,updated_at=now()where id=v_id returning to_jsonb(pdi_eg_records.*)into v_after;
 elsif p_action='receipt_add'then
  if not(v_p->>'can_finance')::boolean then raise exception 'Baixas são da coordenação e gestão.'using errcode='42501';end if;
  if v_rec.kind<>'order'then raise exception 'Selecione um pedido.'using errcode='22023';end if;
  v_day:=(v_data->>'date')::date;if v_day is null or not isfinite(v_day)or v_day<v_rec.work_date or v_day>pdi_performance_private.today_manaus()then raise exception 'Informe a data efetiva de recebimento.'using errcode='22023';end if;
  select value into v_x from jsonb_array_elements(v_rec.data->'installments')where value->>'id'=v_data->>'installment_id';if v_x is null then raise exception 'Parcela não encontrada.'using errcode='22023';end if;
  v_unit:=pdi_eg_private.integer(v_data->'amount_cents',99999999999);select coalesce(sum((data->>'amount_cents')::bigint),0)into v_paid from public.pdi_eg_records where active and kind='receipt'and parent_id=v_id and data->>'installment_id'=v_data->>'installment_id';
  if v_unit<=0 or v_paid+v_unit>(v_x->>'amount_cents')::bigint then raise exception 'O recebimento deve ser positivo e não pode superar o saldo da parcela.'using errcode='22023';end if;
  insert into public.pdi_eg_records(kind,work_date,company_id,subject_id,parent_id,status,data,created_by,updated_by)values('receipt',v_day,v_rec.company_id,v_rec.subject_id,v_id,'paid',jsonb_build_object('installment_id',v_data->>'installment_id','amount_cents',v_unit,'notes',left(coalesce(v_data->>'notes',''),1000)),v_actor,v_actor)returning to_jsonb(pdi_eg_records.*)into v_after;
  perform pdi_eg_private.audit('record',(v_after->>'id')::uuid,'INSERT',null,v_after,null);return v_after;
 elsif p_action='occurrence_add'then
  if not((v_p->>'can_production')::boolean or(v_p->>'can_stock')::boolean)or v_rec.kind<>'transfer'then raise exception 'Ocorrência restrita a uma transferência do E.G.'using errcode='42501';end if;
  if length(trim(coalesce(v_data->>'description','')))<5 then raise exception 'Descreva a ocorrência com pelo menos 5 caracteres.'using errcode='22023';end if;
  insert into public.pdi_eg_records(kind,work_date,subject_id,parent_id,status,data,created_by,updated_by)values('occurrence',pdi_performance_private.today_manaus(),v_actor,v_id,'open',jsonb_build_object('description',left(v_data->>'description',2000),'source','transfer'),v_actor,v_actor)returning to_jsonb(pdi_eg_records.*)into v_after;
  perform pdi_eg_private.audit('occurrence',(v_after->>'id')::uuid,'INSERT',null,v_after,null);return jsonb_build_object('id',v_after->>'id','registered',true);
 elsif p_action='occurrence_resolve'then
  if not(v_p->>'can_occurrences')::boolean or v_rec.kind<>'occurrence'then raise exception 'Ocorrências são da Adriane, Jackson e gestão.'using errcode='42501';end if;
  if length(trim(coalesce(v_data->>'resolution','')))<5 then raise exception 'Informe a solução/encaminhamento.'using errcode='22023';end if;
  update public.pdi_eg_records set status='resolved',data=data||jsonb_build_object('resolution',left(v_data->>'resolution',2000),'resolved_by',v_actor,'resolved_at',now()),revision=revision+1,updated_at=now(),updated_by=v_actor where id=v_id returning to_jsonb(pdi_eg_records.*)into v_after;
 elsif p_action='void'then
  if not(v_p->>'can_delete')::boolean then raise exception 'Exclusão/anulação restrita à gerência e Diretoria.'using errcode='42501';end if;
  if length(trim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique a exclusão em 10 a 300 caracteres.'using errcode='22023';end if;
  if v_rec.kind='order'and exists(select 1 from public.pdi_eg_records where kind='receipt'and parent_id=v_id and active)then raise exception 'Anule primeiro as baixas do pedido para preservar o financeiro.'using errcode='23514';end if;
  for v_ledger in select *from public.pdi_eg_stock_moves where record_id=v_id and not reversal order by quantity desc loop perform pdi_eg_private.move(v_id,v_ledger.product_id,v_ledger.location,-v_ledger.quantity,true);end loop;
  update public.pdi_eg_records set active=false,status='cancelled',revision=revision+1,updated_at=now(),updated_by=v_actor where id=v_id returning to_jsonb(pdi_eg_records.*)into v_after;
 else raise exception 'Operação E.G. inválida.'using errcode='22023';end if;
 perform pdi_eg_private.audit('record',v_id,case when p_action='void'then'DELETE'else upper(p_action)end,v_before,v_after,p_reason);return v_after;
end;
$function$;
notify pgrst,'reload schema';

