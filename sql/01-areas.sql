-- Autorizações por área. Preserva dados existentes e o nível geral de profiles.
begin;
create table if not exists public.pdi_indicator_areas(area_key text primary key check(area_key~'^[a-z][a-z0-9_]{1,40}$'),label text not null,active boolean not null default true);
create table if not exists public.pdi_indicator_modules(module_key text primary key,area_key text not null references public.pdi_indicator_areas(area_key),label text not null,page_key text not null,collector_rule text not null default 'none' check(collector_rule in('pcp','cash','none')),enabled boolean not null default false);
create table if not exists public.pdi_area_memberships(profile_id uuid not null references public.profiles(id) on delete cascade,area_key text not null references public.pdi_indicator_areas(area_key),access_level text not null check(access_level in('manager','supervisor')),assigned_by uuid references public.profiles(id),assigned_at timestamptz not null default now(),primary key(profile_id,area_key));
create index if not exists pdi_area_memberships_area_idx on public.pdi_area_memberships(area_key,access_level);
create index if not exists pdi_area_memberships_actor_idx on public.pdi_area_memberships(assigned_by);
create table if not exists public.pdi_indicator_settings(id boolean primary key default true check(id),director_read_all boolean not null default true);
create table if not exists public.pdi_area_access_audit(id uuid primary key default gen_random_uuid(),actor_id uuid,occurred_at timestamptz not null default clock_timestamp(),action text not null,before_data jsonb,after_data jsonb);
insert into public.pdi_indicator_areas(area_key,label) values('producao','Produção'),('financeiro','Financeiro') on conflict do nothing;
insert into public.pdi_indicator_modules(module_key,area_key,label,page_key,collector_rule,enabled) values('pcp_m2','producao','PCP · m² salvos','pcp','pcp',true),('cash_daily','financeiro','Caixa · fechamento diário','cash','cash',true) on conflict do nothing;
insert into public.pdi_indicator_settings(id,director_read_all) values(true,true) on conflict do nothing;
-- Produção corresponde ao setor já protegido. Administrativo não equivale a Financeiro.
insert into public.pdi_area_memberships(profile_id,area_key,access_level)
 select id,'producao',case when role='gerente' then 'manager' else 'supervisor' end from public.profiles
 where sector='PRODUÇÃO' and role in('gerente','supervisor') and not coalesce(is_master,false) on conflict do nothing;
create or replace function pdi_performance_private.is_indicator_admin()
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select auth.uid() is not null and exists(select 1 from public.profiles p where p.id=auth.uid() and(coalesce(p.is_master,false) or p.role in('master','diretor','diretoria'))) $$;
revoke all on function pdi_performance_private.is_indicator_admin() from public,anon;
grant execute on function pdi_performance_private.is_indicator_admin() to authenticated;
alter table public.pdi_indicator_areas enable row level security;alter table public.pdi_indicator_modules enable row level security;alter table public.pdi_area_memberships enable row level security;alter table public.pdi_indicator_settings enable row level security;alter table public.pdi_area_access_audit enable row level security;
revoke all on public.pdi_indicator_areas,public.pdi_indicator_modules,public.pdi_area_memberships,public.pdi_indicator_settings,public.pdi_area_access_audit from public,anon,authenticated;
grant select on public.pdi_indicator_areas,public.pdi_indicator_modules,public.pdi_area_memberships,public.pdi_indicator_settings,public.pdi_area_access_audit to authenticated;
drop policy if exists pdi_areas_read on public.pdi_indicator_areas;create policy pdi_areas_read on public.pdi_indicator_areas for select to authenticated using(true);
drop policy if exists pdi_modules_read on public.pdi_indicator_modules;create policy pdi_modules_read on public.pdi_indicator_modules for select to authenticated using(true);
drop policy if exists pdi_settings_read on public.pdi_indicator_settings;create policy pdi_settings_read on public.pdi_indicator_settings for select to authenticated using(true);
drop policy if exists pdi_members_read on public.pdi_area_memberships;create policy pdi_members_read on public.pdi_area_memberships for select to authenticated using(profile_id=(select auth.uid()) or pdi_performance_private.is_indicator_admin());
drop policy if exists pdi_access_audit_read on public.pdi_area_access_audit;create policy pdi_access_audit_read on public.pdi_area_access_audit for select to authenticated using(pdi_performance_private.is_indicator_admin());
create or replace function pdi_performance_private.module_level(p_module text)
returns text language sql stable security invoker set search_path=pg_catalog
as $$ select case when pdi_performance_private.is_indicator_admin() and(select director_read_all from public.pdi_indicator_settings where id) then 'director'
 else(select a.access_level from public.pdi_area_memberships a where a.profile_id=auth.uid() and a.area_key=m.area_key) end
 from public.pdi_indicator_modules m join public.pdi_indicator_areas r on r.area_key=m.area_key
 where m.module_key=p_module and m.enabled and r.active and auth.uid() is not null $$;
