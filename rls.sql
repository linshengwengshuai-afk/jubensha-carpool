-- 拼车隐私锁。在 Supabase → SQL Editor 里整段运行一次。
-- 作用：广场数据任何人都能看，但微信号、群二维码、成员联系方式
-- 只存在 carpool_private。外面查不到。只有登录后的车头/车友，
-- 通过下面这些函数才能按身份看到该看的部分。

create table if not exists public.carpool_private (
  car_id bigint primary key,
  contact text,
  qr_image text,
  members jsonb not null default '[]'::jsonb
);

insert into public.carpool_private (car_id, contact, qr_image, members)
select c.id::bigint, c.contact, c.qr_image, coalesce(c.members, '[]'::jsonb)
from public.carpools c
on conflict (car_id) do update
  set contact = excluded.contact,
      qr_image = excluded.qr_image,
      members = excluded.members;

-- 公开表里不再留联系方式，避免实时推送或直接查询泄露
update public.carpools
set contact = '',
    qr_image = null,
    members = '[]'::jsonb;

alter table public.carpools enable row level security;
alter table public.carpool_private enable row level security;

do $$
declare r record;
begin
  for r in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'carpools'
  loop
    execute format('drop policy if exists %I on public.carpools', r.policyname);
  end loop;
  for r in
    select policyname from pg_policies
    where schemaname = 'public' and tablename = 'carpool_private'
  loop
    execute format('drop policy if exists %I on public.carpool_private', r.policyname);
  end loop;
end $$;

create policy "public read carpools"
  on public.carpools
  for select
  to anon, authenticated
  using (true);

revoke all on public.carpool_private from anon, authenticated;
grant select on public.carpools to anon, authenticated;
revoke insert, update, delete on public.carpools from anon, authenticated;

create or replace function public._member_visible(members jsonb, creator uuid, uid uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(
    case
      when uid is not null and uid = creator then elem
      when uid is not null and elem->>'user_id' = uid::text then elem
      when uid is not null
           and coalesce(elem->>'isHost', 'false') in ('true', 't')
           and exists (
             select 1
             from jsonb_array_elements(coalesce(members, '[]'::jsonb)) me
             where me->>'user_id' = uid::text
           )
        then elem
      else elem - 'contact'
    end
    order by ord
  ), '[]'::jsonb)
  from jsonb_array_elements(coalesce(members, '[]'::jsonb)) with ordinality as t(elem, ord);
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
  members jsonb;
  src jsonb;
  removed int;
begin
  if uid is null then
    raise exception '请先登录';
  end if;

  select coalesce(members, '[]'::jsonb) into src
  from public.carpool_private where car_id = p_id for update;
  if not found then
    raise exception '这辆车不存在';
  end if;

  select count(*) into removed
  from jsonb_array_elements(src) m
  where m->>'user_id' = uid::text
    and coalesce(m->>'isHost', 'false') not in ('true', 't');

  if removed = 0 then
    raise exception '你不在这辆车上';
  end if;

  select coalesce(jsonb_agg(m), '[]'::jsonb) into members
  from jsonb_array_elements(src) m
  where not (
    m->>'user_id' = uid::text
    and coalesce(m->>'isHost', 'false') not in ('true', 't')
  );

  update public.carpool_private set members = members where car_id = p_id;
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
  members jsonb;
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

  select coalesce(members, '[]'::jsonb) into members
  from public.carpool_private where car_id = p_id for update;

  target := members -> p_index;
  if target is null or coalesce(target->>'isHost', 'false') in ('true', 't') then
    raise exception '不能移除这个人';
  end if;

  select coalesce(jsonb_agg(elem order by ord), '[]'::jsonb) into members
  from jsonb_array_elements(members) with ordinality as t(elem, ord)
  where ord - 1 <> p_index;

  update public.carpool_private set members = members where car_id = p_id;
  update public.carpools
  set current_count = greatest(1, coalesce(current_count, 1) - 1)
  where id::bigint = p_id;

  return public.list_carpools();
end;
$$;

create or replace function public.set_carpool_total(p_id bigint, p_total int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cur int;
begin
  if uid is null then
    raise exception '请先登录';
  end if;
  if p_total is null or p_total < 1 then
    raise exception '人数不正确';
  end if;

  select current_count into cur
  from public.carpools
  where id::bigint = p_id and creator_id = uid
  for update;

  if not found then
    raise exception '只有车头可以改人数';
  end if;
  if p_total < coalesce(cur, 1) then
    raise exception '总人数不能小于车上已有人数';
  end if;

  update public.carpools set total_count = p_total where id::bigint = p_id;
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
revoke all on function public.set_carpool_total(bigint, int) from public;
revoke all on function public.delete_carpool(bigint) from public;

grant execute on function public.list_carpools() to anon, authenticated;
grant execute on function public.create_carpool(jsonb) to authenticated;
grant execute on function public.join_carpool(bigint, text, text) to authenticated;
grant execute on function public.leave_carpool(bigint) to authenticated;
grant execute on function public.kick_carpool_member(bigint, int) to authenticated;
grant execute on function public.set_carpool_total(bigint, int) to authenticated;
grant execute on function public.delete_carpool(bigint) to authenticated;
