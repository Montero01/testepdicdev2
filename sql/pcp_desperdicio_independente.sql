-- Desperdício por PCP/dia, sem criar valores fictícios no resultado diário.
lock table public.pdi_pcp_waste in access exclusive mode;
do $$begin if exists(select 1 from public.pdi_pcp_waste)then raise exception 'Há desperdícios existentes: revisar a migração e o backfill antes de aplicar.';end if;end$$;
alter table public.pdi_pcp_waste drop constraint pdi_pcp_waste_entry_id_fkey;
alter table public.pdi_pcp_waste rename column entry_id to id;
alter table public.pdi_pcp_waste alter column id set default gen_random_uuid();
alter table public.pdi_pcp_waste add column entry_id uuid references public.pdi_pcp_daily(id)on delete restrict,
 add column pcp_id uuid not null references public.profiles(id),add column work_date date not null,
 add column pcp_name_snapshot text not null default '',add column sector_snapshot text,add column notes text not null default '' check(length(notes)<=1000);
create unique index pdi_pcp_waste_active_day on public.pdi_pcp_waste(pcp_id,work_date)where not is_deleted;
create unique index pdi_pcp_waste_active_entry on public.pdi_pcp_waste(entry_id)where not is_deleted and entry_id is not null;
drop policy pdi_waste_read on public.pdi_pcp_waste;
create policy pdi_waste_read on public.pdi_pcp_waste for select to authenticated using(pcp_id=(select auth.uid())or pdi_performance_private.can_view_module('pcp_m2'));
update public.pdi_indicator_modules set deletion_targets=jsonb_set(deletion_targets,'{waste,pk}','"id"')where module_key='pcp_m2';

create or replace function pdi_performance_private.guard_pcp_waste()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d public.pdi_pcp_daily%rowtype;p public.profiles%rowtype;linking boolean:=false;begin
 if tg_op='INSERT'and new.is_deleted then raise exception 'Não é permitido inserir registro excluído.'using errcode='42501';end if;
 if tg_op='UPDATE'and pdi_performance_private.soft_delete_guard(to_jsonb(old),to_jsonb(new))then new.updated_by:=auth.uid();new.updated_at:=clock_timestamp();new.revision:=old.revision+1;return new;end if;
 if tg_op='UPDATE'then linking:=pg_trigger_depth()>1 and old.entry_id is null and new.entry_id is not null and(to_jsonb(new)-array['entry_id','reason','revision','updated_at','updated_by'])=(to_jsonb(old)-array['entry_id','reason','revision','updated_at','updated_by']);end if;
 if auth.uid()is null or(not linking and not pdi_performance_private.can_record_pcp_waste())then raise exception 'Desperdício restrito à supervisão e gerência autorizada de Produção.'using errcode='42501';end if;
 if new.entry_id is not null then select *into d from public.pdi_pcp_daily where id=new.entry_id and not is_deleted; if not found then raise exception 'Lançamento diário não encontrado.'using errcode='22023';end if;new.pcp_id:=coalesce(new.pcp_id,d.pcp_id);new.work_date:=coalesce(new.work_date,d.work_date);if new.pcp_id<>d.pcp_id or new.work_date<>d.work_date then raise exception 'O desperdício e o resultado diário precisam ser do mesmo PCP e dia.'using errcode='22023';end if;end if;
 if new.work_date is null or not isfinite(new.work_date)or new.work_date<'2020-01-01'or new.work_date>pdi_performance_private.today_manaus()then raise exception 'Escolha uma data válida até hoje.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('pcp-waste:'||new.pcp_id::text||':'||new.work_date::text,0));
 select *into p from public.profiles where id=new.pcp_id;
 if p.id is null or(lower(btrim(coalesce(p.position,'')))<>'pcp'and pdi_access_private.mode('pcp_m2',p.id)is distinct from'collect')then raise exception 'Selecione um PCP cadastrado ou autorizado para coleta.'using errcode='22023';end if;
 if new.m2_wasted is null or new.m2_wasted::text in('NaN','Infinity','-Infinity')or new.m2_wasted<0 or new.m2_wasted>=1000000000 or scale(new.m2_wasted)>3 then raise exception 'Informe o desperdício em m², com até três casas decimais.'using errcode='22023';end if;
 if d.id is not null and d.m2_analyzed is not null and new.m2_wasted+d.m2_saved>d.m2_analyzed then raise exception 'Desperdício mais m² salvos não podem superar os analisados.'using errcode='22023';end if;
 if linking then new.revision:=old.revision+1;new.reason:='Vinculação automática ao resultado diário do PCP';
 elsif tg_op='INSERT'then new.revision:=1;new.created_at:=clock_timestamp();new.created_by:=auth.uid();new.pcp_name_snapshot:=coalesce(p.full_name,'PCP');new.sector_snapshot:=p.sector;new.reason:=coalesce(nullif(btrim(new.reason),''),'Registro inicial de desperdício');
 else
 if row(new.id,new.entry_id,new.pcp_id,new.work_date,new.created_at,new.created_by,new.pcp_name_snapshot,new.sector_snapshot)is distinct from row(old.id,old.entry_id,old.pcp_id,old.work_date,old.created_at,old.created_by,old.pcp_name_snapshot,old.sector_snapshot)then raise exception 'A identidade e a origem do desperdício não podem ser alteradas.'using errcode='22023';end if;
 if new.m2_wasted=old.m2_wasted then raise exception 'Não há alteração no desperdício.'using errcode='22023';end if;
 if length(btrim(coalesce(new.reason,'')))not between 10 and 300 then raise exception 'Justifique a correção em 10 a 300 caracteres.'using errcode='22023';end if;new.revision:=old.revision+1;
 end if;
 if length(coalesce(new.reason,''))>300 then raise exception 'Observação: máximo de 300 caracteres.'using errcode='22023';end if;
 new.updated_at:=clock_timestamp();new.updated_by:=auth.uid();return new;
