-- Executar SOMENTE após instalar erika_glass.sql, como postgres no SQL editor.
-- Não altera profiles. Todo cadastro, lançamento, movimento e auditoria deste teste
-- fica dentro da transação e é descartado pelo ROLLBACK final.
-- Se algum ASSERT falhar, a transação fica abortada: execute ROLLBACK antes de sair.
begin;
set local statement_timeout='45s';
set local lock_timeout='5s';
set local plpgsql.check_asserts=on;
set local role authenticated;
do $test$
declare
 master_id uuid; coordinator_id uuid; stock_id uuid; denied_id uuid;
 company_id uuid:=gen_random_uuid(); item_id uuid:=gen_random_uuid(); kit_id uuid:=gen_random_uuid();
 entry_id uuid:=gen_random_uuid(); transfer_id uuid:=gen_random_uuid(); prep_id uuid:=gen_random_uuid();
 order_id uuid:=gen_random_uuid(); invalid_id uuid:=gen_random_uuid(); occurrence_id uuid;
 r jsonb; cached jsonb; item_payload jsonb; item_request uuid:=gen_random_uuid(); receipt_request uuid:=gen_random_uuid(); ctx jsonb; installment1 text; installment2 text; receipt1 uuid; receipt2 uuid; receipt3 uuid;
 today date; doc text; total integer; digit integer; i integer; j integer;
 token text:=upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