create or replace function pdi_performance_private.can_view_module(p_module text)
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select coalesce(pdi_performance_private.module_level(p_module) in('director','manager','supervisor'),false) $$;
create or replace function pdi_performance_private.can_correct_module(p_module text)
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select coalesce(pdi_performance_private.module_level(p_module)='supervisor',false) and not pdi_performance_private.is_indicator_admin()
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('employee','colaborador','supervisor')) $$;
create or replace function pdi_performance_private.can_collect_module(p_module text)
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select auth.uid() is not null and not pdi_performance_private.is_indicator_admin()
 and coalesce(pdi_performance_private.module_level(p_module),'')<>'manager' and exists(
 select 1 from public.profiles p join public.pdi_indicator_modules m on m.module_key=p_module join public.pdi_indicator_areas r on r.area_key=m.area_key
 where p.id=auth.uid() and p.role in('employee','colaborador','supervisor') and (p.role<>'supervisor' or pdi_performance_private.can_correct_module(p_module)) and m.enabled and r.active
 and case m.collector_rule when 'pcp' then lower(btrim(coalesce(p.position,'')))='pcp' when 'cash' then pdi_performance_private.is_cash_position(p.position) else false end) $$;
create or replace function pdi_performance_private.can_operate_module(p_module text)
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select pdi_performance_private.can_collect_module(p_module) or pdi_performance_private.can_correct_module(p_module) $$;
create or replace function pdi_performance_private.can_audit_module(p_module text)
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select coalesce(pdi_performance_private.module_level(p_module) in('director','manager'),false) $$;
revoke all on function pdi_performance_private.module_level(text),pdi_performance_private.can_view_module(text),pdi_performance_private.can_correct_module(text),pdi_performance_private.can_collect_module(text),pdi_performance_private.can_operate_module(text),pdi_performance_private.can_audit_module(text) from public,anon;
grant execute on function pdi_performance_private.module_level(text),pdi_performance_private.can_view_module(text),pdi_performance_private.can_correct_module(text),pdi_performance_private.can_collect_module(text),pdi_performance_private.can_operate_module(text),pdi_performance_private.can_audit_module(text) to authenticated;
create or replace function pdi_performance_private.set_area_access(p_profile uuid,p_area text,p_level text)
returns void language plpgsql security definer set search_path=pg_catalog
as $$ declare old_row jsonb; new_row jsonb; target public.profiles%rowtype; begin
 if auth.uid() is null or not pdi_performance_private.is_indicator_admin() then raise exception 'Administração de áreas restrita à Diretoria.' using errcode='42501';end if;
 select * into target from public.profiles where id=p_profile;if target.id is null then raise exception 'Perfil não encontrado.' using errcode='22023';end if;
 if not exists(select 1 from public.pdi_indicator_areas where area_key=p_area and active) or(p_level is not null and p_level not in('manager','supervisor'))then raise exception 'Área ou responsabilidade inválida.' using errcode='22023';end if;
 if p_level='supervisor' and(coalesce(target.is_master,false) or target.role in('gerente','master','diretor','diretoria'))then raise exception 'Contas de gerência/Diretoria mantêm consulta. Use Gerência para autorizar a área.' using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_profile::text||':'||p_area,0));
 select to_jsonb(m) into old_row from public.pdi_area_memberships m where profile_id=p_profile and area_key=p_area;
 if p_level is null then delete from public.pdi_area_memberships where profile_id=p_profile and area_key=p_area;
 else insert into public.pdi_area_memberships(profile_id,area_key,access_level,assigned_by) values(p_profile,p_area,p_level,auth.uid()) on conflict(profile_id,area_key) do update set access_level=excluded.access_level,assigned_by=auth.uid(),assigned_at=clock_timestamp();end if;
 select to_jsonb(m) into new_row from public.pdi_area_memberships m where profile_id=p_profile and area_key=p_area;
 if old_row is distinct from new_row then insert into public.pdi_area_access_audit(actor_id,action,before_data,after_data)values(auth.uid(),case when p_level is null then 'REVOKE' else 'GRANT' end,old_row,new_row);end if;
 end $$;
