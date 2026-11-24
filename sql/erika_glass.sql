-- Erika Glass: catálogo compartilhado, registros, estoque por estágio e auditoria.
create schema if not exists pdi_eg_private;
revoke all on schema pdi_eg_private from public,anon;
grant usage on schema pdi_eg_private to authenticated;
create table public.pdi_eg_access(profile_id uuid not null references public.profiles(id),access_role text not null check(access_role in('coordinator','stock')),primary key(profile_id,access_role));
alter table public.pdi_eg_access enable row level security;
create policy eg_access_read on public.pdi_eg_access for select to authenticated using(profile_id=(select auth.uid()) or pdi_performance_private.performance_manager());
grant select on public.pdi_eg_access to authenticated;
insert into public.pdi_eg_access select id,'coordinator' from public.profiles where lower(full_name)='adriane pinheiro campos';
insert into public.pdi_eg_access select id,'stock' from public.profiles where lower(full_name)='jackson f. maia';

create function pdi_eg_private.norm(v text)returns text language sql immutable set search_path=pg_catalog as $$select trim(regexp_replace(translate(lower(coalesce(v,'')),'áàâãäéèêëíìîïóòôõöúùûüç','aaaaaeeeeiiiiooooouuuuc'),'[^a-z0-9]+',' ','g'))$$;
create function pdi_eg_private.permissions()returns jsonb language sql stable security invoker set search_path=pg_catalog as $$
 with p as(select pdi_eg_private.norm(position)pos from public.profiles where id=auth.uid()),a as(select
 coalesce(pdi_performance_private.performance_manager(),false)manager,
 exists(select 1 from public.pdi_eg_access where profile_id=auth.uid()and access_role='coordinator')coordinator,
 exists(select 1 from public.pdi_eg_access where profile_id=auth.uid()and access_role='stock')stock,
 exists(select 1 from p where pos in('vendas e g','vendas erika glass'))sales,
 exists(select 1 from p where pos in('promotoria e g','promotoria erika glass','promotor e g','promotora e g'))promoter,
 exists(select 1 from p where pos in('producao e g','producao erika glass'))production)
 select jsonb_build_object('allowed',auth.uid()is not null and(manager or coordinator or stock or sales or promoter or production),'manager',manager,'coordinator',coordinator,
 'can_manage',manager or coordinator,'can_import',manager or coordinator,'can_sales',manager or coordinator or sales,'can_visit',manager or coordinator or promoter or sales,
 'can_production',manager or coordinator or production,'can_stock',manager or stock,'can_occurrences',manager or coordinator or stock,'can_finance',manager or coordinator,
 'can_delete',manager,'can_eg',manager or coordinator or sales or promoter or production,'can_stock_module',manager or coordinator or stock)from a;
$$;
create function public.pdi_eg_context()returns jsonb language sql stable security invoker set search_path=pg_catalog as $$select pdi_eg_private.permissions()||jsonb_build_object('today',pdi_performance_private.today_manaus(),'user_id',auth.uid())$$;
revoke all on function pdi_eg_private.norm(text),pdi_eg_private.permissions(),public.pdi_eg_context()from public,anon;
grant execute on function pdi_eg_private.norm(text),pdi_eg_private.permissions(),public.pdi_eg_context()to authenticated;

