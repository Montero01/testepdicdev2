begin;
alter table public.pdi_pcp_daily add column if not exists m2_analyzed numeric check(m2_analyzed>=0 and m2_analyzed<1000000000 and scale(m2_analyzed)<=3);
grant select(m2_analyzed)on public.pdi_pcp_daily to authenticated;
create index if not exists pdi_pcp_date_person_idx on public.pdi_pcp_daily(work_date,pcp_id);
create or replace function pdi_performance_private.can_record_pcp_waste()
returns boolean language sql stable security invoker set search_path=pg_catalog as $$ select not pdi_performance_private.is_indicator_admin() and coalesce(pdi_performance_private.module_level('pcp_m2') in('manager','supervisor'),false) $$;
revoke all on function pdi_performance_private.can_record_pcp_waste()from public,anon;grant execute on function pdi_performance_private.can_record_pcp_waste()to authenticated;
create table public.pdi_pcp_waste(
 entry_id uuid primary key references public.pdi_pcp_daily(id)on delete restrict,
 m2_wasted numeric not null check(m2_wasted>=0 and m2_wasted<1000000000 and scale(m2_wasted)<=3),
 revision int not null default 1,reason text,created_at timestamptz not null default now(),created_by uuid references public.profiles(id),updated_at timestamptz not null default now(),updated_by uuid references public.profiles(id));
create index pdi_pcp_waste_created_by_idx on public.pdi_pcp_waste(created_by);
create index pdi_pcp_waste_updated_by_idx on public.pdi_pcp_waste(updated_by);
alter table public.pdi_pcp_waste enable row level security;
revoke all on public.pdi_pcp_waste from public,anon,authenticated;
grant select(entry_id,m2_wasted,revision,created_at,created_by,updated_at,updated_by),insert,update on public.pdi_pcp_waste to authenticated;
create policy pdi_waste_read on public.pdi_pcp_waste for select to authenticated using(exists(select 1 from public.pdi_pcp_daily d where d.id=entry_id));
create policy pdi_waste_insert on public.pdi_pcp_waste for insert to authenticated with check(pdi_performance_private.can_record_pcp_waste());
create policy pdi_waste_update on public.pdi_pcp_waste for update to authenticated using(pdi_performance_private.can_record_pcp_waste())with check(pdi_performance_private.can_record_pcp_waste());
-- Somente o trigger pode bloquear a linha diária sem conceder edição ao gerente.
create or replace function pdi_performance_private.guard_pcp_waste()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d public.pdi_pcp_daily%rowtype;begin
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
 new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;end $$;
revoke all on function pdi_performance_private.guard_pcp_waste()from public,anon,authenticated;
create trigger pdi_guard_pcp_waste before insert or update on public.pdi_pcp_waste for each row execute function pdi_performance_private.guard_pcp_waste();
create or replace function pdi_performance_private.audit_pcp_waste()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d public.pdi_pcp_daily%rowtype;a public.profiles%rowtype;meta jsonb;begin
 select *into d from public.pdi_pcp_daily where id=new.entry_id;select *into a from public.profiles where id=auth.uid();
 meta:=jsonb_build_object('work_date',d.work_date,'pcp_name_snapshot',d.pcp_name_snapshot);
 insert into public.pdi_performance_audit(entry_id,pcp_id,sector_snapshot,module_key,action,actor_id,actor_name,actor_role,database_actor,reason,before_data,after_data,area_key_snapshot,access_level_snapshot)
 values(d.id,d.pcp_id,d.sector_snapshot,'pcp_waste',tg_op,auth.uid(),a.full_name,a.role,session_user||'/'||coalesce(current_setting('role',true),'none'),new.reason,case when tg_op='UPDATE'then to_jsonb(old)||meta else null end,to_jsonb(new)||meta,'producao',pdi_performance_private.module_level('pcp_m2'));return new;end $$;
