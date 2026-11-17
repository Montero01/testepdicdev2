begin;
create table public.pdi_audit_exports(id uuid primary key default gen_random_uuid(),module_key text not null check(module_key in('pcp_m2','cash_daily')),reference_month date not null,search_text text not null default '',subject_id uuid,row_count int not null check(row_count between 0 and 50000),actor_id uuid not null,actor_name text not null,actor_email text,actor_role text,created_at timestamptz not null default clock_timestamp(),download_triggered_at timestamptz);
create index pdi_audit_exports_month_idx on public.pdi_audit_exports(module_key,reference_month,created_at desc);
create index if not exists pdi_audit_time_idx on public.pdi_performance_audit(occurred_at desc,id);
create index if not exists pdi_cash_audit_time_idx on public.pdi_cash_audit(occurred_at desc,id);
alter table public.pdi_audit_exports enable row level security;
revoke all on public.pdi_audit_exports from public,anon,authenticated;grant select on public.pdi_audit_exports to authenticated;
create policy pdi_export_read on public.pdi_audit_exports for select to authenticated using(pdi_performance_private.can_audit_module(module_key));
create or replace function pdi_performance_private.record_audit_export(p_module text,p_month date,p_search text,p_subject uuid,p_count int)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$ declare k uuid;p public.profiles%rowtype;begin
 if auth.uid()is null or not pdi_performance_private.can_audit_module(p_module)or p_module not in('pcp_m2','cash_daily')then raise exception 'Exportação restrita à gerência da área e Diretoria.'using errcode='42501';end if;
 select *into p from public.profiles where id=auth.uid();insert into public.pdi_audit_exports(module_key,reference_month,search_text,subject_id,row_count,actor_id,actor_name,actor_email,actor_role)values(p_module,p_month,left(coalesce(p_search,''),150),p_subject,p_count,auth.uid(),coalesce(p.full_name,'Usuário'),coalesce((select u.email from auth.users u where u.id=auth.uid()),p.email),pdi_performance_private.module_level(p_module))returning id into k;return k;end $$;
revoke all on function pdi_performance_private.record_audit_export(text,date,text,uuid,int)from public,anon;grant execute on function pdi_performance_private.record_audit_export(text,date,text,uuid,int)to authenticated;
create or replace function public.pdi_audit_query(p_module text,p_month date,p_search text default '',p_subject uuid default null,p_offset int default 0,p_export boolean default false)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
declare payload jsonb;n int;export_id uuid;start_at timestamptz;end_at timestamptz;begin
 if auth.uid()is null or p_module not in('pcp_m2','cash_daily')or not pdi_performance_private.can_audit_module(p_module)then raise exception 'Log restrito à gerência da área e Diretoria.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or extract(day from p_month)<>1 or p_offset<0 or length(coalesce(p_search,''))>150 then raise exception 'Mês ou pesquisa inválida.'using errcode='22023';end if;
 start_at:=p_month::timestamp at time zone 'America/Manaus';end_at:=(p_month+interval'1 month')at time zone 'America/Manaus';
 with events as materialized(
 select a.id,a.module_key,a.action,a.actor_id,a.actor_name,a.actor_role,p.email actor_email,a.database_actor,a.occurred_at,a.reason,a.before_data,a.after_data,a.pcp_id subject_id from public.pdi_performance_audit a left join public.profiles p on p.id=a.actor_id where p_module='pcp_m2'and a.occurred_at>=start_at and a.occurred_at<end_at and(p_subject is null or a.pcp_id=p_subject)
 union all select a.id,'cash_daily',a.action,a.actor_id,a.actor_name,a.actor_role,p.email,a.database_actor,a.occurred_at,a.reason,a.before_data,a.after_data,a.cashier_id from public.pdi_cash_audit a left join public.profiles p on p.id=a.actor_id where p_module='cash_daily'and a.occurred_at>=start_at and a.occurred_at<end_at and(p_subject is null or a.cashier_id=p_subject)
 ),filtered as materialized(select *from events e where coalesce(p_search,'')=''or strpos(lower(concat_ws(' ',e.actor_name,e.actor_email,e.actor_id::text,e.action,e.reason,e.before_data::text,e.after_data::text)),lower(p_search))>0)
 select jsonb_build_object('count',(select count(*)from filtered),'month',p_month,'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from filtered order by occurred_at desc,id desc limit(case when p_export then 50001 else 30 end)offset(case when p_export then 0 else p_offset end))x),'[]'))into payload;
 n:=(payload->>'count')::int;if p_export then
 if n>50000 then raise exception 'Mais de 50 mil eventos: refine a pesquisa ou selecione um colaborador.'using errcode='22023';end if;
 export_id:=pdi_performance_private.record_audit_export(p_module,p_month,p_search,p_subject,n);payload:=payload||jsonb_build_object('export_id',export_id);end if;return payload;end $$;
revoke all on function public.pdi_audit_query(text,date,text,uuid,int,boolean)from public,anon;grant execute on function public.pdi_audit_query(text,date,text,uuid,int,boolean)to authenticated;
create or replace function public.pdi_audit_export_history(p_module text,p_month date,p_search text default '',p_offset int default 0)
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog as $$ declare result jsonb;begin
 if auth.uid()is null or p_module not in('pcp_m2','cash_daily')or not pdi_performance_private.can_audit_module(p_module)then raise exception 'Consulta restrita à gestão da área.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or p_offset<0 or length(coalesce(p_search,''))>150 then raise exception 'Filtro inválido.'using errcode='22023';end if;
 with f as materialized(select *from public.pdi_audit_exports e where module_key=p_module and reference_month=p_month and(coalesce(p_search,'')=''or strpos(lower(concat_ws(' ',e.actor_name,e.actor_email,e.actor_id::text,e.search_text)),lower(p_search))>0))
 select jsonb_build_object('count',(select count(*)from f),'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from f order by created_at desc,id desc limit 30 offset p_offset)x),'[]'))into result;return result;end $$;
revoke all on function public.pdi_audit_export_history(text,date,text,int)from public,anon;grant execute on function public.pdi_audit_export_history(text,date,text,int)to authenticated;
create or replace function pdi_performance_private.mark_audit_export(p_id uuid)
returns void language plpgsql security definer set search_path=pg_catalog as $$ begin
 if auth.uid()is null then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 update public.pdi_audit_exports set download_triggered_at=coalesce(download_triggered_at,clock_timestamp())where id=p_id and actor_id=auth.uid()and pdi_performance_private.can_audit_module(module_key);
 if not found then raise exception 'Exportação fora do seu acesso.'using errcode='42501';end if;end $$;
revoke all on function pdi_performance_private.mark_audit_export(uuid)from public,anon;grant execute on function pdi_performance_private.mark_audit_export(uuid)to authenticated;
create or replace function public.pdi_audit_export_dispatched(p_id uuid)returns void language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.mark_audit_export(p_id)$$;
revoke all on function public.pdi_audit_export_dispatched(uuid)from public,anon;grant execute on function public.pdi_audit_export_dispatched(uuid)to authenticated;
notify pgrst,'reload schema';commit;
