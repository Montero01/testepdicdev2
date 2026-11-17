begin;
create table public.pdi_performance_events(id uuid primary key default gen_random_uuid(),module_key text not null,process text not null,action text not null,subject_id uuid,actor_id uuid,actor_name text not null,actor_email text,actor_role text,database_actor text not null,occurred_at timestamptz not null default clock_timestamp(),reason text,before_data jsonb,after_data jsonb);
create index pdi_events_time_idx on public.pdi_performance_events(module_key,occurred_at desc,id);
alter table public.pdi_performance_events enable row level security;
revoke all on public.pdi_performance_events from public,anon,authenticated;grant select on public.pdi_performance_events to authenticated;
create policy pdi_events_read on public.pdi_performance_events for select to authenticated using(pdi_performance_private.can_audit_module(module_key)and(process not in('acessos','configuracao')or pdi_performance_private.is_indicator_admin()));
create or replace function pdi_performance_private.record_event(p_module text,p_process text,p_action text,p_subject uuid,p_before jsonb,p_after jsonb,p_reason text default null)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare p public.profiles%rowtype;k uuid;caller text:=coalesce(current_setting('role',true),'none');begin
 if auth.uid()is null and not(caller='service_role'or(caller in('none','postgres')and session_user in('postgres','supabase_admin')))then raise exception 'Autenticação necessária.'using errcode='42501';end if;
 select *into p from public.profiles where id=auth.uid();
 insert into public.pdi_performance_events(module_key,process,action,subject_id,actor_id,actor_name,actor_email,actor_role,database_actor,reason,before_data,after_data)
 values(p_module,p_process,p_action,p_subject,auth.uid(),coalesce(p.full_name,'Operação administrativa'),coalesce((select email from auth.users where id=auth.uid()),p.email),p.role,session_user||'/'||caller,p_reason,p_before,p_after)returning id into k;return k;end $$;
revoke all on function pdi_performance_private.record_event(text,text,text,uuid,jsonb,jsonb,text)from public,anon;grant execute on function pdi_performance_private.record_event(text,text,text,uuid,jsonb,jsonb,text)to authenticated;
create or replace function pdi_performance_private.audit_cash_file_lifecycle()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if tg_op='INSERT'or(new.attached_at is distinct from old.attached_at and new.attached_at is not null)then
 perform pdi_performance_private.record_event('cash_daily','arquivos',case when tg_op='INSERT'then'PDF_RESERVED'else'PDF_ATTACHED'end,new.cashier_id,case when tg_op='UPDATE'then to_jsonb(old)else null end,to_jsonb(new),null);end if;return new;end $$;
revoke all on function pdi_performance_private.audit_cash_file_lifecycle()from public,anon,authenticated;
create trigger pdi_audit_cash_file_lifecycle after insert or update on public.pdi_cash_files for each row execute function pdi_performance_private.audit_cash_file_lifecycle();
create or replace function pdi_performance_private.audit_pdf_change()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$begin
 if new.pdf_file_id is distinct from old.pdf_file_id then perform pdi_performance_private.record_event('cash_daily','arquivos',case when new.pdf_file_id is null then'PDF_REMOVED'when old.pdf_file_id is null then'PDF_ADDED'else'PDF_REPLACED'end,new.cashier_id,jsonb_build_object('pdf_file_id',old.pdf_file_id,'file_name',old.pdf_name_snapshot,'work_date',old.work_date),jsonb_build_object('pdf_file_id',new.pdf_file_id,'file_name',new.pdf_name_snapshot,'work_date',new.work_date),new.edit_reason);end if;return new;end $$;
