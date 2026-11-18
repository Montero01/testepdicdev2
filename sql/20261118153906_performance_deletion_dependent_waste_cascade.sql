begin;
create or replace function pdi_performance_private.delete_performance(p_module text,p_entity text,p_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path=pg_catalog as $$declare cfg jsonb;t text;pk text;before_row jsonb;k uuid;child_id uuid;begin
 if not pdi_performance_private.performance_manager()then raise exception 'Exclusão restrita à gerência e Diretoria.'using errcode='42501';end if;
 if length(btrim(coalesce(p_reason,'')))not between 10 and 300 then raise exception 'Justifique a exclusão em 10 a 300 caracteres.'using errcode='22023';end if;
 select deletion_targets->p_entity into cfg from public.pdi_indicator_modules where module_key=p_module and enabled;
 t:=cfg->>'table';pk:=cfg->>'pk';if t is null or pk not in('id','entry_id')or t!~'^pdi_[a-z0-9_]+$'then raise exception 'Processo não habilitado para exclusão.'using errcode='22023';end if;
 execute format('select to_jsonb(x)from public.%I x where %I=$1 and not is_deleted for update',t,pk)into before_row using p_id;
 if before_row is null or(p_module='stock'and before_row->>'origin_module'<>'stock')then raise exception 'Registro não encontrado neste processo.'using errcode='22023';end if;
 execute format('update public.%I set is_deleted=true where %I=$1',t,pk)using p_id;
 if t='pdi_pcp_daily'and exists(select 1 from public.pdi_pcp_waste where entry_id=p_id and not is_deleted)then perform pdi_performance_private.delete_performance('pcp_m2','waste',p_id,p_reason);end if;
 if t='pdi_logistics_records'and before_row->>'kind'='movement'and before_row->>'origin_module'='stock'then for child_id in select id from public.pdi_logistics_records where kind='stock_waste'and not is_deleted and data->>'stock_entry'=p_id::text loop perform pdi_performance_private.delete_performance('stock','records',child_id,p_reason);end loop;end if;
 k:=pdi_performance_private.record_event(case when p_module='stock'then'logistics'else p_module end,'exclusao','PERFORMANCE_DELETED',coalesce((before_row->>'pcp_id')::uuid,(before_row->>'cashier_id')::uuid,(before_row->>'person_id')::uuid),before_row,jsonb_build_object('record_id',p_id,'table',t,'module',p_module,'is_deleted',true),p_reason);return k;end$$;

notify pgrst,'reload schema';commit;