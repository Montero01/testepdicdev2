begin;
-- Não muda a privacidade do bucket já usado pelo PDI e Academy.
drop policy if exists pdi_avatar_insert_guard on storage.objects;
create policy pdi_avatar_insert_guard on storage.objects as restrictive for insert to authenticated with check(bucket_id<>'avatars' or split_part(name,'/',1)=(select auth.uid())::text);
drop policy if exists pdi_avatar_update_guard on storage.objects;
create policy pdi_avatar_update_guard on storage.objects as restrictive for update to authenticated using(bucket_id<>'avatars' or split_part(name,'/',1)=(select auth.uid())::text) with check(bucket_id<>'avatars' or split_part(name,'/',1)=(select auth.uid())::text);
drop policy if exists pdi_avatar_delete_guard on storage.objects;
create policy pdi_avatar_delete_guard on storage.objects as restrictive for delete to authenticated using(bucket_id<>'avatars' or split_part(name,'/',1)=(select auth.uid())::text);
-- Direitos PDI continuam independentes das responsabilidades financeiras/produção.
create or replace function pdi_performance_private.can_read_pdi(p_owner uuid)
returns boolean language sql stable security invoker set search_path=pg_catalog as $$ select auth.uid() is not null and(p_owner=auth.uid() or pdi_performance_private.is_indicator_admin() or exists(select 1 from public.profiles a join public.profiles p on p.id=p_owner and p.sector=a.sector where a.id=auth.uid() and a.role in('gerente','supervisor'))) $$;
create or replace function pdi_performance_private.can_manage_pdi(p_owner uuid)
returns boolean language sql stable security invoker set search_path=pg_catalog as $$ select auth.uid() is not null and(pdi_performance_private.is_indicator_admin() or exists(select 1 from public.profiles a join public.profiles p on p.id=p_owner and p.sector=a.sector where a.id=auth.uid() and a.role='gerente')) $$;
revoke all on function pdi_performance_private.can_read_pdi(uuid),pdi_performance_private.can_manage_pdi(uuid) from public,anon;
grant execute on function pdi_performance_private.can_read_pdi(uuid),pdi_performance_private.can_manage_pdi(uuid) to authenticated;
-- Políticas restritivas neutralizam políticas permissivas legadas sem removê-las.
create policy pdi_goals_read_guard on public.goals as restrictive for select to authenticated using(pdi_performance_private.can_read_pdi(user_id));
create policy pdi_goals_insert_guard on public.goals as restrictive for insert to authenticated with check(pdi_performance_private.can_manage_pdi(user_id));
create policy pdi_goals_update_guard on public.goals as restrictive for update to authenticated using(pdi_performance_private.can_manage_pdi(user_id)) with check(pdi_performance_private.can_manage_pdi(user_id));
create policy pdi_goals_delete_guard on public.goals as restrictive for delete to authenticated using(pdi_performance_private.can_manage_pdi(user_id));
create policy pdi_certs_read_guard on public.certificates as restrictive for select to authenticated using(pdi_performance_private.can_read_pdi(user_id));
create policy pdi_certs_insert_guard on public.certificates as restrictive for insert to authenticated with check(user_id=(select auth.uid()) and status='pending' and coalesce(points_awarded,0)=0 and validated_at is null and validated_by is null and exists(select 1 from public.goals g where g.id=goal_id and g.user_id=(select auth.uid())));
create policy pdi_certs_update_guard on public.certificates as restrictive for update to authenticated using(pdi_performance_private.can_manage_pdi(user_id)) with check(pdi_performance_private.can_manage_pdi(user_id));
create policy pdi_certs_delete_guard on public.certificates as restrictive for delete to authenticated using(pdi_performance_private.can_manage_pdi(user_id));
alter table public.certificates add column if not exists review_note text,add column if not exists revision integer not null default 1;
create or replace function pdi_performance_private.guard_certificate_review()
returns trigger language plpgsql security invoker set search_path=pg_catalog as $$
declare g public.goals%rowtype;trusted boolean:=coalesce(current_setting('role',true),'none')='service_role' or(coalesce(current_setting('role',true),'none') in('none','postgres') and session_user in('postgres','supabase_admin'));begin
 select * into g from public.goals where id=new.goal_id;
 if g.id is null or g.user_id<>new.user_id then raise exception 'Comprovante não corresponde ao titular da meta.' using errcode='22023';end if;
 if tg_op='UPDATE' then
 if not trusted and not pdi_performance_private.can_manage_pdi(old.user_id) then raise exception 'Avaliação restrita à gerência.' using errcode='42501';end if;
 if row(new.id,new.user_id,new.goal_id,new.file_url,new.file_name,new.file_url_2,new.file_name_2,new.submitted_at) is distinct from row(old.id,old.user_id,old.goal_id,old.file_url,old.file_name,old.file_url_2,old.file_name_2,old.submitted_at) then raise exception 'Origem e arquivos não podem ser alterados.' using errcode='22023';end if;
 if not trusted then new.validated_by:=auth.uid();new.validated_at:=clock_timestamp();end if;
 new.revision:=old.revision+1;
 else
 if not trusted then new.status:='pending';new.points_awarded:=0;new.validated_by:=null;new.validated_at:=null;new.submitted_at:=clock_timestamp();new.revision:=1;new.review_note:=null;end if;
 end if;
 if new.points_awarded is null or new.points_awarded<0 or new.points_awarded>g.max_points or(new.status<>'approved' and new.points_awarded<>0) or length(coalesce(new.review_note,''))>500 then raise exception 'Confira a pontuação e a observação.' using errcode='22023';end if;
 return new;end $$;
revoke all on function pdi_performance_private.guard_certificate_review() from public,anon,authenticated;
create trigger pdi_guard_certificate_review before insert or update on public.certificates for each row execute function pdi_performance_private.guard_certificate_review();
-- Evita reenvio concorrente ou pontuação duplicada da mesma meta.
create unique index if not exists pdi_one_active_certificate on public.certificates(goal_id) where status in('pending','approved');
create or replace function pdi_performance_private.can_read_certificate_file(p_path text)
returns boolean language sql stable security definer set search_path=pg_catalog as $$ select auth.uid() is not null and(split_part(p_path,'/',1)=auth.uid()::text or exists(select 1 from public.certificates c where(p_path=c.file_url or p_path=c.file_url_2)and pdi_performance_private.can_read_pdi(c.user_id))) $$;
revoke all on function pdi_performance_private.can_read_certificate_file(text) from public,anon;grant execute on function pdi_performance_private.can_read_certificate_file(text) to authenticated;
create policy pdi_certificate_storage_read_guard on storage.objects as restrictive for select to authenticated using(bucket_id<>'certificates' or pdi_performance_private.can_read_certificate_file(name));
create policy pdi_certificate_storage_insert_guard on storage.objects as restrictive for insert to authenticated with check(bucket_id<>'certificates' or split_part(name,'/',1)=(select auth.uid())::text);
create policy pdi_certificate_storage_update_guard on storage.objects as restrictive for update to authenticated using(bucket_id<>'certificates') with check(bucket_id<>'certificates');
create policy pdi_certificate_storage_delete_guard on storage.objects as restrictive for delete to authenticated using(bucket_id<>'certificates');
notify pgrst,'reload schema';commit;