create table public.pdi_eg_companies(id uuid primary key default gen_random_uuid(),name text not null check(length(name)between 2 and 160),document text unique,contact_name text not null default '',contact_phone text not null default '',contact_email text not null default '',address text not null default '',active boolean not null default true,revision integer not null default 1,created_at timestamptz not null default now(),created_by uuid not null references public.profiles(id),updated_at timestamptz not null default now(),updated_by uuid not null references public.profiles(id));
create table public.pdi_eg_products(id uuid primary key default gen_random_uuid(),sku text not null,name text not null check(length(name)between 2 and 160),kind text not null check(kind in('item','kit')),sale_cents bigint check(sale_cents between 0 and 99999999999),components jsonb not null default '[]',active boolean not null default true,revision integer not null default 1,created_at timestamptz not null default now(),created_by uuid not null references public.profiles(id),updated_at timestamptz not null default now(),updated_by uuid not null references public.profiles(id));
create unique index eg_product_sku on public.pdi_eg_products(lower(sku));
create table public.pdi_eg_prices(product_id uuid primary key references public.pdi_eg_products(id),cost_cents bigint check(cost_cents between 0 and 99999999999),updated_at timestamptz not null default now(),updated_by uuid not null references public.profiles(id));
create table public.pdi_eg_records(id uuid primary key default gen_random_uuid(),kind text not null check(kind in('report','visit','order','transfer','preparation','receipt','occurrence','stock_entry')),work_date date not null,company_id uuid references public.pdi_eg_companies(id),subject_id uuid not null references public.profiles(id),parent_id uuid references public.pdi_eg_records(id),status text not null default 'registered',data jsonb not null default '{}',active boolean not null default true,revision integer not null default 1,created_at timestamptz not null default now(),created_by uuid not null references public.profiles(id),updated_at timestamptz not null default now(),updated_by uuid not null references public.profiles(id));
create unique index eg_daily_report on public.pdi_eg_records(work_date,subject_id)where kind='report'and active;
create index eg_record_date on public.pdi_eg_records(kind,work_date desc);
create index eg_record_parent on public.pdi_eg_records(parent_id);
create table public.pdi_eg_stock_moves(id uuid primary key default gen_random_uuid(),record_id uuid not null references public.pdi_eg_records(id),product_id uuid not null references public.pdi_eg_products(id),location text not null check(location in('warehouse','raw','ready')),quantity bigint not null check(quantity<>0),reversal boolean not null default false,created_at timestamptz not null default now(),created_by uuid not null references public.profiles(id));
create index eg_stock_product on public.pdi_eg_stock_moves(product_id,location);
create index eg_stock_record on public.pdi_eg_stock_moves(record_id);
create table public.pdi_eg_audit(id uuid primary key default gen_random_uuid(),entity text not null,entity_id uuid,action text not null,before_data jsonb,after_data jsonb,reason text,actor_id uuid not null references public.profiles(id),actor_name text not null,actor_role text not null,occurred_at timestamptz not null default now());
create index eg_audit_month on public.pdi_eg_audit(occurred_at desc);
create table public.pdi_eg_photos(id uuid primary key default gen_random_uuid(),visit_id uuid not null references public.pdi_eg_records(id),phase text not null check(phase in('before','after')),path text not null unique,file_name text not null,size_bytes bigint not null,active boolean not null default true,created_at timestamptz not null default now(),created_by uuid not null references public.profiles(id));
create index eg_photo_visit on public.pdi_eg_photos(visit_id,phase)where active;

create function pdi_eg_private.read_record(k text,subject uuid,creator uuid)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select coalesce((p->>'can_manage')::boolean,false)or case
 when k='occurrence'then(p->>'can_occurrences')::boolean
 when k in('transfer','preparation','stock_entry')then(p->>'can_stock')::boolean or(p->>'can_production')::boolean
 when k in('report','visit','order')then(p->>'allowed')::boolean and(subject=auth.uid()or creator=auth.uid())
 when k='receipt'then(p->>'can_finance')::boolean else false end from(select pdi_eg_private.permissions()p)x$$;
revoke all on function pdi_eg_private.read_record(text,uuid,uuid)from public,anon;grant execute on function pdi_eg_private.read_record(text,uuid,uuid)to authenticated;
do $$declare t text;begin foreach t in array array['pdi_eg_companies','pdi_eg_products','pdi_eg_prices','pdi_eg_records','pdi_eg_stock_moves','pdi_eg_audit','pdi_eg_photos']loop execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);end loop;end$$;
create policy eg_company_read on public.pdi_eg_companies for select to authenticated using((pdi_eg_private.permissions()->>'can_sales')::boolean or(pdi_eg_private.permissions()->>'can_visit')::boolean or(pdi_eg_private.permissions()->>'can_finance')::boolean);
create policy eg_product_read on public.pdi_eg_products for select to authenticated using((pdi_eg_private.permissions()->>'allowed')::boolean);
create policy eg_price_read on public.pdi_eg_prices for select to authenticated using((pdi_eg_private.permissions()->>'can_finance')::boolean);
create policy eg_record_read on public.pdi_eg_records for select to authenticated using(pdi_eg_private.read_record(kind,subject_id,created_by));
create policy eg_moves_read on public.pdi_eg_stock_moves for select to authenticated using((pdi_eg_private.permissions()->>'can_stock')::boolean or(pdi_eg_private.permissions()->>'can_production')::boolean or(pdi_eg_private.permissions()->>'can_sales')::boolean);
create policy eg_audit_read on public.pdi_eg_audit for select to authenticated using((pdi_eg_private.permissions()->>'can_manage')::boolean);
create policy eg_photo_read on public.pdi_eg_photos for select to authenticated using(exists(select 1 from public.pdi_eg_records r where r.id=visit_id and pdi_eg_private.read_record(r.kind,r.subject_id,r.created_by)));