end$$;
create or replace function pdi_performance_private.audit_pcp_waste()returns trigger language plpgsql security definer set search_path=pg_catalog as $$
declare d public.pdi_pcp_daily%rowtype;a public.profiles%rowtype;meta jsonb;before_row jsonb;begin
 select *into a from public.profiles where id=auth.uid();meta:=jsonb_build_object('work_date',new.work_date,'pcp_name_snapshot',new.pcp_name_snapshot,'pending_daily',new.entry_id is null);
 before_row:=case when tg_op='UPDATE'then to_jsonb(old)else null end;
 if new.entry_id is null then perform pdi_performance_private.record_event('pcp_m2','desperdicio',case when tg_op='INSERT'then'PCP_WASTE_CREATED'else'PCP_WASTE_UPDATED'end,new.pcp_id,before_row,to_jsonb(new)||meta,new.reason);
 else
 select *into d from public.pdi_pcp_daily where id=new.entry_id;
 insert into public.pdi_performance_audit(entry_id,pcp_id,sector_snapshot,module_key,action,actor_id,actor_name,actor_role,database_actor,reason,before_data,after_data,area_key_snapshot,access_level_snapshot)
 values(d.id,new.pcp_id,new.sector_snapshot,'pcp_waste',tg_op,auth.uid(),a.full_name,a.role,session_user||'/'||coalesce(current_setting('role',true),'none'),new.reason,before_row,to_jsonb(new)||meta,'producao',pdi_performance_private.module_level('pcp_m2'));
 end if;return new;
end$$;
create function pdi_performance_private.link_pcp_waste()returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if not new.is_deleted then update public.pdi_pcp_waste set entry_id=new.id where pcp_id=new.pcp_id and work_date=new.work_date and entry_id is null and not is_deleted;end if;return new;
end$$;
revoke all on function pdi_performance_private.link_pcp_waste()from public,anon,authenticated;
create trigger pdi_link_pcp_waste after insert on public.pdi_pcp_daily for each row execute function pdi_performance_private.link_pcp_waste();