revoke all on function pdi_performance_private.audit_pdf_change()from public,anon,authenticated;
create trigger pdi_audit_pdf_change after update on public.pdi_cash_daily for each row execute function pdi_performance_private.audit_pdf_change();
create or replace function pdi_performance_private.cash_file_event(p_file uuid,p_action text)
returns uuid language plpgsql security definer set search_path=pg_catalog as $$
declare f public.pdi_cash_files%rowtype;k uuid;begin
 if auth.uid()is null or p_action not in('PDF_UPLOAD_CONFIRMED','PDF_UPLOAD_FAILED','PDF_DOWNLOAD_REQUESTED','PDF_DOWNLOAD_TRIGGERED','PDF_DOWNLOAD_FAILED')then raise exception 'Operação inválida.'using errcode='42501';end if;
 select *into f from public.pdi_cash_files where id=p_file;
 if f.id is null or not pdi_performance_private.cash_file_can_read(f.storage_path)then raise exception 'Arquivo fora do seu acesso.'using errcode='42501';end if;
 if p_action like 'PDF_UPLOAD%'and f.uploaded_by<>auth.uid()then raise exception 'Envio fora do seu usuário.'using errcode='42501';end if;
 if p_action='PDF_UPLOAD_CONFIRMED'and(f.uploaded_by<>auth.uid()or not exists(select 1 from storage.objects o where o.bucket_id='pdi-cash-pdfs'and o.name=f.storage_path and lower(o.metadata->>'mimetype')='application/pdf'and(o.metadata->>'size')::numeric=f.size_bytes))then raise exception 'Envio do PDF não confirmado no Storage.'using errcode='22023';end if;
 if p_action like 'PDF_DOWNLOAD%'and not exists(select 1 from storage.objects where bucket_id='pdi-cash-pdfs'and name=f.storage_path)then raise exception 'PDF indisponível.'using errcode='22023';end if;
 k:=pdi_performance_private.record_event('cash_daily','arquivos',p_action,f.cashier_id,null,jsonb_build_object('file_id',f.id,'entry_id',f.entry_id,'file_name',f.original_name,'size_bytes',f.size_bytes,'work_date',f.work_date),null);return k;end $$;
revoke all on function pdi_performance_private.cash_file_event(uuid,text)from public,anon;grant execute on function pdi_performance_private.cash_file_event(uuid,text)to authenticated;
create or replace function public.pdi_cash_file_event(p_file_id uuid,p_action text)returns uuid language sql security invoker set search_path=pg_catalog as $$select pdi_performance_private.cash_file_event(p_file_id,p_action)$$;
revoke all on function public.pdi_cash_file_event(uuid,text)from public,anon;grant execute on function public.pdi_cash_file_event(uuid,text)to authenticated;
create or replace function pdi_performance_private.audit_indicator_configuration()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare oldj jsonb;newj jsonb;m record;area text;begin
 if tg_op<>'INSERT'then oldj:=to_jsonb(old);end if;if tg_op<>'DELETE'then newj:=to_jsonb(new);end if;if oldj is not distinct from newj then return new;end if;
 area:=coalesce(newj->>'area_key',oldj->>'area_key');
 for m in select coalesce(newj->>'module_key',oldj->>'module_key')module_key where tg_table_name='pdi_indicator_modules' union select module_key from public.pdi_indicator_modules where tg_table_name<>'pdi_indicator_modules'and(tg_table_name='pdi_indicator_settings'or area_key in(newj->>'area_key',oldj->>'area_key'))loop
 perform pdi_performance_private.record_event(m.module_key,case when tg_table_name='pdi_area_memberships'then'acessos'else'configuracao'end,tg_op||'_'||upper(tg_table_name),case when tg_table_name='pdi_area_memberships'then coalesce(newj->>'profile_id',oldj->>'profile_id')::uuid else null end,oldj,newj,null);end loop;
 if tg_op='DELETE'then return old;end if;return new;end $$;
revoke all on function pdi_performance_private.audit_indicator_configuration()from public,anon,authenticated;
create trigger pdi_audit_area_memberships after insert or update or delete on public.pdi_area_memberships for each row execute function pdi_performance_private.audit_indicator_configuration();
create trigger pdi_audit_indicator_modules after insert or update or delete on public.pdi_indicator_modules for each row execute function pdi_performance_private.audit_indicator_configuration();
create trigger pdi_audit_indicator_areas after insert or update or delete on public.pdi_indicator_areas for each row execute function pdi_performance_private.audit_indicator_configuration();
create trigger pdi_audit_indicator_settings after insert or update or delete on public.pdi_indicator_settings for each row execute function pdi_performance_private.audit_indicator_configuration();