create function pdi_eg_private.integer(v jsonb,maximum bigint default 1000000)returns bigint language plpgsql immutable set search_path=pg_catalog as $$begin if v is null or v='null'::jsonb or v#>>'{}'!~'^\d+$'then raise exception 'Use quantidades inteiras e valores monetários com centavos válidos.'using errcode='22023';end if;if(v#>>'{}')::numeric>maximum then raise exception 'Valor acima do limite permitido.'using errcode='22023';end if;return(v#>>'{}')::bigint;end$$;
create function pdi_eg_private.valid_document(v text)returns boolean language plpgsql immutable set search_path=pg_catalog as $$declare d text:=regexp_replace(coalesce(v,''),'\D','','g');n integer;s integer;j integer;checkdigit integer;weights integer[];begin n:=length(d);if n not in(11,14)or d=repeat(left(d,1),n)then return false;end if;for j in 1..2 loop s:=0;if n=11 then for i in 1..(8+j)loop s:=s+substr(d,i,1)::int*(10+j-i);end loop;checkdigit:=(s*10)%11;if checkdigit=10 then checkdigit:=0;end if;else weights:=case when j=1 then array[5,4,3,2,9,8,7,6,5,4,3,2]else array[6,5,4,3,2,9,8,7,6,5,4,3,2]end;for i in 1..array_length(weights,1)loop s:=s+substr(d,i,1)::int*weights[i];end loop;checkdigit:=case when s%11<2 then 0 else 11-s%11 end;end if;if checkdigit<>substr(d,n-2+j,1)::int then return false;end if;end loop;return true;end$$;
create function pdi_eg_private.audit(entity text,entity_id uuid,action text,before_data jsonb,after_data jsonb,reason text default null)returns void language sql security definer set search_path=pg_catalog as $$insert into public.pdi_eg_audit(entity,entity_id,action,before_data,after_data,reason,actor_id,actor_name,actor_role)select entity,entity_id,action,before_data,after_data,reason,p.id,p.full_name,p.role from public.profiles p where p.id=auth.uid()$$;
create function pdi_eg_private.move(record_id uuid,product_id uuid,location text,quantity bigint,reversal boolean default false)returns void language plpgsql security definer set search_path=pg_catalog as $$declare available bigint;begin if quantity=0 then return;end if;select coalesce(sum(m.quantity),0)into available from public.pdi_eg_stock_moves m where m.product_id=move.product_id and m.location=move.location;if available+quantity<0 then raise exception 'Saldo insuficiente para este produto no estágio %. Atualize os dados.',location using errcode='23514';end if;insert into public.pdi_eg_stock_moves(record_id,product_id,location,quantity,reversal,created_by)values(record_id,product_id,location,quantity,reversal,auth.uid());end$$;
revoke all on function pdi_eg_private.integer(jsonb,bigint),pdi_eg_private.valid_document(text),pdi_eg_private.audit(text,uuid,text,jsonb,jsonb,text),pdi_eg_private.move(uuid,uuid,text,bigint,boolean)from public,anon,authenticated;