create function pdi_performance_private.save_pcp_waste(p_pcp_id uuid,p_day date,p_m2_wasted numeric,p_id uuid,p_revision integer,p_reason text)returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
declare d public.pdi_pcp_daily%rowtype;w public.pdi_pcp_waste%rowtype;result jsonb;begin
 perform pdi_access_private.assert_allowed('pcp_m2',true);
 if not pdi_performance_private.can_record_pcp_waste()then raise exception 'Desperdício restrito à supervisão e gerência autorizada de Produção.'using errcode='42501';end if;
 if p_pcp_id is null or p_day is null or not isfinite(p_day)or p_day<'2020-01-01'or p_day>pdi_performance_private.today_manaus()then raise exception 'Selecione o PCP e uma data válida até hoje.'using errcode='22023';end if;
 perform pg_advisory_xact_lock(hashtextextended('pcp-waste:'||p_pcp_id::text||':'||p_day::text,0));
 if p_id is not null then select *into w from public.pdi_pcp_waste where id=p_id for update;end if;
 if w.id is null then select *into w from public.pdi_pcp_waste where pcp_id=p_pcp_id and work_date=p_day for update;end if;
 if w.id is not null then
 if p_revision is null and w.id=p_id and w.pcp_id=p_pcp_id and w.work_date=p_day and w.m2_wasted=p_m2_wasted then return to_jsonb(w)||jsonb_build_object('already_saved',true);end if;
 if w.revision is distinct from p_revision or w.id is distinct from p_id then raise exception 'Já existe desperdício para este PCP/dia ou o registro mudou. Atualize e abra os ajustes.'using errcode='40001';end if;
 if w.pcp_id<>p_pcp_id or w.work_date<>p_day then raise exception 'PCP e data do registro não podem ser alterados.'using errcode='22023';end if;
 update public.pdi_pcp_waste set m2_wasted=p_m2_wasted,reason=p_reason where id=w.id and revision=p_revision returning to_jsonb(pdi_pcp_waste.*)into result;
 else
 if p_revision is not null then raise exception 'O desperdício não está mais disponível. Atualize a página.'using errcode='40001';end if;
 select id into d.id from public.pdi_pcp_daily where pcp_id=p_pcp_id and work_date=p_day;
 insert into public.pdi_pcp_waste(id,entry_id,pcp_id,work_date,m2_wasted,reason,notes)values(coalesce(p_id,gen_random_uuid()),d.id,p_pcp_id,p_day,p_m2_wasted,p_reason,coalesce(p_reason,''))returning to_jsonb(pdi_pcp_waste.*)into result;
 end if;return result;
end$$;
revoke all on function pdi_performance_private.save_pcp_waste(uuid,date,numeric,uuid,integer,text)from public,anon;grant execute on function pdi_performance_private.save_pcp_waste(uuid,date,numeric,uuid,integer,text)to authenticated;
create function public.pdi_pcp_waste_save(p_pcp_id uuid,p_day date,p_m2_wasted numeric,p_id uuid default null,p_revision integer default null,p_reason text default null)returns jsonb language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.save_pcp_waste(p_pcp_id,p_day,p_m2_wasted,p_id,p_revision,p_reason)$$;
revoke all on function public.pdi_pcp_waste_save(uuid,date,numeric,uuid,integer,text)from public,anon;grant execute on function public.pdi_pcp_waste_save(uuid,date,numeric,uuid,integer,text)to authenticated;
notify pgrst,'reload schema';
-- Leitura dos novos metadados segue a RLS: próprio PCP ou gestão autorizada.
grant select(entry_id,pcp_id,work_date,pcp_name_snapshot,sector_snapshot,reason,notes)on public.pdi_pcp_waste to authenticated;
