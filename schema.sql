-- WIN CHALLENGE: run this whole file once in Supabase > SQL Editor.
-- All writes go through security-definer functions (RPC); clients cannot write tables directly.

create extension if not exists pgcrypto;

create table public.profiles(
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null check (username ~ '^[A-Za-z0-9_]{3,20}$'),
  display_name text not null check (char_length(display_name) between 1 and 40),
  avatar_url text,
  role text not null default 'player' check (role in ('player','admin')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());

create table public.activity_log(
  id bigint generated always as identity primary key,
  user_id uuid, action text not null, entity_type text, entity_id text,
  metadata jsonb not null default '{}', created_at timestamptz not null default now());

create table public.win_challenges(
  id uuid primary key default gen_random_uuid(),
  name text not null,
  status text not null default 'draft' check (status in ('draft','running','paused','completed')),
  started_at timestamptz, paused_at timestamptz, completed_at timestamptz,
  paused_seconds int not null default 0, elapsed_seconds int,
  created_by uuid references public.profiles(id), created_at timestamptz not null default now());
create unique index one_open_win on public.win_challenges((true)) where status <> 'completed';

create table public.challenge_definitions(
  id uuid primary key default gen_random_uuid(),
  name text unique not null, icon text default '🎮', description text, category text not null,
  min_players int not null default 1 check (min_players >= 1),
  max_players int not null default 1,
  sort_order int not null default 0, enabled boolean not null default true,
  time_limit_seconds int,
  progression_schema jsonb not null default '[]',
  check (max_players >= min_players));

create table public.challenge_instances(
  id uuid primary key default gen_random_uuid(),
  win_challenge_id uuid not null references public.win_challenges(id) on delete cascade,
  challenge_definition_id uuid references public.challenge_definitions(id) on delete set null,
  name text not null, icon text, description text, category text,
  min_players int not null, max_players int not null, time_limit_seconds int,
  progression_schema jsonb not null,
  status text not null default 'not_started' check (status in ('not_started','waiting','active','completed')),
  started_at timestamptz, completed_at timestamptz, elapsed_seconds int,
  completed_by uuid references public.profiles(id), notes text,
  sort_order int not null default 0, updated_at timestamptz not null default now(),
  unique (win_challenge_id, challenge_definition_id));

create table public.challenge_progress(
  id uuid primary key default gen_random_uuid(),
  challenge_instance_id uuid not null references public.challenge_instances(id) on delete cascade,
  progression_key text not null, current_value numeric not null default 0, target_value numeric not null,
  metadata jsonb not null default '{}',
  updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
  unique (challenge_instance_id, progression_key));

create table public.progress_history(
  id bigint generated always as identity primary key,
  challenge_instance_id uuid not null references public.challenge_instances(id) on delete cascade,
  progression_key text not null, old_value numeric, new_value numeric, op text,
  user_id uuid references public.profiles(id), created_at timestamptz not null default now());

create table public.challenge_participants(
  id uuid primary key default gen_random_uuid(),
  challenge_instance_id uuid not null references public.challenge_instances(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  joined_at timestamptz not null default now(), left_at timestamptz);
create unique index one_active_participation on public.challenge_participants(challenge_instance_id, user_id) where left_at is null;

create table public.challenge_contributions(
  id uuid primary key default gen_random_uuid(),
  challenge_instance_id uuid not null references public.challenge_instances(id) on delete cascade,
  user_id uuid not null references public.profiles(id),
  amount numeric not null default 0 check (amount >= 0), note text,
  updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
  unique (challenge_instance_id, user_id));

create table public.votes(
  id uuid primary key default gen_random_uuid(),
  challenge_instance_id uuid not null references public.challenge_instances(id) on delete cascade,
  voter_id uuid not null references public.profiles(id),
  target_user_id uuid not null references public.profiles(id),
  vote_type text not null check (vote_type in ('MVP','MOST_CARRIED')),
  created_at timestamptz not null default now(),
  unique (challenge_instance_id, voter_id, vote_type),
  check (voter_id <> target_user_id));

-- ---------- helpers ----------
create function public.is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and role = 'admin') $$;

create function public.server_now() returns timestamptz language sql stable as $$ select now() $$;

create function public.log_event(p_action text, p_type text, p_id text, p_meta jsonb default '{}')
returns void language sql security definer set search_path = public as
$$ insert into activity_log(user_id, action, entity_type, entity_id, metadata) values (auth.uid(), p_action, p_type, p_id, p_meta) $$;

-- First registered account becomes admin; everyone after is a player.
create function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
declare u text := coalesce(new.raw_user_meta_data->>'username', split_part(new.email, '@', 1));
begin
  insert into profiles(id, username, display_name, role)
  values (new.id, u, coalesce(nullif(new.raw_user_meta_data->>'display_name', ''), u),
          case when exists(select 1 from profiles) then 'player' else 'admin' end);
  insert into activity_log(user_id, action, entity_type, entity_id) values (new.id, 'user_registered', 'user', new.id::text);
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

create function public.refresh_status(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare i challenge_instances; n int; s text;
begin
  select * into i from challenge_instances where id = p_id for update;
  if i.status = 'completed' then return; end if;
  select count(*) into n from challenge_participants where challenge_instance_id = p_id and left_at is null;
  s := case when n = 0 then 'not_started' when n < i.min_players then 'waiting' else 'active' end;
  update challenge_instances set status = s,
    started_at = case when s = 'active' then coalesce(started_at, now()) else started_at end,
    updated_at = now() where id = p_id;
end $$;

create function public._end_win(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update win_challenges set status = 'completed', completed_at = now(),
    paused_seconds = paused_seconds + coalesce(extract(epoch from now() - paused_at)::int, 0),
    elapsed_seconds = greatest(0, extract(epoch from now() - started_at)::int - paused_seconds - coalesce(extract(epoch from now() - paused_at)::int, 0)),
    paused_at = null
  where id = p_id and status in ('running', 'paused');
end $$;

create function public._assert_can_edit(p_instance uuid) returns void language plpgsql security definer set search_path = public as $$
declare i challenge_instances; w win_challenges;
begin
  select * into i from challenge_instances where id = p_instance;
  if not found then raise exception 'Unknown challenge'; end if;
  if i.status = 'completed' then raise exception 'Challenge already completed'; end if;
  if is_admin() then return; end if;
  select * into w from win_challenges where id = i.win_challenge_id;
  if w.status <> 'running' then raise exception 'The Win Challenge is not running'; end if;
  if not exists(select 1 from challenge_participants where challenge_instance_id = p_instance and user_id = auth.uid() and left_at is null)
    then raise exception 'Join this challenge first'; end if;
  if i.status <> 'active' then raise exception 'Waiting for more players'; end if;
  if i.time_limit_seconds is not null and now() > i.started_at + make_interval(secs => i.time_limit_seconds)
    then raise exception 'This challenge timer has expired (ask the admin to reset it)'; end if;
end $$;

-- Automatic completion: every objective in the schema must be satisfied.
create function public._check_complete(p_id uuid, p_force boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare i challenge_instances; w win_challenges; o jsonb; ok boolean := true; v numeric; n int; tgt numeric;
begin
  select * into i from challenge_instances where id = p_id for update;
  if i.status = 'completed' then return; end if;
  if not p_force then
    if jsonb_array_length(i.progression_schema) = 0 then return; end if;
    for o in select * from jsonb_array_elements(i.progression_schema) loop
      tgt := (o->>'target')::numeric;
      if o->>'type' = 'team_total' then
        select coalesce(sum(amount), 0) into v from challenge_contributions where challenge_instance_id = p_id;
        ok := ok and v >= tgt;
      elsif o->>'type' = 'each_player' then
        select count(*) into n from challenge_participants where challenge_instance_id = p_id and left_at is null;
        ok := ok and n > 0 and not exists(
          select 1 from challenge_participants p where p.challenge_instance_id = p_id and p.left_at is null
          and coalesce((select c.amount from challenge_contributions c where c.challenge_instance_id = p_id and c.user_id = p.user_id), 0) < tgt);
      else
        select coalesce(current_value, 0) into v from challenge_progress where challenge_instance_id = p_id and progression_key = o->>'key';
        v := coalesce(v, 0);
        ok := ok and (case when o->>'type' = 'lte' then (v > 0 and v <= tgt) else v >= tgt end);
      end if;
    end loop;
    if not coalesce(ok, false) then return; end if;
  end if;
  select * into w from win_challenges where id = i.win_challenge_id;
  update challenge_instances set status = 'completed', completed_at = now(), completed_by = auth.uid(), updated_at = now(),
    elapsed_seconds = greatest(0, extract(epoch from now() - w.started_at)::int - w.paused_seconds - coalesce(extract(epoch from now() - w.paused_at)::int, 0))
  where id = p_id;
  perform log_event('challenge_completed', 'challenge', p_id::text, jsonb_build_object('name', i.name, 'forced', p_force));
  if not exists(select 1 from challenge_instances where win_challenge_id = i.win_challenge_id and status <> 'completed') then
    perform _end_win(i.win_challenge_id);
    perform log_event('win_completed', 'win_challenge', i.win_challenge_id::text);
  end if;
end $$;

-- ---------- public RPC ----------
create function public.create_win(p_name text) returns uuid language plpgsql security definer set search_path = public as $$
declare w uuid; d record; o jsonb; iid uuid;
begin
  if not is_admin() then raise exception 'Admin only'; end if;
  if exists(select 1 from win_challenges where status <> 'completed') then raise exception 'End the current Win Challenge first'; end if;
  insert into win_challenges(name, created_by) values (p_name, auth.uid()) returning id into w;
  for d in select * from challenge_definitions where enabled order by sort_order loop
    insert into challenge_instances(win_challenge_id, challenge_definition_id, name, icon, description, category, min_players, max_players, time_limit_seconds, progression_schema, sort_order)
    values (w, d.id, d.name, d.icon, d.description, d.category, d.min_players, d.max_players, d.time_limit_seconds, d.progression_schema, d.sort_order)
    returning id into iid;
    for o in select * from jsonb_array_elements(d.progression_schema) loop
      if o->>'type' not in ('team_total', 'each_player') then
        insert into challenge_progress(challenge_instance_id, progression_key, current_value, target_value, metadata)
        values (iid, o->>'key', coalesce((o->>'start')::numeric, 0), (o->>'target')::numeric, '{"best":0,"fails":0}');
      end if;
    end loop;
  end loop;
  perform log_event('win_challenge_created', 'win_challenge', w::text, jsonb_build_object('name', p_name));
  return w;
end $$;

create function public.win_action(p_id uuid, p_action text) returns void language plpgsql security definer set search_path = public as $$
declare w win_challenges;
begin
  if not is_admin() then raise exception 'Admin only'; end if;
  select * into w from win_challenges where id = p_id for update;
  if not found then raise exception 'Not found'; end if;
  if p_action = 'start' and w.status = 'draft' then
    update win_challenges set status = 'running', started_at = now() where id = p_id;
  elsif p_action = 'pause' and w.status = 'running' then
    update win_challenges set status = 'paused', paused_at = now() where id = p_id;
  elsif p_action = 'resume' and w.status = 'paused' then
    update win_challenges set status = 'running', paused_seconds = paused_seconds + extract(epoch from now() - paused_at)::int, paused_at = null where id = p_id;
  elsif p_action = 'end' and w.status in ('running', 'paused') then
    perform _end_win(p_id);
  else
    raise exception 'Cannot % while status is %', p_action, w.status;
  end if;
  perform log_event('win_' || p_action, 'win_challenge', p_id::text);
end $$;

create function public.set_participant(p_instance uuid, p_user uuid, p_join boolean) returns void language plpgsql security definer set search_path = public as $$
declare i challenge_instances; w win_challenges; n int;
begin
  select * into i from challenge_instances where id = p_instance for update;
  if not found then raise exception 'Unknown challenge'; end if;
  if p_user <> auth.uid() and not is_admin() then raise exception 'Not allowed'; end if;
  if i.status = 'completed' then raise exception 'Challenge already completed'; end if;
  if p_join then
    select * into w from win_challenges where id = i.win_challenge_id;
    if w.status <> 'running' then raise exception 'The Win Challenge is not running'; end if;
    select count(*) into n from challenge_participants where challenge_instance_id = p_instance and left_at is null;
    if n >= i.max_players and not is_admin() then raise exception 'This challenge is full'; end if;
    insert into challenge_participants(challenge_instance_id, user_id) values (p_instance, p_user) on conflict do nothing;
  else
    update challenge_participants set left_at = now() where challenge_instance_id = p_instance and user_id = p_user and left_at is null;
  end if;
  perform refresh_status(p_instance);
  perform log_event(case when p_join then 'player_joined' else 'player_left' end, 'challenge', p_instance::text, jsonb_build_object('user_id', p_user, 'by_admin', p_user <> auth.uid()));
end $$;

create function public.admin_add_all(p_instance uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admin only'; end if;
  if not exists(select 1 from challenge_instances i join win_challenges w on w.id = i.win_challenge_id where i.id = p_instance and w.status = 'running' and i.status <> 'completed')
    then raise exception 'The Win Challenge must be running'; end if;
  insert into challenge_participants(challenge_instance_id, user_id)
  select p_instance, pr.id from profiles pr
  where not exists(select 1 from challenge_participants x where x.challenge_instance_id = p_instance and x.user_id = pr.id and x.left_at is null);
  perform refresh_status(p_instance);
  perform log_event('admin_added_all_players', 'challenge', p_instance::text);
end $$;

-- p_op: set | inc | win | loss   (win/loss only for streak objectives)
create function public.update_progress(p_instance uuid, p_key text, p_op text, p_value numeric default 1) returns void language plpgsql security definer set search_path = public as $$
declare i challenge_instances; o jsonb; cp challenge_progress; nv numeric;
begin
  perform _assert_can_edit(p_instance);
  select * into i from challenge_instances where id = p_instance;
  select e into o from jsonb_array_elements(i.progression_schema) e where e->>'key' = p_key;
  if o is null then raise exception 'Unknown objective'; end if;
  if p_op in ('win', 'loss') and o->>'type' <> 'streak' then raise exception 'Only streak objectives use win/loss'; end if;
  select * into cp from challenge_progress where challenge_instance_id = p_instance and progression_key = p_key for update;
  if not found then raise exception 'This objective is tracked per player'; end if;
  nv := case p_op when 'set' then p_value when 'inc' then cp.current_value + p_value when 'win' then cp.current_value + 1 when 'loss' then 0 end;
  if nv is null then raise exception 'Bad operation'; end if;
  if o->>'type' = 'lte' then nv := greatest(nv, 0); else nv := least(greatest(nv, 0), cp.target_value); end if;
  update challenge_progress set current_value = nv, updated_by = auth.uid(), updated_at = now(),
    metadata = case when o->>'type' = 'streak' then
      jsonb_build_object('best', greatest(coalesce((metadata->>'best')::numeric, 0), nv),
                         'fails', coalesce((metadata->>'fails')::int, 0) + case when p_op = 'loss' then 1 else 0 end)
      else metadata end
  where id = cp.id;
  insert into progress_history(challenge_instance_id, progression_key, old_value, new_value, op, user_id) values (p_instance, p_key, cp.current_value, nv, p_op, auth.uid());
  update challenge_instances set updated_at = now() where id = p_instance;
  perform log_event('progress_changed', 'challenge', p_instance::text, jsonb_build_object('key', p_key, 'from', cp.current_value, 'to', nv));
  perform _check_complete(p_instance);
end $$;

create function public.add_contribution(p_instance uuid, p_user uuid, p_amount numeric, p_set boolean default false, p_note text default null) returns void language plpgsql security definer set search_path = public as $$
declare old numeric; nv numeric;
begin
  perform _assert_can_edit(p_instance);
  if p_amount < 0 or p_amount > 100000 then raise exception 'Invalid amount'; end if;
  if not exists(select 1 from challenge_participants where challenge_instance_id = p_instance and user_id = p_user and left_at is null)
    then raise exception 'That player is not in this challenge'; end if;
  select amount into old from challenge_contributions where challenge_instance_id = p_instance and user_id = p_user;
  old := coalesce(old, 0);
  nv := case when p_set then p_amount else old + p_amount end;
  insert into challenge_contributions(challenge_instance_id, user_id, amount, note, updated_by) values (p_instance, p_user, nv, p_note, auth.uid())
  on conflict (challenge_instance_id, user_id) do update set amount = excluded.amount,
    note = coalesce(excluded.note, challenge_contributions.note), updated_at = now(), updated_by = auth.uid();
  insert into progress_history(challenge_instance_id, progression_key, old_value, new_value, op, user_id) values (p_instance, 'player:' || p_user, old, nv, case when p_set then 'set' else 'add' end, auth.uid());
  update challenge_instances set updated_at = now() where id = p_instance;
  perform log_event('contribution_changed', 'challenge', p_instance::text, jsonb_build_object('player', p_user, 'from', old, 'to', nv));
  perform _check_complete(p_instance);
end $$;

create function public.cast_vote(p_instance uuid, p_target uuid, p_type text) returns void language plpgsql security definer set search_path = public as $$
begin
  if p_type not in ('MVP', 'MOST_CARRIED') then raise exception 'Bad vote type'; end if;
  if p_target = auth.uid() then raise exception 'You cannot vote for yourself'; end if;
  if not exists(select 1 from challenge_instances where id = p_instance and status = 'completed') then raise exception 'Voting opens when the challenge is completed'; end if;
  if not exists(select 1 from challenge_participants where challenge_instance_id = p_instance and user_id = auth.uid()) then raise exception 'Only participants can vote'; end if;
  if not exists(select 1 from challenge_participants where challenge_instance_id = p_instance and user_id = p_target) then raise exception 'That player did not take part'; end if;
  insert into votes(challenge_instance_id, voter_id, target_user_id, vote_type) values (p_instance, auth.uid(), p_target, p_type);
  update challenge_instances set updated_at = now() where id = p_instance;
  perform log_event('vote_submitted', 'challenge', p_instance::text, jsonb_build_object('type', p_type));
exception when unique_violation then raise exception 'You already cast this vote';
end $$;

-- p_complete=true: force-complete. p_complete=false: reopen (p_reset=true also zeroes progress; history is kept).
create function public.admin_set_complete(p_instance uuid, p_complete boolean, p_reset boolean default false) returns void language plpgsql security definer set search_path = public as $$
declare i challenge_instances; o jsonb;
begin
  if not is_admin() then raise exception 'Admin only'; end if;
  select * into i from challenge_instances where id = p_instance for update;
  if not found then raise exception 'Unknown challenge'; end if;
  if p_complete then
    perform _check_complete(p_instance, true);
  else
    if exists(select 1 from win_challenges where id = i.win_challenge_id and status = 'completed') then raise exception 'The Win Challenge has already ended'; end if;
    update challenge_instances set status = 'waiting', completed_at = null, completed_by = null, elapsed_seconds = null, updated_at = now() where id = p_instance;
    if p_reset then
      for o in select * from jsonb_array_elements(i.progression_schema) loop
        update challenge_progress set current_value = coalesce((o->>'start')::numeric, 0), metadata = '{"best":0,"fails":0}', updated_by = auth.uid(), updated_at = now()
        where challenge_instance_id = p_instance and progression_key = o->>'key';
      end loop;
      delete from challenge_contributions where challenge_instance_id = p_instance;
      update challenge_instances set started_at = null where id = p_instance;
    end if;
    perform refresh_status(p_instance);
  end if;
  perform log_event(case when p_complete then 'admin_forced_complete' when p_reset then 'challenge_reset' else 'challenge_reopened' end, 'challenge', p_instance::text);
end $$;

create function public.admin_set_role(p_user uuid, p_role text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Admin only'; end if;
  if p_role not in ('player', 'admin') then raise exception 'Bad role'; end if;
  if p_user = auth.uid() and p_role = 'player' then raise exception 'You cannot remove your own admin role'; end if;
  update profiles set role = p_role, updated_at = now() where id = p_user;
  perform log_event('role_changed', 'user', p_user::text, jsonb_build_object('role', p_role));
end $$;

-- ---------- views ----------
create view public.vote_counts as
  select challenge_instance_id, target_user_id, vote_type, count(*)::int as n from public.votes group by 1, 2, 3;

create view public.leaderboard as
  select p.id as user_id, p.display_name, p.username, p.avatar_url,
    (select count(*) from public.votes v where v.target_user_id = p.id and v.vote_type = 'MVP')::int as mvp,
    (select count(*) from public.votes v where v.target_user_id = p.id and v.vote_type = 'MOST_CARRIED')::int as carried,
    (select count(distinct cp.challenge_instance_id) from public.challenge_participants cp
       join public.challenge_instances ci on ci.id = cp.challenge_instance_id
       where cp.user_id = p.id and ci.status = 'completed')::int as participated
  from public.profiles p;

-- ---------- security ----------
do $$ declare t text; begin
  foreach t in array array['profiles','activity_log','win_challenges','challenge_definitions','challenge_instances','challenge_progress','progress_history','challenge_participants','challenge_contributions','votes'] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
  foreach t in array array['profiles','win_challenges','challenge_definitions','challenge_instances','challenge_progress','progress_history','challenge_participants','challenge_contributions'] loop
    execute format('create policy "read" on public.%I for select to authenticated using (true)', t);
  end loop;
end $$;
create policy "own votes or admin" on public.votes for select to authenticated using (voter_id = auth.uid() or public.is_admin());
create policy "admin reads log" on public.activity_log for select to authenticated using (public.is_admin());
create policy "admin edits definitions" on public.challenge_definitions for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy "edit own profile" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated;
grant update (display_name, avatar_url) on public.profiles to authenticated;   -- role can never be self-edited

revoke all on public.vote_counts, public.leaderboard from anon;
grant select on public.vote_counts, public.leaderboard to authenticated;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.server_now(), public.is_admin(), public.create_win(text), public.win_action(uuid, text),
  public.set_participant(uuid, uuid, boolean), public.admin_add_all(uuid), public.update_progress(uuid, text, text, numeric),
  public.add_contribution(uuid, uuid, numeric, boolean, text), public.cast_vote(uuid, uuid, text),
  public.admin_set_complete(uuid, boolean, boolean), public.admin_set_role(uuid, text) to authenticated;

alter publication supabase_realtime add table public.win_challenges, public.challenge_instances, public.challenge_progress,
  public.challenge_participants, public.challenge_contributions;

-- ---------- preloaded challenges ----------
-- objective types: counter | flag (yes/no) | streak (resets on loss, keeps best) | money | lte (met when 0 < value <= target)
--                  team_total (summed player contributions) | each_player (every participant must reach target)
insert into public.challenge_definitions(name, icon, category, min_players, max_players, sort_order, time_limit_seconds, progression_schema) values
('Rainbow Six Siege','🛡️','Competitive',5,5,1,null,'[{"key":"ranked","label":"Ranked wins","type":"counter","target":5},{"key":"nocomms","label":"No-comms wins","type":"counter","target":2}]'),
('Overwatch 2','🦸','Competitive',5,5,2,null,'[{"key":"ranked","label":"Ranked wins","type":"counter","target":5},{"key":"nocomms","label":"No communication","type":"flag","target":1},{"key":"nosound","label":"Game sound disabled","type":"flag","target":1}]'),
('Valorant','🎯','Competitive',5,5,3,null,'[{"key":"streak","label":"Ranked wins in a row","type":"streak","target":3}]'),
('Fortnite','👑','Competitive',4,4,4,null,'[{"key":"b2b","label":"Back-to-back Victory Royales","type":"streak","target":2},{"key":"elims","label":"Team eliminations","type":"counter","target":20}]'),
('Minecraft Hardcore','⛏️','Co-op',6,7,5,null,'[{"key":"dragon","label":"Ender Dragon killed","type":"flag","target":1}]'),
('How to Fish','🎣','Solo/Filler',1,1,6,null,'[{"key":"done","label":"Game completion","type":"flag","target":1}]'),
('Phasmophobia','👻','Co-op',4,4,7,null,'[{"key":"streak","label":"Contracts in a row","type":"streak","target":3}]'),
('PEAK','🏔️','Co-op',3,3,8,null,'[{"key":"summit","label":"Summit","type":"flag","target":1}]'),
('Ready or Not','🚔','Co-op',3,3,9,null,'[{"key":"streak","label":"Missions without failure","type":"streak","target":3}]'),
('Scam With Your Friends','🃏','Party',4,4,10,null,'[{"key":"days","label":"Days","type":"counter","target":4}]'),
('The Sims 4','🏠','Solo',1,1,11,7200,'[{"key":"money","label":"Household money","type":"money","target":1000000}]'),
('Rocket League','🚀','Competitive',2,3,12,null,'[{"key":"tournament","label":"Tournament completed","type":"flag","target":1}]'),
('GTA V Online','🚗','Co-op',4,4,13,null,'[{"key":"h1","label":"The Fleeca Job","type":"flag","target":1},{"key":"h2","label":"The Prison Break","type":"flag","target":1},{"key":"h3","label":"The Humane Labs Raid","type":"flag","target":1},{"key":"h4","label":"Series A Funding","type":"flag","target":1},{"key":"h5","label":"The Pacific Standard Job","type":"flag","target":1}]'),
('500 Push-ups','💪','IRL',5,5,14,null,'[{"key":"total","label":"Team push-ups","type":"team_total","target":500}]'),
('Euro Truck Simulator','🚚','Solo/Filler',1,1,15,null,'[{"key":"drives","label":"Long drives","type":"counter","target":2}]'),
('F1','🏎️','Solo',1,1,16,null,'[{"key":"race","label":"Race distance %","type":"counter","target":100},{"key":"finish","label":"Finish position (podium = P1-P3)","type":"lte","target":3,"prefix":"P"}]'),
('EA FC 27 Pro Clubs','⚽','Competitive',5,9,17,null,'[{"key":"division","label":"Current division (target Division 1+)","type":"lte","target":1,"start":10,"prefix":"Division "}]'),
('Duolingo','🦉','Long-term',1,99,18,null,'[{"key":"lessons","label":"Lessons per player (admin can edit the minimum)","type":"each_player","target":1}]'),
('Gamble With Your Friends','🎰','Party/Filler',3,3,19,null,'[{"key":"done","label":"Game completion","type":"flag","target":1}]');

-- Log admin edits to challenge definitions (created after the seed so the seed is not logged).
create function public.log_definition_change() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log(user_id, action, entity_type, entity_id, metadata)
  values (auth.uid(), 'definition_' || lower(tg_op), 'definition', coalesce(new.id, old.id)::text, jsonb_build_object('name', coalesce(new.name, old.name)));
  return coalesce(new, old);
end $$;
create trigger trg_log_definition after insert or update or delete on public.challenge_definitions for each row execute function public.log_definition_change();
revoke execute on function public.log_definition_change() from public, anon, authenticated;