revoke all on function pdi_performance_private.audit_pcp_waste()from public,anon,authenticated;
create trigger pdi_audit_pcp_waste after insert or update on public.pdi_pcp_waste for each row execute function pdi_performance_private.audit_pcp_waste();
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
end $$;create or replace function public.pdi_pcp_dashboard(p_start_date date,p_end_date date,p_pcp_id uuid default null)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$
declare payload jsonb;begin
 if not pdi_performance_private.can_view_module('pcp_m2')then raise exception 'Dashboard restrito à gestão de Produção.' using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date)or not isfinite(p_end_date)or p_start_date>p_end_date then raise exception 'Período inválido.' using errcode='22023';end if;
 with f as materialized(select d.id,d.pcp_id,d.work_date,d.pcp_name_snapshot,d.m2_saved,d.m2_analyzed,d.updated_at,w.m2_wasted from public.pdi_pcp_daily d left join public.pdi_pcp_waste w on w.entry_id=d.id where d.work_date between p_start_date and p_end_date and(p_pcp_id is null or d.pcp_id=p_pcp_id)),
 g as(select pcp_id,(array_agg(pcp_name_snapshot order by work_date desc,updated_at desc))[1]name,count(*)entry_count,sum(m2_saved)saved,sum(m2_analyzed)analyzed,sum(m2_wasted)wasted,count(*)filter(where m2_analyzed is null or m2_wasted is null)pending,
 case when count(*)filter(where m2_analyzed is null or m2_wasted is null)=0 then round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)end utilization from f group by pcp_id),
 r as(select g.*,dense_rank()over(order by saved desc)place from g)
 select jsonb_build_object('total_m2',coalesce((select sum(m2_saved)from f),0)::text,'total_analyzed',(select sum(m2_analyzed)::text from f),'total_wasted',(select sum(m2_wasted)::text from f),
 'entry_count',(select count(*)from f),'pcp_count',(select count(*)from g),'pending_count',(select count(*)from f where m2_analyzed is null or m2_wasted is null),'can_record_waste',pdi_performance_private.can_record_pcp_waste(),
 'utilization_percent',(select round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null and m2_wasted is not null),
 'waste_percent',(select round(sum(m2_wasted)*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null and m2_wasted is not null),
 'recovery_percent',(select round(sum(m2_saved)*100/nullif(sum(m2_analyzed),0),2)::text from f where m2_analyzed is not null),
 'ranking',coalesce((select jsonb_agg(jsonb_build_object('pcp_id',pcp_id,'name',name,'total_m2',saved::text,'total_analyzed',analyzed::text,'total_wasted',wasted::text,'entry_count',entry_count,'pending_count',pending,'utilization_percent',utilization::text,'place',place,'share_percent','0','bar_percent','0')order by saved desc,name)from r),'[]'),
 'daily',coalesce((select jsonb_agg(jsonb_build_object('date',work_date,'saved',saved::text,'analyzed',analyzed::text,'wasted',wasted::text,'pending_count',pending,'utilization_percent',utilization::text)order by work_date)from(select work_date,sum(m2_saved)saved,sum(m2_analyzed)analyzed,sum(m2_wasted)wasted,count(*)filter(where m2_analyzed is null or m2_wasted is null)pending,case when count(*)filter(where m2_analyzed is null or m2_wasted is null)=0 then round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)end utilization from f group by work_date)x),'[]'),'updated_at',statement_timestamp())into payload;
 return payload;end $$;
-- Lista paginada para gerência registrar somente desperdício, sem editar produção.
create or replace function public.pdi_pcp_waste_entries(p_start_date date,p_end_date date,p_pcp_id uuid default null,p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$ declare result jsonb;begin
 if not(pdi_performance_private.can_view_module('pcp_m2')or pdi_performance_private.can_collect_module('pcp_m2'))then raise exception 'Acesso restrito à gestão de Produção.' using errcode='42501';end if;
 if p_offset<0 or p_start_date is null or p_end_date is null or p_start_date>p_end_date then raise exception 'Filtro inválido.' using errcode='22023';end if;
 with f as materialized(select d.id,d.pcp_id,d.work_date,d.pcp_name_snapshot,d.m2_analyzed,d.m2_saved,w.m2_wasted,w.revision as waste_revision from public.pdi_pcp_daily d left join public.pdi_pcp_waste w on w.entry_id=d.id where d.work_date between p_start_date and p_end_date and(p_pcp_id is null or d.pcp_id=p_pcp_id))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by work_date desc,id limit 30 offset p_offset)x),'[]'))into result;return result;end $$;
revoke all on function public.pdi_pcp_waste_entries(date,date,uuid,int)from public,anon;grant execute on function public.pdi_pcp_waste_entries(date,date,uuid,int)to authenticated;
notify pgrst,'reload schema';commit;