create or replace function pdi_performance_private.audit_profile_performance_access()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$declare m record;begin
 for m in select module_key from public.pdi_indicator_modules where module_key in('pcp_m2','cash_daily')loop
 perform pdi_performance_private.record_event(m.module_key,'acessos','PROFILE_PERFORMANCE_ACCESS_CHANGED',new.id,jsonb_build_object('id',old.id,'role',old.role,'sector',old.sector,'position',old.position,'is_master',old.is_master),jsonb_build_object('id',new.id,'role',new.role,'sector',new.sector,'position',new.position,'is_master',new.is_master),null);end loop;return new;end $$;
revoke all on function pdi_performance_private.audit_profile_performance_access()from public,anon,authenticated;
create trigger pdi_audit_profile_performance_access after update on public.profiles for each row when(row(old.role,old.sector,old.position,old.is_master)is distinct from row(new.role,new.sector,new.position,new.is_master))execute function pdi_performance_private.audit_profile_performance_access();

create or replace function public.pdi_audit_query(p_module text,p_month date,p_search text default '',p_subject uuid default null,p_offset int default 0,p_export boolean default false)
returns jsonb language plpgsql security invoker set search_path=pg_catalog as $$
declare payload jsonb;n int;export_id uuid;start_at timestamptz;end_at timestamptz;begin
 if auth.uid()is null or p_module not in('pcp_m2','cash_daily')or not pdi_performance_private.can_audit_module(p_module)then raise exception 'Log restrito à gerência da área e Diretoria.'using errcode='42501';end if;
 if p_month is null or not isfinite(p_month)or extract(day from p_month)<>1 or p_offset<0 or length(coalesce(p_search,''))>150 then raise exception 'Mês ou pesquisa inválida.'using errcode='22023';end if;
 start_at:=p_month::timestamp at time zone 'America/Manaus';end_at:=(p_month+interval'1 month')at time zone 'America/Manaus';
 with events as materialized(
 select a.id,a.module_key,a.action,a.actor_id,a.actor_name,a.actor_role,p.email actor_email,a.database_actor,a.occurred_at,a.reason,a.before_data,a.after_data,a.pcp_id subject_id,case when a.module_key='pcp_waste'then'desperdicio'else'pcp'end process from public.pdi_performance_audit a left join public.profiles p on p.id=a.actor_id where p_module='pcp_m2'and a.occurred_at>=start_at and a.occurred_at<end_at and(p_subject is null or a.pcp_id=p_subject)
 union all select a.id,'cash_daily',a.action,a.actor_id,a.actor_name,a.actor_role,p.email,a.database_actor,a.occurred_at,a.reason,a.before_data,a.after_data,a.cashier_id,'caixa' from public.pdi_cash_audit a left join public.profiles p on p.id=a.actor_id where p_module='cash_daily'and a.occurred_at>=start_at and a.occurred_at<end_at and(p_subject is null or a.cashier_id=p_subject)

 union all select e.id,e.module_key,e.action,e.actor_id,e.actor_name,e.actor_role,e.actor_email,e.database_actor,e.occurred_at,e.reason,e.before_data,e.after_data,e.subject_id,e.process from public.pdi_performance_events e where e.module_key=p_module and e.occurred_at>=start_at and e.occurred_at<end_at and(p_subject is null or e.subject_id=p_subject)
 union all select e.id,e.module_key,'CSV_GENERATED',e.actor_id,e.actor_name,e.actor_role,e.actor_email,'application',e.created_at,null,null,to_jsonb(e),e.subject_id,'exportacao' from public.pdi_audit_exports e where e.module_key=p_module and e.created_at>=start_at and e.created_at<end_at and(p_subject is null or e.subject_id=p_subject)
 union all select e.id,e.module_key,'CSV_DOWNLOAD_TRIGGERED',e.actor_id,e.actor_name,e.actor_role,e.actor_email,'application',e.download_triggered_at,null,null,to_jsonb(e),e.subject_id,'exportacao' from public.pdi_audit_exports e where e.module_key=p_module and e.download_triggered_at>=start_at and e.download_triggered_at<end_at and(p_subject is null or e.subject_id=p_subject)

 union all select a.id,p_module,case when a.action='REVOKE'then'DELETE_PDI_AREA_MEMBERSHIPS'when a.before_data is null then'INSERT_PDI_AREA_MEMBERSHIPS'else'UPDATE_PDI_AREA_MEMBERSHIPS'end,a.actor_id,p.full_name,p.role,p.email,'legacy_access',a.occurred_at,null,a.before_data,a.after_data,coalesce(a.after_data->>'profile_id',a.before_data->>'profile_id')::uuid,'acessos' from public.pdi_area_access_audit a left join public.profiles p on p.id=a.actor_id where pdi_performance_private.is_indicator_admin()and a.occurred_at>=start_at and a.occurred_at<end_at and coalesce(a.after_data->>'area_key',a.before_data->>'area_key')=(select area_key from public.pdi_indicator_modules where module_key=p_module)and(p_subject is null or coalesce(a.after_data->>'profile_id',a.before_data->>'profile_id')::uuid=p_subject)and not exists(select 1 from public.pdi_performance_events e where e.module_key=p_module and e.process='acessos'and e.actor_id is not distinct from a.actor_id and e.before_data is not distinct from a.before_data and e.after_data is not distinct from a.after_data)
 ),filtered as materialized(select *from events e where coalesce(p_search,'')=''or strpos(lower(concat_ws(' ',e.actor_name,e.actor_email,e.actor_id::text,e.action,e.process,e.reason,e.before_data::text,e.after_data::text)),lower(p_search))>0)
 select jsonb_build_object('count',(select count(*)from filtered),'month',p_month,'rows',coalesce((select jsonb_agg(to_jsonb(x))from(select *from filtered order by occurred_at desc,id desc limit(case when p_export then 50001 else 30 end)offset(case when p_export then 0 else p_offset end))x),'[]'))into payload;
 n:=(payload->>'count')::int;if p_export then
 if n>50000 then raise exception 'Mais de 50 mil eventos: refine a pesquisa ou selecione um colaborador.'using errcode='22023';end if;
 export_id:=pdi_performance_private.record_audit_export(p_module,p_month,p_search,p_subject,n);payload:=payload||jsonb_build_object('export_id',export_id);end if;return payload;end $$;