create function pdi_eg_private.command(p_action text,p_id uuid,p_data jsonb,p_revision integer,p_reason text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
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
   v_data:=jsonb_build_object('company_id',v_company.id,'company_name',v_company.name,'document',v_company.document,'items',v_items,'total_cents',v_total,'quoted_cents',pdi_eg_private.integer(coalesce(v_data->'quoted_cents',to_jsonb(v_total)),99999999999),'payment',v_data->>'payment','installments',v_inst,'notes',left(coalesce(v_data->>'notes',''),1500));v_status:='closed';
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
  for v_x in select *from jsonb_array_elements(v_rec.data->'items')loop perform pdi_eg_private.move(v_id,(v_x->>'product_id')::uuid,'ready',-(v_x->>'quantity')::bigint);end loop;
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
$$;
revoke all on function pdi_eg_private.command(text,uuid,jsonb,integer,text)from public,anon;
grant execute on function pdi_eg_private.command(text,uuid,jsonb,integer,text)to authenticated;
create function public.pdi_eg_command(p_action text,p_id uuid default null,p_data jsonb default '{}',p_revision integer default null,p_reason text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_eg_private.command(p_action,p_id,p_data,p_revision,p_reason)$$;
revoke all on function public.pdi_eg_command(text,uuid,jsonb,integer,text)from public,anon;
grant execute on function public.pdi_eg_command(text,uuid,jsonb,integer,text)to authenticated;

-- Fotografias privadas: upload próprio, limite por visita/fase e acesso do registro.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('pdi-eg-visits','pdi-eg-visits',false,5242880,array['image/jpeg','image/png','image/webp'])on conflict(id)do nothing;
create function pdi_eg_private.photo_allowed(p_path text,p_write boolean)returns boolean language plpgsql stable security definer set search_path=pg_catalog as $$
declare r public.pdi_eg_records%rowtype;parts text[]:=string_to_array(p_path,'/');p jsonb:=pdi_eg_private.permissions();begin
 if auth.uid()is null or not(p->>'can_visit')::boolean or array_length(parts,1)<>4 then return false;end if;
 if parts[2]!~'^[0-9a-fA-F-]{36}$'then return false;end if;
 select *into r from public.pdi_eg_records where id=parts[2]::uuid and kind='visit'and active;
 if not found or not pdi_eg_private.read_record(r.kind,r.subject_id,r.created_by)then return false;end if;
 if p_write then return parts[1]=auth.uid()::text and parts[3]in('before','after')and parts[4]~'^[a-zA-Z0-9_-]+\.(jpg|jpeg|png|webp)$'and((p->>'can_manage')::boolean or r.subject_id=auth.uid());end if;
 return exists(select 1 from public.pdi_eg_photos where path=p_path and active);
 exception when invalid_text_representation then return false;
end$$;
revoke all on function pdi_eg_private.photo_allowed(text,boolean)from public,anon;grant execute on function pdi_eg_private.photo_allowed(text,boolean)to authenticated;
create policy eg_photo_object_read on storage.objects for select to authenticated using(bucket_id='pdi-eg-visits'and pdi_eg_private.photo_allowed(name,false));
create policy eg_photo_object_insert on storage.objects for insert to authenticated with check(bucket_id='pdi-eg-visits'and pdi_eg_private.photo_allowed(name,true));
create policy eg_photo_object_delete on storage.objects for delete to authenticated using(bucket_id='pdi-eg-visits'and split_part(name,'/',1)=auth.uid()::text and not exists(select 1 from public.pdi_eg_photos where path=name and active));
create function pdi_eg_private.photo(p_action text,p_visit uuid,p_phase text,p_path text,p_name text)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare r public.pdi_eg_records%rowtype;pic public.pdi_eg_photos%rowtype;v_size bigint;p jsonb:=pdi_eg_private.permissions();begin
 perform pg_advisory_xact_lock(763123,24);
 select *into r from public.pdi_eg_records where id=p_visit and kind='visit'and active;
 if not found or not(p->>'can_visit')::boolean or not((p->>'can_manage')::boolean or r.subject_id=auth.uid())then raise exception 'Sem acesso às fotos desta visita.'using errcode='42501';end if;
 if p_action='attach'then
  if p_phase not in('before','after')or not pdi_eg_private.photo_allowed(p_path,true)or split_part(p_path,'/',2)<>p_visit::text or split_part(p_path,'/',3)<>p_phase then raise exception 'Caminho de fotografia inválido.'using errcode='22023';end if;
  if exists(select 1 from public.pdi_eg_photos where path=p_path and active)then return jsonb_build_object('attached',true);end if;
  if(select count(*)from public.pdi_eg_photos where visit_id=p_visit and phase=p_phase and active)>=3 then raise exception 'Máximo de três fotos por etapa.'using errcode='23514';end if;
  select(metadata->>'size')::bigint into v_size from storage.objects where bucket_id='pdi-eg-visits'and name=p_path;
  if v_size is null or v_size>5242880 then raise exception 'Fotografia ausente ou acima de 5 MB.'using errcode='22023';end if;
  insert into public.pdi_eg_photos(visit_id,phase,path,file_name,size_bytes,created_by)values(p_visit,p_phase,p_path,left(coalesce(p_name,'Foto'),160),v_size,auth.uid())returning *into pic;
  perform pdi_eg_private.audit('photo',pic.id,'ATTACH',null,to_jsonb(pic),null);
 elsif p_action='remove'then
  select *into pic from public.pdi_eg_photos where visit_id=p_visit and path=p_path and active for update;
  if not found then raise exception 'Fotografia não encontrada.'using errcode='22023';end if;
  update public.pdi_eg_photos set active=false where id=pic.id;
  perform pdi_eg_private.audit('photo',pic.id,'REMOVE',to_jsonb(pic),jsonb_build_object('active',false),null);
 else raise exception 'Ação de fotografia inválida.'using errcode='22023';end if;
 return jsonb_build_object('id',pic.id,'path',pic.path,'active',p_action='attach');
end$$;
revoke all on function pdi_eg_private.photo(text,uuid,text,text,text)from public,anon;grant execute on function pdi_eg_private.photo(text,uuid,text,text,text)to authenticated;
create function public.pdi_eg_photo(p_action text,p_visit uuid,p_phase text default null,p_path text default null,p_name text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_eg_private.photo(p_action,p_visit,p_phase,p_path,p_name)$$;
revoke all on function public.pdi_eg_photo(text,uuid,text,text,text)from public,anon;grant execute on function public.pdi_eg_photo(text,uuid,text,text,text)to authenticated;

create function pdi_eg_private.export_log(p_kind text,p_count integer,p_filters jsonb)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$begin
 if auth.uid()is null or not(pdi_eg_private.permissions()->>'allowed')::boolean then raise exception 'Acesso negado.'using errcode='42501';end if;
 if p_kind not in('records','products','finance','stock','audit')or p_count<0 or p_count>50000 or octet_length(coalesce(p_filters,'{}')::text)>2000 then raise exception 'Exportação inválida.'using errcode='22023';end if;
 if p_kind='audit'and not(pdi_eg_private.permissions()->>'can_manage')::boolean then raise exception 'Log restrito à gestão.'using errcode='42501';end if;
 perform pdi_eg_private.audit('export',null,'CSV_EXPORT',null,jsonb_build_object('kind',p_kind,'rows_reported',p_count,'filters',p_filters),null);
 return jsonb_build_object('logged',true);
end$$;
revoke all on function pdi_eg_private.export_log(text,integer,jsonb)from public,anon;grant execute on function pdi_eg_private.export_log(text,integer,jsonb)to authenticated;
create function public.pdi_eg_export_log(p_kind text,p_count integer,p_filters jsonb default '{}')returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_eg_private.export_log(p_kind,p_count,p_filters)$$;
revoke all on function public.pdi_eg_export_log(text,integer,jsonb)from public,anon;grant execute on function public.pdi_eg_export_log(text,integer,jsonb)to authenticated;
notify pgrst,'reload schema';

-- Chave de requisição protege operações físicas e financeiras contra reenvio de rede.
create table public.pdi_eg_requests(actor_id uuid not null references public.profiles(id),request_id uuid not null,payload jsonb not null,result jsonb not null,created_at timestamptz not null default now(),primary key(actor_id,request_id));
alter table public.pdi_eg_requests enable row level security;
revoke all on public.pdi_eg_requests from public,anon,authenticated;
alter function pdi_eg_private.command(text,uuid,jsonb,integer,text)rename to perform_command;
create function pdi_eg_private.request(p_action text,p_id uuid,p_data jsonb,p_revision integer,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior public.pdi_eg_requests%rowtype;result jsonb;payload jsonb:=jsonb_build_object('action',p_action,'id',p_id,'data',p_data,'revision',p_revision,'reason',p_reason);begin
 if auth.uid()is null then raise exception 'Entre novamente.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(763123,24);
 if p_request_id is not null then
  select *into prior from public.pdi_eg_requests where actor_id=auth.uid()and request_id=p_request_id;
  if found then if prior.payload<>payload then raise exception 'Requisição reutilizada com dados diferentes.'using errcode='22023';end if;return prior.result;end if;
 end if;
 result:=pdi_eg_private.perform_command(p_action,p_id,p_data,p_revision,p_reason);
 if p_request_id is not null then insert into public.pdi_eg_requests(actor_id,request_id,payload,result)values(auth.uid(),p_request_id,payload,result);end if;
 return result;
end$$;
revoke all on function pdi_eg_private.request(text,uuid,jsonb,integer,text,uuid)from public,anon;grant execute on function pdi_eg_private.request(text,uuid,jsonb,integer,text,uuid)to authenticated;
-- Existing internal catalog recursion and existing clients retain the guarded five-argument entry.
create function pdi_eg_private.command(p_action text,p_id uuid,p_data jsonb,p_revision integer,p_reason text)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_eg_private.request(p_action,p_id,p_data,p_revision,p_reason,null)$$;
revoke all on function pdi_eg_private.command(text,uuid,jsonb,integer,text)from public,anon;grant execute on function pdi_eg_private.command(text,uuid,jsonb,integer,text)to authenticated;
drop function public.pdi_eg_command(text,uuid,jsonb,integer,text);
create function public.pdi_eg_command(p_action text,p_id uuid default null,p_data jsonb default '{}',p_revision integer default null,p_reason text default null,p_request_id uuid default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_eg_private.request(p_action,p_id,p_data,p_revision,p_reason,p_request_id)$$;
revoke all on function public.pdi_eg_command(text,uuid,jsonb,integer,text,uuid)from public,anon;grant execute on function public.pdi_eg_command(text,uuid,jsonb,integer,text,uuid)to authenticated;
notify pgrst,'reload schema';
create function pdi_eg_private.global_manager()returns boolean language sql stable security invoker set search_path=pg_catalog as $$select auth.uid()is not null and exists(select 1 from public.profiles where id=auth.uid()and(coalesce(is_master,false)or role in('master','diretor','diretoria','gerente')))$$;
revoke all on function pdi_eg_private.global_manager()from public,anon;grant execute on function pdi_eg_private.global_manager()to authenticated;
drop policy eg_access_read on public.pdi_eg_access;
create policy eg_access_read on public.pdi_eg_access for select to authenticated using(profile_id=(select auth.uid())or pdi_eg_private.global_manager());
create function pdi_eg_private.photo_delete_allowed(p_path text)returns boolean language sql stable security definer set search_path=pg_catalog as $$select auth.uid()is not null and(pdi_eg_private.permissions()->>'can_visit')::boolean and split_part(p_path,'/',1)=auth.uid()::text and not exists(select 1 from public.pdi_eg_photos where path=p_path and active)$$;
revoke all on function pdi_eg_private.photo_delete_allowed(text)from public,anon;grant execute on function pdi_eg_private.photo_delete_allowed(text)to authenticated;
drop policy eg_photo_object_delete on storage.objects;
create policy eg_photo_object_delete on storage.objects for delete to authenticated using(bucket_id='pdi-eg-visits'and pdi_eg_private.photo_delete_allowed(name));
create or replace function pdi_eg_private.permissions()returns jsonb language sql stable security invoker set search_path=pg_catalog as $$
 with p as(select pdi_eg_private.norm(position)pos from public.profiles where id=auth.uid()),a as(select
 coalesce(pdi_eg_private.global_manager(),false)manager,
 exists(select 1 from public.pdi_eg_access where profile_id=auth.uid()and access_role='coordinator')coordinator,
 exists(select 1 from public.pdi_eg_access where profile_id=auth.uid()and access_role='stock')stock,
 exists(select 1 from p where pos in('vendas e g','vendas erika glass'))sales,
 exists(select 1 from p where pos in('promotoria e g','promotoria erika glass','promotor e g','promotora e g'))promoter,
 exists(select 1 from p where pos in('producao e g','producao erika glass'))production)
 select jsonb_build_object('allowed',auth.uid()is not null and(manager or coordinator or stock or sales or promoter or production),'manager',manager,'coordinator',coordinator,
 'can_manage',manager or coordinator,'can_import',manager or coordinator,'can_sales',manager or coordinator or sales,'can_visit',manager or coordinator or promoter or sales,
 'can_production',manager or coordinator or production,'can_stock',manager or stock,'can_occurrences',manager or coordinator or stock,'can_finance',manager or coordinator,
 'can_delete',manager,'can_eg',manager or coordinator or sales or promoter or production,'can_stock_module',manager or coordinator or stock)from a;
$$;
create or replace function pdi_eg_private.request(p_action text,p_id uuid,p_data jsonb,p_revision integer,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior public.pdi_eg_requests%rowtype;result jsonb;payload jsonb:=jsonb_build_object('action',p_action,'id',p_id,'data',p_data,'revision',p_revision,'reason',p_reason);begin
 if auth.uid()is null then raise exception 'Entre novamente.'using errcode='42501';end if;
 if not coalesce((pdi_eg_private.permissions()->>'allowed')::boolean,false)then raise exception 'Acesso E.G. revogado.'using errcode='42501';end if;
 if not coalesce((pdi_eg_private.permissions()->>case
 when p_action in('company_save','product_save','product_import','order_deliver')then'can_manage'
 when p_action in('report_save','order_save')then'can_sales'
 when p_action='visit_save'then'can_visit'
 when p_action in('stock_entry','transfer_send')then'can_stock'
 when p_action in('prepare','transfer_receive')then'can_production'
 when p_action='receipt_add'then'can_finance'
 when p_action='occurrence_resolve'then'can_occurrences'
 when p_action='void'then'can_delete'
 when p_action='occurrence_add'then'allowed'
 else'unknown'end)::boolean,false)then raise exception 'Operação fora do acesso atual.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(763123,24);
 if p_request_id is not null then
  select *into prior from public.pdi_eg_requests where actor_id=auth.uid()and request_id=p_request_id;
  if found then if prior.payload<>payload then raise exception 'Requisição reutilizada com dados diferentes.'using errcode='22023';end if;return prior.result;end if;
 end if;
 result:=pdi_eg_private.perform_command(p_action,p_id,p_data,p_revision,p_reason);
 if p_request_id is not null then insert into public.pdi_eg_requests(actor_id,request_id,payload,result)values(auth.uid(),p_request_id,payload,result);end if;
 return result;
end$$;
create or replace function pdi_eg_private.request(p_action text,p_id uuid,p_data jsonb,p_revision integer,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior public.pdi_eg_requests%rowtype;result jsonb;payload jsonb:=jsonb_build_object('action',p_action,'id',p_id,'data',p_data,'revision',p_revision,'reason',p_reason);begin
 if auth.uid()is null then raise exception 'Entre novamente.'using errcode='42501';end if;
 if not coalesce((pdi_eg_private.permissions()->>'allowed')::boolean,false)then raise exception 'Acesso E.G. revogado.'using errcode='42501';end if;
 if not coalesce((pdi_eg_private.permissions()->>case
 when p_action in('company_save','product_save','product_import','order_deliver')then'can_manage'
 when p_action in('report_save','order_save')then'can_sales'
 when p_action='visit_save'then'can_visit'
 when p_action in('stock_entry','transfer_send')then'can_stock'
 when p_action in('prepare','transfer_receive')then'can_production'
 when p_action='receipt_add'then'can_finance'
 when p_action='occurrence_resolve'then'can_occurrences'
 when p_action='void'then'can_delete'
 when p_action='occurrence_add'then'allowed'
 else'unknown'end)::boolean,false)then raise exception 'Operação fora do acesso atual.'using errcode='42501';end if;
 if p_action='occurrence_add'and not((pdi_eg_private.permissions()->>'can_production')::boolean or(pdi_eg_private.permissions()->>'can_stock')::boolean)then raise exception 'Ocorrência fora do acesso atual.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(763123,24);
 if p_request_id is not null then
  select *into prior from public.pdi_eg_requests where actor_id=auth.uid()and request_id=p_request_id;
  if found then if prior.payload<>payload then raise exception 'Requisição reutilizada com dados diferentes.'using errcode='22023';end if;return prior.result;end if;
 end if;
 result:=pdi_eg_private.perform_command(p_action,p_id,p_data,p_revision,p_reason);
 if p_request_id is not null then insert into public.pdi_eg_requests(actor_id,request_id,payload,result)values(auth.uid(),p_request_id,payload,result);end if;
 return result;
end$$;
create or replace function pdi_eg_private.read_record(k text,subject uuid,creator uuid)returns boolean language sql stable security invoker set search_path=pg_catalog as $$select coalesce((p->>'can_manage')::boolean,false)or case
 when k='occurrence'then(p->>'can_occurrences')::boolean
 when k in('transfer','preparation','stock_entry')then(p->>'can_stock')::boolean or(p->>'can_production')::boolean
 when k in('report','visit','order')then(p->>'allowed')::boolean and subject=auth.uid()
 when k='receipt'then(p->>'can_finance')::boolean else false end from(select pdi_eg_private.permissions()p)x$$;
create or replace function pdi_eg_private.request(p_action text,p_id uuid,p_data jsonb,p_revision integer,p_reason text,p_request_id uuid)returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare prior public.pdi_eg_requests%rowtype;result jsonb;payload jsonb:=jsonb_build_object('action',p_action,'id',p_id,'data',p_data,'revision',p_revision,'reason',p_reason);begin
 if auth.uid()is null then raise exception 'Entre novamente.'using errcode='42501';end if;
 if not coalesce((pdi_eg_private.permissions()->>'allowed')::boolean,false)then raise exception 'Acesso E.G. revogado.'using errcode='42501';end if;
 if not coalesce((pdi_eg_private.permissions()->>case
 when p_action in('company_save','product_save','product_import','order_deliver')then'can_manage'
 when p_action in('report_save','order_save')then'can_sales'
 when p_action='visit_save'then'can_visit'
 when p_action in('stock_entry','transfer_send')then'can_stock'
 when p_action in('prepare','transfer_receive')then'can_production'
 when p_action='receipt_add'then'can_finance'
 when p_action='occurrence_resolve'then'can_occurrences'
 when p_action='void'then'can_delete'
 when p_action='occurrence_add'then'allowed'
 else'unknown'end)::boolean,false)then raise exception 'Operação fora do acesso atual.'using errcode='42501';end if;
 if p_action='occurrence_add'and not((pdi_eg_private.permissions()->>'can_production')::boolean or(pdi_eg_private.permissions()->>'can_stock')::boolean)then raise exception 'Ocorrência fora do acesso atual.'using errcode='42501';end if;
 perform pg_advisory_xact_lock(763123,24);
 if p_request_id is not null then
  select *into prior from public.pdi_eg_requests where actor_id=auth.uid()and request_id=p_request_id;
  if found then if prior.payload<>payload then raise exception 'Requisição reutilizada com dados diferentes.'using errcode='22023';end if;if prior.result?'kind'and not pdi_eg_private.read_record(prior.result->>'kind',(prior.result->>'subject_id')::uuid,(prior.result->>'created_by')::uuid)then raise exception 'Registro fora do acesso atual.'using errcode='42501';end if;return prior.result;end if;
 end if;
 result:=pdi_eg_private.perform_command(p_action,p_id,p_data,p_revision,p_reason);
 if p_request_id is not null then insert into public.pdi_eg_requests(actor_id,request_id,payload,result)values(auth.uid(),p_request_id,payload,result);end if;
 return result;
end$$;
