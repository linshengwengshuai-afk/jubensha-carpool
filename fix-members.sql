-- 只修函数，不碰已有拼车数据。
-- 在 Supabase → SQL Editor 里整段运行一次。
-- 不要重跑旧的整份 rls.sql，否则会把成员名单清空。

create or replace function public._member_visible(src_members jsonb, creator uuid, uid uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return (
    select coalesce(jsonb_agg(
      case
        when uid is not null and uid = creator then elem
        when uid is not null and elem->>'user_id' = uid::text then elem
        when uid is not null
             and coalesce(elem->>'isHost', 'false') in ('true', 't')
             and exists (
               select 1
               from jsonb_array_elements(coalesce(src_members, '[]'::jsonb)) me
               where me->>'user_id' = uid::text
             )
          then elem
        else elem - 'contact'
      end
      order by ord
    ), '[]'::jsonb)
    from jsonb_array_elements(coalesce(src_members, '[]'::jsonb)) with ordinality as t(elem, ord)
  );
end;
$$;

create or replace function public.list_carpools()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  return (
    select coalesce(jsonb_agg(to_jsonb(t) order by t.id desc), '[]'::jsonb)
    from (
      select
        c.id,
        c.script_name,
        c.game_time,
        c.location,
        c.total_count,
        c.current_count,
        c.price,
        c.host,
        c.tags,
        c.creator_id,
        case
          when uid = c.creator_id
            or exists (
              select 1 from jsonb_array_elements(coalesce(p.members, '[]'::jsonb)) m
              where m->>'user_id' = uid::text
            )
          then nullif(p.contact, '')
          else null
        end as contact,
        case
          when uid = c.creator_id
            or exists (
              select 1 from jsonb_array_elements(coalesce(p.members, '[]'::jsonb)) m
              where m->>'user_id' = uid::text
            )
          then p.qr_image
          else null
        end as qr_image,
        public._member_visible(p.members, c.creator_id, uid) as members
      from public.carpools c
      left join public.carpool_private p on p.car_id = c.id::bigint
    ) t
  );
end;
$$;

create or replace function public.create_carpool(p jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  new_id bigint;
  uname text;
  wx text;
  host_member jsonb;
  tag_type text;
begin
  if uid is null then
    raise exception '请先登录';
  end if;
  wx := btrim(coalesce(p->>'contact', ''));
  if wx = '' then
    raise exception '请填写微信号';
  end if;
  if coalesce(p->>'script_name', '') ~ '情感|沉浸|哭哭|演绎|立意|还泪' then
    raise exception '禁止情感类';
  end if;
  if coalesce((p->>'total_count')::int, 0) < 1 then
    raise exception '人数不正确';
  end if;
  if coalesce((p->>'current_count')::int, 0) < 1
     or (p->>'current_count')::int > (p->>'total_count')::int then
    raise exception '当前人数不正确';
  end if;

  uname := coalesce(nullif(btrim(p->>'host'), ''), '玩家');
  host_member := jsonb_build_array(jsonb_build_object(
    'name', uname,
    'contact', wx,
    'isHost', true,
    'user_id', uid
  ));

  select udt_name into tag_type
  from information_schema.columns
  where table_schema = 'public' and table_name = 'carpools' and column_name = 'tags';

  if tag_type = 'jsonb' then
    insert into public.carpools (
      script_name, game_time, location, total_count, current_count,
      price, host, tags, creator_id, contact, qr_image, members
    ) values (
      p->>'script_name', p->>'game_time', p->>'location',
      (p->>'total_count')::int, (p->>'current_count')::int,
      p->>'price', uname, coalesce(p->'tags', '[]'::jsonb), uid,
      '', null, '[]'::jsonb
    )
    returning id::bigint into new_id;
  else
    insert into public.carpools (
      script_name, game_time, location, total_count, current_count,
      price, host, tags, creator_id, contact, qr_image, members
    ) values (
      p->>'script_name', p->>'game_time', p->>'location',
      (p->>'total_count')::int, (p->>'current_count')::int,
      p->>'price', uname,
      array(select jsonb_array_elements_text(coalesce(p->'tags', '[]'::jsonb))),
      uid, '', null, '[]'::jsonb
    )
    returning id::bigint into new_id;
  end if;

  insert into public.carpool_private (car_id, contact, qr_image, members)
  values (new_id, wx, nullif(p->>'qr_image', ''), host_member);

  return public.list_carpools();
end;
$$;

create or replace function public.join_carpool(p_id bigint, p_name text, p_contact text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  row public.carpools%rowtype;
  priv public.carpool_private%rowtype;
  members jsonb;
begin
  if uid is null then
    raise exception '请先登录';
  end if;
  if btrim(coalesce(p_contact, '')) = '' then
    raise exception '请先绑定微信号';
  end if;

  select * into row from public.carpools where id::bigint = p_id for update;
  if not found then
    raise exception '这辆车不存在';
  end if;
  if row.creator_id = uid then
    raise exception '车头不用上车';
  end if;
  if coalesce(row.current_count, 0) >= coalesce(row.total_count, 0) then
    raise exception '已满';
  end if;

  select * into priv from public.carpool_private where car_id = p_id for update;
  if not found then
    insert into public.carpool_private (car_id, contact, members)
    values (p_id, '', '[]'::jsonb)
    returning * into priv;
  end if;

  members := coalesce(priv.members, '[]'::jsonb);
  if exists (
    select 1 from jsonb_array_elements(members) m
    where m->>'user_id' = uid::text
  ) then
    raise exception '你已经在车上';
  end if;

  members := members || jsonb_build_array(jsonb_build_object(
    'name', coalesce(nullif(btrim(p_name), ''), '玩家'),
    'contact', btrim(p_contact),
    'isHost', false,
    'user_id', uid
  ));

  update public.carpool_private set members = members where car_id = p_id;
  update public.carpools
  set current_count = coalesce(current_count, 0) + 1
  where id::bigint = p_id;

  return public.list_carpools();
end;
$$;

create or replace function public.leave_carpool(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  src jsonb;
  next_members jsonb;
  removed int;
begin
  if uid is null then
    raise exception '请先登录';
  end if;

  select cp.members into src
  from public.carpool_private cp
  where cp.car_id = p_id
  for update;
  if not found then
    raise exception '这辆车不存在';
  end if;
  src := coalesce(src, '[]'::jsonb);

  select count(*) into removed
  from jsonb_array_elements(src) m
  where m->>'user_id' = uid::text
    and coalesce(m->>'isHost', 'false') not in ('true', 't');

  if removed = 0 then
    raise exception '你不在这辆车上';
  end if;

  select coalesce(jsonb_agg(m), '[]'::jsonb) into next_members
  from jsonb_array_elements(src) m
  where not (
    m->>'user_id' = uid::text
    and coalesce(m->>'isHost', 'false') not in ('true', 't')
  );

  update public.carpool_private cp
  set members = next_members
  where cp.car_id = p_id;
  update public.carpools
  set current_count = greatest(1, coalesce(current_count, 1) - removed)
  where id::bigint = p_id;

  return public.list_carpools();
end;
$$;

create or replace function public.kick_carpool_member(p_id bigint, p_index int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  src jsonb;
  next_members jsonb;
  target jsonb;
begin
  if uid is null then
    raise exception '请先登录';
  end if;
  if not exists (
    select 1 from public.carpools where id::bigint = p_id and creator_id = uid
  ) then
    raise exception '只有车头可以移除';
  end if;

  select cp.members into src
  from public.carpool_private cp
  where cp.car_id = p_id
  for update;
  src := coalesce(src, '[]'::jsonb);

  target := src -> p_index;
  if target is null or coalesce(target->>'isHost', 'false') in ('true', 't') then
    raise exception '不能移除这个人';
  end if;

  select coalesce(jsonb_agg(elem order by ord), '[]'::jsonb) into next_members
  from jsonb_array_elements(src) with ordinality as t(elem, ord)
  where ord - 1 <> p_index;

  update public.carpool_private cp
  set members = next_members
  where cp.car_id = p_id;
  update public.carpools
  set current_count = greatest(1, coalesce(current_count, 1) - 1)
  where id::bigint = p_id;

  return public.list_carpools();
end;
$$;

drop function if exists public.set_carpool_total(bigint, int);

create or replace function public.set_carpool_total(p_id bigint, p_total int, p_current int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  on_board int;
begin
  if uid is null then
    raise exception '请先登录';
  end if;
  if p_total is null or p_total < 1 or p_current is null or p_current < 1 then
    raise exception '人数不正确';
  end if;
  if p_total < p_current then
    raise exception '总人数不能小于当前已有人数';
  end if;

  if not exists (
    select 1 from public.carpools
    where id::bigint = p_id and creator_id = uid
  ) then
    raise exception '只有车头可以改人数';
  end if;

  select coalesce(jsonb_array_length(cp.members), 0) into on_board
  from public.carpool_private cp
  where cp.car_id = p_id;
  on_board := greatest(coalesce(on_board, 1), 1);

  if p_current < on_board then
    raise exception '当前人数不能少于已经上车的 % 人。请先让本人下车，或由车头移除', on_board;
  end if;

  update public.carpools
  set total_count = p_total,
      current_count = p_current
  where id::bigint = p_id;

  return public.list_carpools();
end;
$$;

create or replace function public.delete_carpool(p_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if uid is null then
    raise exception '请先登录';
  end if;
  if not exists (
    select 1 from public.carpools where id::bigint = p_id and creator_id = uid
  ) then
    raise exception '只有车头可以解散';
  end if;
  delete from public.carpool_private where car_id = p_id;
  delete from public.carpools where id::bigint = p_id;
  return public.list_carpools();
end;
$$;

revoke all on function public._member_visible(jsonb, uuid, uuid) from public, anon, authenticated;
revoke all on function public.list_carpools() from public;
revoke all on function public.create_carpool(jsonb) from public;
revoke all on function public.join_carpool(bigint, text, text) from public;
revoke all on function public.leave_carpool(bigint) from public;
revoke all on function public.kick_carpool_member(bigint, int) from public;
revoke all on function public.set_carpool_total(bigint, int, int) from public;
revoke all on function public.delete_carpool(bigint) from public;

grant execute on function public.list_carpools() to anon, authenticated;
grant execute on function public.create_carpool(jsonb) to authenticated;
grant execute on function public.join_carpool(bigint, text, text) to authenticated;
grant execute on function public.leave_carpool(bigint) to authenticated;
grant execute on function public.kick_carpool_member(bigint, int) to authenticated;
grant execute on function public.set_carpool_total(bigint, int, int) to authenticated;
grant execute on function public.delete_carpool(bigint) to authenticated;
