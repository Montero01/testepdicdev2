begin;
create or replace function pdi_performance_private.guard_certificate_files()
returns trigger language plpgsql security invoker set search_path=pg_catalog as $$
declare path text;trusted boolean:=coalesce(current_setting('role',true),'none')='service_role' or(coalesce(current_setting('role',true),'none') in('none','postgres') and session_user in('postgres','supabase_admin'));begin
 if trusted then return new;end if;
 if new.user_id is distinct from auth.uid() then raise exception 'Envie somente os próprios comprovantes.' using errcode='42501';end if;
 if new.file_url is null or new.file_url='' then raise exception 'Anexe pelo menos um comprovante.' using errcode='22023';end if;
 foreach path in array array[new.file_url,new.file_url_2] loop
 if path is not null and path<>'' then
 if split_part(path,'/',1)<>auth.uid()::text or not exists(select 1 from storage.objects o where o.bucket_id='certificates' and o.name=path and lower(o.metadata->>'mimetype')in('application/pdf','image/png','image/jpeg') and(o.metadata->>'size')::numeric between 1 and 20971520)then raise exception 'Comprovante não enviado ou fora do seu perfil. Use PDF, PNG ou JPG de até 20 MB.' using errcode='22023';end if;end if;end loop;return new;end $$;
revoke all on function pdi_performance_private.guard_certificate_files()from public,anon,authenticated;
create trigger pdi_guard_certificate_files before insert on public.certificates for each row execute function pdi_performance_private.guard_certificate_files();
notify pgrst,'reload schema';commit;
