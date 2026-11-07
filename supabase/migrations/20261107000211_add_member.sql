-- Owners and vendor admins add their own people by email; Duly staff can add anyone.
drop function public.admin_add_member(text, uuid, public.member_role);

create function public.add_member(p_email text, p_org uuid, p_role public.member_role)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  v_user uuid;
  v_kind public.org_kind;
begin
  select kind into v_kind from public.organisations where id = p_org;
  if v_kind is null then raise exception 'Organisation not found'; end if;
  if not private.is_platform_admin() then
    if p_role = 'platform_admin' then raise exception 'Only Duly staff can add Duly staff'; end if;
    if v_kind = 'vendor' and not (private.has_org_role(p_org, array['vendor_admin']::public.member_role[])
                                  and p_role in ('vendor_admin', 'dispatcher', 'operative')) then
      raise exception 'Only your company admin can add vendor staff';
    end if;
    if v_kind = 'buyer' and not (private.has_org_role(p_org, array['owner']::public.member_role[])
                                 and p_role in ('owner', 'approver', 'viewer')) then
      raise exception 'Only the account owner can add people';
    end if;
    if v_kind = 'platform' then raise exception 'Not allowed'; end if;
  end if;
  select id into v_user from auth.users where lower(email) = lower(trim(p_email));
  if v_user is null then
    raise exception 'No Duly account for %. Ask them to sign in once (Duly Crew for cleaners), then try again.', trim(p_email);
  end if;
  insert into public.memberships (org_id, user_id, role) values (p_org, v_user, p_role) on conflict do nothing;
  return v_user;
end;
$$;
revoke execute on function public.add_member(text, uuid, public.member_role) from public, anon;
grant execute on function public.add_member(text, uuid, public.member_role) to authenticated;
