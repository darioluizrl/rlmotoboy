-- RL Motoboy — banco do sistema web (Supabase)
-- Rode uma vez no SQL Editor do projeto (ou pelo conector do Supabase).
-- Segurança: só usuários LIBERADOS (tabela membros, ativo = true) leem ou gravam dados.

-- 1) Quem pode usar o sistema
create table if not exists public.membros (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  papel      text not null default 'funcionario' check (papel in ('admin','funcionario')),
  ativo      boolean not null default true,
  criado_em  timestamptz not null default now()
);

-- 2) Dados do sistema (clientes, equipe, movimentacoes, orcamentos, config)
create table if not exists public.docs (
  colecao     text not null,
  id          text not null,
  data        jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  updated_by  uuid default auth.uid(),
  primary key (colecao, id)
);

alter table public.membros enable row level security;
alter table public.docs    enable row level security;

-- 3) Funções de permissão
create or replace function public.is_membro() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.membros where user_id = auth.uid() and ativo);
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.membros where user_id = auth.uid() and ativo and papel = 'admin');
$$;

-- 4) Regras de acesso
drop policy if exists docs_membros on public.docs;
create policy docs_membros on public.docs for all to authenticated
  using (public.is_membro()) with check (public.is_membro());

drop policy if exists membros_ver on public.membros;
create policy membros_ver on public.membros for select to authenticated
  using (user_id = auth.uid() or public.is_admin());

-- 5) O primeiro usuário a entrar vira administrador (só funciona com a tabela vazia)
create or replace function public.primeiro_admin() returns text
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return null; end if;
  if exists (select 1 from public.membros) then return null; end if;
  insert into public.membros (user_id, email, papel, ativo)
  values (auth.uid(), lower(auth.email()), 'admin', true);
  return 'admin';
end $$;

-- 6) Administração de usuários (só admin)
create or replace function public.listar_usuarios()
returns table (user_id uuid, email text, papel text, ativo boolean, liberado boolean, criado_em timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select u.id, u.email::text, m.papel, coalesce(m.ativo,false), (m.user_id is not null), u.created_at
    from auth.users u left join public.membros m on m.user_id = u.id
    order by (m.user_id is not null), u.created_at desc;
end $$;

create or replace function public.liberar_usuario(p_email text, p_papel text default 'funcionario') returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if p_papel not in ('admin','funcionario') then raise exception 'Perfil inválido'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'O usuário % ainda não criou o acesso', p_email; end if;
  insert into public.membros (user_id, email, papel, ativo) values (uid, lower(trim(p_email)), p_papel, true)
  on conflict (user_id) do update set papel = excluded.papel, ativo = true, email = excluded.email;
  return 'ok';
end $$;

create or replace function public.bloquear_usuario(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if p_user = auth.uid() then raise exception 'Você não pode bloquear a si mesmo'; end if;
  update public.membros set ativo = false where user_id = p_user;
end $$;

revoke all on function public.primeiro_admin(), public.listar_usuarios(), public.liberar_usuario(text,text), public.bloquear_usuario(uuid) from public, anon;
grant execute on function public.primeiro_admin(), public.listar_usuarios(), public.liberar_usuario(text,text), public.bloquear_usuario(uuid) to authenticated;

-- 7) Tempo real
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;
