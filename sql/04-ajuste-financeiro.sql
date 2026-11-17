begin;
-- Solicitação atual: Financeiro sem supervisão; gerência por atribuição explícita.
insert into public.pdi_area_memberships(profile_id,area_key,access_level)
 select id,'financeiro','manager' from public.profiles where sector='ADMINISTRATIVO' and role='gerente' and not coalesce(is_master,false) on conflict do nothing;
create or replace function pdi_performance_private.can_correct_module(p_module text)
returns boolean language sql stable security invoker set search_path=pg_catalog
as $$ select p_module<>'cash_daily' and coalesce(pdi_performance_private.module_level(p_module)='supervisor',false) and not pdi_performance_private.is_indicator_admin()
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in('employee','colaborador','supervisor')) $$;
alter table public.pdi_area_memberships add constraint pdi_finance_manager_only check(area_key<>'financeiro' or access_level='manager');
create or replace function pdi_performance_private.guard_goal_values()
returns trigger language plpgsql security invoker set search_path=pg_catalog as $$ begin
 if new.title is null or length(btrim(new.title))=0 or new.max_points is null or new.max_points<0 or new.max_points>100000 then raise exception 'Informe um título e pontos válidos.' using errcode='22023';end if;
 if tg_op='UPDATE' then
 if row(new.id,new.user_id,new.created_at) is distinct from row(old.id,old.user_id,old.created_at) then raise exception 'Identidade e titular da meta não podem mudar.' using errcode='22023';end if;
 if exists(select 1 from public.certificates c where c.goal_id=old.id and c.status='approved' and c.points_awarded>new.max_points)then raise exception 'Os pontos máximos não podem ficar abaixo dos pontos aprovados.' using errcode='22023';end if;end if;return new;end $$;
revoke all on function pdi_performance_private.guard_goal_values() from public,anon,authenticated;
create trigger pdi_guard_goal_values before insert or update on public.goals for each row execute function pdi_performance_private.guard_goal_values();
notify pgrst,'reload schema';commit;