revoke all on function public.pdi_audit_query(text,date,text,uuid,int,boolean)from public,anon;grant execute on function public.pdi_audit_query(text,date,text,uuid,int,boolean)to authenticated;

CREATE OR REPLACE FUNCTION public.pdi_cash_dashboard(p_start_date date, p_end_date date, p_cashier_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO 'pg_catalog'
AS $function$
declare a public.profiles%rowtype; g boolean; result jsonb;
begin
 if auth.uid() is null then raise exception 'Autenticação necessária.' using errcode='42501'; end if;
 select * into a from public.profiles where id=auth.uid();
 g:=coalesce(a.is_master,false) or lower(btrim(coalesce(a.role,''))) in ('master','diretor','diretoria');
 if a.id is null or not pdi_performance_private.can_view_module('cash_daily') then raise exception 'Dashboard restrito à gestão.' using errcode='42501'; end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date) or not isfinite(p_end_date) or p_start_date>p_end_date then raise exception 'Período inválido.' using errcode='22023'; end if;
 select jsonb_build_object('result_cents',coalesce(sum(d.result_cents),0)::text,'cash_cents',coalesce(sum(d.cash_cents),0)::text,'credit_cash_cents',coalesce(sum(d.credit_cash_cents),0)::text,
 'credit_installment_cents',coalesce(sum(d.credit_installment_cents),0)::text,'debit_cents',coalesce(sum(d.debit_cents),0)::text,'pix_cents',coalesce(sum(d.pix_cents),0)::text,
 'entry_count',count(*),'cashier_count',count(distinct d.cashier_id),'updated_at',statement_timestamp()) into result
 from public.pdi_cash_daily d where d.work_date between p_start_date and p_end_date and (p_cashier_id is null or d.cashier_id=p_cashier_id)
 ;
 perform pdi_performance_private.record_event('cash_daily','dashboard','DASHBOARD_VIEW',p_cashier_id,null,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'source','pdi_cash_dashboard'),null);
 return result;