begin
 select id into strict master_id from public.profiles where lower(full_name)='gabriel m. monteiro';
 select id into strict coordinator_id from public.profiles where lower(full_name)='adriane pinheiro campos';
 select id into strict stock_id from public.profiles where lower(full_name)='jackson f. maia';
 select id into strict denied_id from public.profiles where lower(full_name)='vitor amaral';
 -- Claims correspondem somente aos perfis existentes, sem criar usuários de Auth.
 perform set_config('request.jwt.claim.sub',denied_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',denied_id,'role','authenticated')::text,true);
 ctx:=public.pdi_eg_context(); assert not(ctx->>'allowed')::boolean,'Vitor não deve acessar o E.G.';
 begin perform public.pdi_eg_command('company_save',company_id,'{"name":"QA negado"}');raise exception 'FALHOU: Vitor criou cadastro';exception when insufficient_privilege then null;end;
 assert not exists(select 1 from public.pdi_eg_products),'Usuário externo não pode enumerar catálogo E.G.';
 assert not has_function_privilege('anon','public.pdi_eg_command(text,uuid,jsonb,integer,text,uuid)','EXECUTE'),'anon não pode chamar command';
 assert not has_function_privilege('authenticated','pdi_eg_private.move(uuid,uuid,text,bigint,boolean)','EXECUTE'),'Helper de estoque não pode ser chamado diretamente';
 assert not has_table_privilege('authenticated','public.pdi_eg_records','INSERT'),'Gravação direta de registros deve ser bloqueada';
 begin insert into public.pdi_eg_records(kind,work_date,subject_id,created_by,updated_by)values('report',current_date,denied_id,denied_id,denied_id);raise exception 'FALHOU: INSERT direto';exception when insufficient_privilege then null;end;

 perform set_config('request.jwt.claim.sub',coordinator_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',coordinator_id,'role','authenticated')::text,true);
 ctx:=public.pdi_eg_context();today:=(ctx->>'today')::date;
 assert(ctx->>'can_manage')::boolean and(ctx->>'can_finance')::boolean and(ctx->>'can_production')::boolean,'Adriane precisa coordenar, preparar e registrar baixas';
 assert not(ctx->>'can_delete')::boolean,'Coordenação não deve receber exclusão gerencial';
 assert not(ctx->>'can_stock')::boolean,'Entrada/saída pertence ao estoque e gestão global';
 -- CPF sintético com dígitos verificadores, exclusivo dentro desta transação.
 loop
  doc:=lpad(floor(random()*999999999)::bigint::text,9,'0');
  if doc=repeat(left(doc,1),9)then continue;end if;
  for j in 1..2 loop total:=0;for i in 1..(8+j)loop total:=total+substr(doc,i,1)::integer*(10+j-i);end loop;digit:=(total*10)%11;if digit=10 then digit:=0;end if;doc:=doc||digit::text;end loop;
  exit when not exists(select 1 from public.pdi_eg_companies where document=doc);
 end loop;
 r:=public.pdi_eg_command('company_save',company_id,jsonb_build_object('name','QA EG '||token,'document',doc));
 assert(r->>'id')::uuid=company_id and(r->>'document')=doc,'Cadastro de empresa não preservou CPF válido';
 begin perform public.pdi_eg_command('company_save',invalid_id,'{"name":"QA documento inválido","document":"11111111111"}');raise exception 'FALHOU: aceitou CPF inválido';exception when invalid_parameter_value then null;end;
 item_payload:=jsonb_build_object('sku','QA-I-'||token,'name','QA item '||token,'kind','item','sale_cents',1000,'cost_cents',300);
 r:=public.pdi_eg_command('product_save',item_id,item_payload,null,null,item_request);
 cached:=public.pdi_eg_command('product_save',item_id,item_payload,null,null,item_request);
 assert cached=r and(cached->>'revision')::integer=1,'Reenvio deve reutilizar resposta sem duplicar cadastro/auditoria';
 begin perform public.pdi_eg_command('product_save',item_id,item_payload||'{"sale_cents":1001}',null,null,item_request);raise exception 'FALHOU: reutilizou chave com payload diferente';exception when invalid_parameter_value then null;end;
 -- Revogação fica invisível às outras sessões: altera somente pdi_eg_access
 -- nesta transação, nunca profiles, e é desfeita/restaurada antes do rollback.
 perform set_config('role','none',true);
 delete from public.pdi_eg_access where profile_id=coordinator_id and access_role='coordinator';
 perform set_config('role','authenticated',true);
 assert not(public.pdi_eg_context()->>'allowed')::boolean,'Revogação temporária deveria remover acesso';
 begin perform public.pdi_eg_command('product_save',item_id,item_payload,null,null,item_request);raise exception 'FALHOU: cache expôs custo após revogação';exception when insufficient_privilege then null;end;
 perform set_config('role','none',true);
 insert into public.pdi_eg_access(profile_id,access_role)values(coordinator_id,'coordinator');
 perform set_config('role','authenticated',true);

 assert(r->>'cost_cents')::bigint=300,'Custo precisa ser preservado para a coordenação';
 r:=public.pdi_eg_command('product_save',kit_id,jsonb_build_object('sku','QA-K-'||token,'name','QA kit '||token,'kind','kit','sale_cents',2500,'components',jsonb_build_array(jsonb_build_object('product_id',item_id,'quantity',2))));
 begin perform public.pdi_eg_command('product_save',item_id,jsonb_build_object('sku','QA-I-'||token,'name','QA revisão obsoleta','kind','item'),99,'Teste de revisão obsoleta');raise exception 'FALHOU: revisão obsoleta de produto';exception when serialization_failure then null;end;
 begin perform public.pdi_eg_command('stock_entry',invalid_id,jsonb_build_object('date',today,'items',jsonb_build_array(jsonb_build_object('product_id',item_id,'quantity',10))));raise exception 'FALHOU: coordenação executou entrada de estoque';exception when insufficient_privilege then null;end;

 perform set_config('request.jwt.claim.sub',stock_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',stock_id,'role','authenticated')::text,true);
 ctx:=public.pdi_eg_context();assert(ctx->>'can_stock')::boolean,'Jackson precisa movimentar estoque';
 assert not(ctx->>'can_finance')::boolean and not(ctx->>'can_delete')::boolean and not(ctx->>'can_manage')::boolean,'Falha de separação: Jackson herdou gestão/financeiro/exclusão por outra área';
 assert not exists(select 1 from public.pdi_eg_prices where product_id=item_id),'Estoque não pode ler preços de custo';
 assert not exists(select 1 from public.pdi_eg_audit where entity_id=item_id),'Estoque não pode acessar auditoria com custos';
 begin perform public.pdi_eg_command('product_save',gen_random_uuid(),'{"sku":"QA-NEGADO","name":"QA cadastro negado","kind":"item"}');raise exception 'FALHOU: estoque editou catálogo';exception when insufficient_privilege then null;end;
 r:=public.pdi_eg_command('stock_entry',entry_id,jsonb_build_object('date',today,'items',jsonb_build_array(jsonb_build_object('product_id',item_id,'quantity',10))));
 assert(select coalesce(sum(quantity),0)=10 from public.pdi_eg_stock_moves where product_id=item_id and location='warehouse'),'Entrada deve gerar 10 no depósito';
 begin perform public.pdi_eg_command('transfer_send',invalid_id,jsonb_build_object('date',today,'items',jsonb_build_array(jsonb_build_object('product_id',item_id,'quantity',11))));raise exception 'FALHOU: saldo negativo';exception when check_violation then null;end;
 assert not exists(select 1 from public.pdi_eg_records where id=invalid_id),'Falha de saldo deve reverter registro e movimentos parciais';
 r:=public.pdi_eg_command('transfer_send',transfer_id,jsonb_build_object('date',today,'items',jsonb_build_array(jsonb_build_object('product_id',item_id,'quantity',8))));
 assert r->>'status'='dispatched','Saída precisa ficar pendente de conferência';
 assert(select coalesce(sum(quantity),0)=2 from public.pdi_eg_stock_moves where product_id=item_id and location='warehouse'),'Transferência deve retirar oito do depósito';
 assert(select coalesce(sum(quantity),0)=0 from public.pdi_eg_stock_moves where product_id=item_id and location='raw'),'Não deve creditar matéria-prima antes de conferência';
 begin perform public.pdi_eg_command('transfer_receive',transfer_id,jsonb_build_object('date',today,'checked',true),1);raise exception 'FALHOU: remetente estoque confirmou recebimento E.G.';exception when insufficient_privilege then null;end;

 perform set_config('request.jwt.claim.sub',coordinator_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',coordinator_id,'role','authenticated')::text,true);
 begin perform public.pdi_eg_command('transfer_receive',transfer_id,jsonb_build_object('date',today,'checked',false),1);raise exception 'FALHOU: recebimento sem conferência';exception when invalid_parameter_value then null;end;
 r:=public.pdi_eg_command('transfer_receive',transfer_id,jsonb_build_object('date',today,'checked',true,'occurrence','QA conferência com ocorrência registrada'),1);
 assert r->>'status'='received' and(r->>'revision')::int=2,'Recebimento precisa avançar estado/revisão';
 assert(select coalesce(sum(quantity),0)=8 from public.pdi_eg_stock_moves where product_id=item_id and location='raw'),'Conferência deve creditar oito em bruto';
 begin perform public.pdi_eg_command('transfer_receive',transfer_id,jsonb_build_object('date',today,'checked',true),1);raise exception 'FALHOU: ação com revisão antiga';exception when serialization_failure then null;end;
 begin perform public.pdi_eg_command('order_save',invalid_id,jsonb_build_object('date',today,'company_id',company_id,'payment','cash','items',jsonb_build_array(jsonb_build_object('product_id',item_id,'quantity',1,'unit_cents',1000)),'installments',jsonb_build_array(jsonb_build_object('date',today,'amount_cents',1000))));raise exception 'FALHOU: comercializou matéria-prima sem preparo';exception when check_violation then null;end;
 r:=public.pdi_eg_command('prepare',prep_id,jsonb_build_object('date',today,'product_id',kit_id,'quantity',3));
 assert(select coalesce(sum(quantity),0)=2 from public.pdi_eg_stock_moves where product_id=item_id and location='raw'),'Três kits devem consumir seis componentes';
 assert(select coalesce(sum(quantity),0)=3 from public.pdi_eg_stock_moves where product_id=kit_id and location='ready'),'Preparo deve produzir três kits acabados';
 begin perform public.pdi_eg_command('prepare',invalid_id,jsonb_build_object('date',today,'product_id',kit_id,'quantity',2));raise exception 'FALHOU: preparo sem matéria-prima';exception when check_violation then null;end;
 assert not exists(select 1 from public.pdi_eg_records where id=invalid_id),'Preparo inválido deve ser atômico';
 begin perform public.pdi_eg_command('order_save',invalid_id,jsonb_build_object('date',today,'company_id',company_id,'payment','boleto','items',jsonb_build_array(jsonb_build_object('product_id',kit_id,'quantity',2,'unit_cents',2500)),'installments',jsonb_build_array(jsonb_build_object('date',today,'amount_cents',4999))));raise exception 'FALHOU: parcelas não fecham total';exception when invalid_parameter_value then null;end;
 r:=public.pdi_eg_command('order_save',order_id,jsonb_build_object('date',today,'company_id',company_id,'payment','boleto','items',jsonb_build_array(jsonb_build_object('product_id',kit_id,'quantity',2,'unit_cents',2500)),'installments',jsonb_build_array(jsonb_build_object('date',today,'amount_cents',2500),jsonb_build_object('date',today+1,'amount_cents',2500))));
 assert r->>'status'='closed' and(r->'data'->>'total_cents')::bigint=5000,'Pedido precisa fechar em 5.000 centavos';
 installment1:=r->'data'->'installments'->0->>'id';installment2:=r->'data'->'installments'->1->>'id';
 assert(select coalesce(sum(quantity),0)=1 from public.pdi_eg_stock_moves where product_id=kit_id and location='ready'),'Fechar pedido compromete duas unidades acabadas';
 assert(r->'data'->>'ready_stock_committed')::boolean;
 begin perform public.pdi_eg_command('order_save',invalid_id,jsonb_build_object('date',today,'company_id',company_id,'payment','cash','items',jsonb_build_array(jsonb_build_object('product_id',kit_id,'quantity',1,'unit_cents',2500),jsonb_build_object('product_id',kit_id,'quantity',1,'unit_cents',2500)),'installments',jsonb_build_array(jsonb_build_object('date',today,'amount_cents',5000))));raise exception 'FALHOU: ignorou soma das linhas ou vendeu unidades comprometidas';exception when check_violation then null;end;
 assert not exists(select 1 from public.pdi_eg_records where id=invalid_id),'Pedido sem saldo é integralmente recusado';
 r:=public.pdi_eg_command('receipt_add',order_id,jsonb_build_object('date',today,'installment_id',installment1,'amount_cents',2000),1,null,receipt_request);receipt1:=(r->>'id')::uuid;
 cached:=public.pdi_eg_command('receipt_add',order_id,jsonb_build_object('date',today,'installment_id',installment1,'amount_cents',2000),1,null,receipt_request);
 assert cached=r,'Reenvio da baixa precisa devolver a mesma resposta';
 assert(select count(*)=1 from public.pdi_eg_records where kind='receipt'and parent_id=order_id and active),'Reenvio de rede não pode duplicar recebimento';
 begin perform public.pdi_eg_command('receipt_add',order_id,jsonb_build_object('date',today,'installment_id',installment1,'amount_cents',501),1);raise exception 'FALHOU: excedeu saldo da parcela';exception when invalid_parameter_value then null;end;
 r:=public.pdi_eg_command('receipt_add',order_id,jsonb_build_object('date',today,'installment_id',installment1,'amount_cents',500),1);receipt2:=(r->>'id')::uuid;
 r:=public.pdi_eg_command('receipt_add',order_id,jsonb_build_object('date',today,'installment_id',installment2,'amount_cents',2500),1);receipt3:=(r->>'id')::uuid;
 assert(select sum((data->>'amount_cents')::bigint)=5000 from public.pdi_eg_records where kind='receipt' and parent_id=order_id and active),'Baixas parciais devem totalizar 5.000';
 r:=public.pdi_eg_command('order_deliver',order_id,jsonb_build_object('date',today),1);
 assert r->>'status'='delivered','Entrega deve avançar estado';
 assert(select coalesce(sum(quantity),0)=1 from public.pdi_eg_stock_moves where product_id=kit_id and location='ready'),'Entrega deve retirar dois kits';
 begin perform public.pdi_eg_command('void',order_id,'{}',2,'Teste de anulação negada à coordenação');raise exception 'FALHOU: coordenação excluiu';exception when insufficient_privilege then null;end;

 perform set_config('request.jwt.claim.sub',stock_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',stock_id,'role','authenticated')::text,true);
 assert not exists(select 1 from public.pdi_eg_records where id in(receipt1,receipt2,receipt3)),'Estoque não pode consultar baixas';
 begin perform public.pdi_eg_command('receipt_add',order_id,jsonb_build_object('date',today,'installment_id',installment2,'amount_cents',1),2);raise exception 'FALHOU: estoque registrou baixa';exception when insufficient_privilege then null;end;
 select id into strict occurrence_id from public.pdi_eg_records where kind='occurrence' and parent_id=transfer_id and active;
 r:=public.pdi_eg_command('occurrence_resolve',occurrence_id,jsonb_build_object('resolution','QA solução registrada pelo estoque'),1);assert r->>'status'='resolved','Estoque precisa resolver ocorrências';

 perform set_config('request.jwt.claim.sub',master_id::text,true);
 perform set_config('request.jwt.claims',jsonb_build_object('sub',master_id,'role','authenticated')::text,true);
 assert(public.pdi_eg_context()->>'can_delete')::boolean,'Gabriel precisa anular com justificativa';
 begin perform public.pdi_eg_command('void',order_id,'{}',2,'QA ordem tem baixas ativas');raise exception 'FALHOU: anulou pedido com baixas';exception when check_violation then null;end;
 begin perform public.pdi_eg_command('void',prep_id,'{}',1,'QA produto já consumido na entrega');raise exception 'FALHOU: estorno gerou estoque negativo';exception when check_violation then null;end;
 begin perform public.pdi_eg_command('void',transfer_id,'{}',2,'QA matéria-prima ainda consumida');raise exception 'FALHOU: desfez transferência consumida';exception when check_violation then null;end;
 perform public.pdi_eg_command('void',receipt1,'{}',1,'QA reversão de baixa para conferir pedido');
 perform public.pdi_eg_command('void',receipt2,'{}',1,'QA reversão de baixa para conferir pedido');
 perform public.pdi_eg_command('void',receipt3,'{}',1,'QA reversão de baixa para conferir pedido');
 perform public.pdi_eg_command('void',order_id,'{}',2,'QA reversão do pedido após anular baixas');
 assert(select coalesce(sum(quantity),0)=3 from public.pdi_eg_stock_moves where product_id=kit_id and location='ready'),'Anular entrega precisa devolver dois kits';
 perform public.pdi_eg_command('void',prep_id,'{}',1,'QA reversão do preparo após desfazer pedido');
 perform public.pdi_eg_command('void',transfer_id,'{}',2,'QA reversão da transferência já disponível');
 perform public.pdi_eg_command('void',entry_id,'{}',1,'QA reversão da entrada após devolver produtos');
 assert(select coalesce(sum(quantity),0)=0 from public.pdi_eg_stock_moves where product_id in(item_id,kit_id)),'Estornos devem zerar todo movimento QA';
 assert not exists(select 1 from public.pdi_eg_records where id in(entry_id,transfer_id,prep_id,order_id,receipt1,receipt2,receipt3) and active),'Registros anulados não podem permanecer ativos';
 assert(select count(*)>=16 from public.pdi_eg_audit where entity_id in(company_id,item_id,kit_id,entry_id,transfer_id,prep_id,order_id,receipt1,receipt2,receipt3)),'Auditoria precisa cobrir cadastro, estoque, financeiro e estornos';
end
$test$;
reset role;
select 'PASS: ACL/RLS, coordenação/estoque/gestão, kit, transferência, parcelas, baixas, entrega, revisão, saldo e estornos auditados; rollback abaixo' as resultado;
rollback;
