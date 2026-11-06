-- Move access helpers out of the public API into a private schema.
-- Policies can still call them; the REST API can't.

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated, service_role;

create function private.is_platform_admin()
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.memberships where user_id = (select auth.uid()) and role = 'platform_admin');
$$;

create function private.is_member(p_org uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.memberships where org_id = p_org and user_id = (select auth.uid()));
$$;

create function private.has_org_role(p_org uuid, p_roles public.member_role[])
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.memberships where org_id = p_org and user_id = (select auth.uid()) and role = any (p_roles));
$$;

revoke execute on all functions in schema private from public, anon;
grant execute on all functions in schema private to authenticated, service_role;

-- Re-point policies to the private helpers.
drop policy "config admin" on public.markets;
drop policy "config admin" on public.segments;
drop policy "config admin" on public.policies;
create policy "config admin" on public.markets for all to authenticated using (private.is_platform_admin()) with check (private.is_platform_admin());
create policy "config admin" on public.segments for all to authenticated using (private.is_platform_admin()) with check (private.is_platform_admin());
create policy "config admin" on public.policies for all to authenticated using (private.is_platform_admin()) with check (private.is_platform_admin());

drop policy "orgs visible" on public.organisations;
drop policy "orgs updatable by owners" on public.organisations;
drop policy "orgs created by admins" on public.organisations;
drop policy "orgs deleted by admins" on public.organisations;
create policy "orgs visible" on public.organisations for select to authenticated
  using (kind = 'vendor' or private.is_member(id) or private.is_platform_admin());
create policy "orgs updatable by owners" on public.organisations for update to authenticated
  using (private.has_org_role(id, array['owner', 'vendor_admin']::public.member_role[]) or private.is_platform_admin())
  with check (private.has_org_role(id, array['owner', 'vendor_admin']::public.member_role[]) or private.is_platform_admin());
create policy "orgs created by admins" on public.organisations for insert to authenticated
  with check (private.is_platform_admin());
create policy "orgs deleted by admins" on public.organisations for delete to authenticated
  using (private.is_platform_admin());

drop policy "own profile" on public.profiles;
create policy "own profile" on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or private.is_platform_admin()
    or exists (
      select 1 from public.memberships mine
      join public.memberships theirs on theirs.org_id = mine.org_id
      where mine.user_id = (select auth.uid()) and theirs.user_id = profiles.id
    )
  );

drop policy "memberships visible" on public.memberships;
drop policy "memberships managed" on public.memberships;
create policy "memberships visible" on public.memberships for select to authenticated
  using (user_id = (select auth.uid()) or private.is_member(org_id) or private.is_platform_admin());
create policy "memberships managed" on public.memberships for all to authenticated
  using (private.has_org_role(org_id, array['owner', 'vendor_admin']::public.member_role[]) or private.is_platform_admin())
  with check (private.has_org_role(org_id, array['owner', 'vendor_admin']::public.member_role[]) or private.is_platform_admin());

drop function public.is_platform_admin();
drop function public.is_member(uuid);
drop function public.has_org_role(uuid, public.member_role[]);

-- Move the profile trigger function out of the public API too.
create function private.handle_new_user()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name')
  on conflict (id) do nothing;
  return new;
end;
$$;
revoke execute on function private.handle_new_user() from public, anon, authenticated;
drop trigger on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function private.handle_new_user();
drop function public.handle_new_user();

-- create_buyer_org stays in public on purpose: the app calls it to start a home or business account.