end $function$;

CREATE OR REPLACE FUNCTION public.pdi_pcp_dashboard(p_start_date date, p_end_date date, p_pcp_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO 'pg_catalog'
AS $function$
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
 'ranking',coalesce((select jsonb_agg(jsonb_build_object('pcp_id',pcp_id,'name',name,'total_m2',saved::text,'total_analyzed',analyzed::text,'total_wasted',wasted::text,'entry_count',entry_count,'pending_count',pending,'utilization_percent',utilization::text,'place',place,'share_percent',coalesce(round(saved*100/nullif((select sum(saved)from g),0),2),0)::text,'bar_percent',coalesce(round(saved*100/nullif((select max(saved)from g),0),2),0)::text)order by saved desc,name)from r),'[]'),
 'daily',coalesce((select jsonb_agg(jsonb_build_object('date',work_date,'saved',saved::text,'analyzed',analyzed::text,'wasted',wasted::text,'pending_count',pending,'utilization_percent',utilization::text)order by work_date)from(select work_date,sum(m2_saved)saved,sum(m2_analyzed)analyzed,sum(m2_wasted)wasted,count(*)filter(where m2_analyzed is null or m2_wasted is null)pending,case when count(*)filter(where m2_analyzed is null or m2_wasted is null)=0 then round((sum(m2_analyzed)-sum(m2_wasted))*100/nullif(sum(m2_analyzed),0),2)end utilization from f group by work_date)x),'[]'),'updated_at',statement_timestamp())into payload;
 perform pdi_performance_private.record_event('pcp_m2','dashboard','DASHBOARD_VIEW',p_pcp_id,null,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'source','pdi_pcp_dashboard'),null);
 return payload;end $function$;

CREATE OR REPLACE FUNCTION public.pdi_performance_series(p_module text, p_start_date date, p_end_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 VOLATILE
 SET search_path TO 'pg_catalog'
AS $function$
 declare result jsonb;begin
 if auth.uid() is null or not pdi_performance_private.can_view_module(p_module) then raise exception 'Indicadores restritos à gestão da área.' using errcode='42501';end if;
 if p_start_date is null or p_end_date is null or not isfinite(p_start_date) or not isfinite(p_end_date) or p_start_date>p_end_date or p_end_date-p_start_date>1095 then raise exception 'Selecione até 3 anos.' using errcode='22023';end if;
 if p_module='pcp_m2' then
 select jsonb_build_object('days',coalesce(jsonb_agg(jsonb_build_object('date',x.work_date,'value',x.total::text,'entries',x.entries)order by x.work_date),'[]'))into result from(select work_date,sum(m2_saved)total,count(*)entries from public.pdi_pcp_daily where work_date between p_start_date and p_end_date group by work_date)x;
 elsif p_module='cash_daily' then
 select jsonb_build_object('days',coalesce(jsonb_agg(jsonb_build_object('date',x.work_date,'value',x.total::text,'entries',x.entries)order by x.work_date),'[]'))into result from(select work_date,sum(result_cents)total,count(*)entries from public.pdi_cash_daily where work_date between p_start_date and p_end_date group by work_date)x;
 else raise exception 'Módulo sem indicadores configurados.' using errcode='22023';end if;
 perform pdi_performance_private.record_event(p_module,'dashboard','DASHBOARD_VIEW',null,null,jsonb_build_object('start_date',p_start_date,'end_date',p_end_date,'source','pdi_performance_series'),null);
 return result;end $function$;
notify pgrst,'reload schema';
commit;