revoke all on function pdi_performance_private.set_area_access(uuid,text,text) from public,anon;
grant execute on function pdi_performance_private.set_area_access(uuid,text,text) to authenticated;
create or replace function public.pdi_set_area_access(p_profile_id uuid,p_area_key text,p_access_level text)
returns void language sql security invoker set search_path=pg_catalog as $$ select pdi_performance_private.set_area_access(p_profile_id,p_area_key,p_access_level) $$;
revoke all on function public.pdi_set_area_access(uuid,text,text) from public,anon;grant execute on function public.pdi_set_area_access(uuid,text,text) to authenticated;
create or replace function public.pdi_module_access_context()
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog
as $$ declare result jsonb;begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501';end if;
 select coalesce(jsonb_agg(jsonb_build_object('module_key',m.module_key,'area_key',m.area_key,'label',m.label,'page_key',m.page_key,'area_label',a.label,
 'can_view',pdi_performance_private.can_view_module(m.module_key),'can_correct',pdi_performance_private.can_correct_module(m.module_key),'can_collect',pdi_performance_private.can_collect_module(m.module_key),'level',pdi_performance_private.module_level(m.module_key)) order by m.module_key),'[]')into result from public.pdi_indicator_modules m join public.pdi_indicator_areas a on a.area_key=m.area_key where m.enabled and a.active;
 return jsonb_build_object('today',pdi_performance_private.today_manaus(),'is_admin',pdi_performance_private.is_indicator_admin(),'modules',result,'memberships',(select coalesce(jsonb_agg(jsonb_build_object('area_key',m.area_key,'area_label',a.label,'access_level',m.access_level)),'[]')from public.pdi_area_memberships m join public.pdi_indicator_areas a on a.area_key=m.area_key where m.profile_id=auth.uid()));end $$;
revoke all on function public.pdi_module_access_context() from public,anon;grant execute on function public.pdi_module_access_context() to authenticated;
create or replace function public.pdi_area_admin_context()
returns jsonb language plpgsql stable security invoker set search_path=pg_catalog
as $$ begin
 if not pdi_performance_private.is_indicator_admin() then raise exception 'Acesso restrito à Diretoria.' using errcode='42501';end if;
 return jsonb_build_object('areas',(select coalesce(jsonb_agg(to_jsonb(a)order by label),'[]')from public.pdi_indicator_areas a where active),
 'memberships',(select coalesce(jsonb_agg(to_jsonb(m)),'[]')from public.pdi_area_memberships m),
 'profiles',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'full_name',p.full_name,'position',p.position,'role',p.role,'sector',p.sector,'is_master',p.is_master)order by full_name),'[]')from public.profiles p),
 'modules',(select coalesce(jsonb_agg(to_jsonb(m)),'[]')from public.pdi_indicator_modules m),
 'audit',(select coalesce(jsonb_agg(to_jsonb(x)),'[]')from(select * from public.pdi_area_access_audit order by occurred_at desc limit 30)x));end $$;
revoke all on function public.pdi_area_admin_context() from public,anon;grant execute on function public.pdi_area_admin_context() to authenticated;
commit;
