-- Passo 1 da Central RL: cadastro de prestadores (motoboys/motoristas) e contratantes (quem solta serviço)
-- Entrada só por convite. Cadastro fica "pendente" até o administrador aprovar.
-- Prestador e contratante NÃO acessam os dados internos da RL (tabela docs): as regras de docs só liberam admin/funcionario/orcamento.

-- 1) Novos perfis
alter table public.membros drop constraint if exists membros_papel_check;
alter table public.membros add constraint membros_papel_check
  check (papel in ('admin','funcionario','orcamento','prestador','contratante'));

-- 2) Convites
create table if not exists public.convites (
  codigo     text primary key check (codigo ~ '^[A-Z0-9-]{6,20}$'),
  tipo       text not null check (tipo in ('prestador','contratante')),
  descricao  text,
  usos_max   int  not null default 1 check (usos_max between 1 and 1000),
  usos       int  not null default 0,
  expira_em  timestamptz,
  ativo      boolean not null default true,
  criado_por uuid default auth.uid(),
  criado_em  timestamptz not null default now()
);
alter table public.convites enable row level security;
drop policy if exists convites_admin on public.convites;
create policy convites_admin on public.convites for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- 3) Perfis (dados do cadastro)
create table if not exists public.perfis (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text,
  tipo         text not null check (tipo in ('prestador','contratante')),
  pessoa       text not null default 'pf' check (pessoa in ('pf','pj')),
  nome         text not null,
  documento    text not null,           -- CPF (11) ou CNPJ (14), só números
  telefone     text not null,
  cidade       text,
  veiculo      text check (veiculo in ('moto','carro','utilitario','caminhao')),
  placa        text,
  modelo       text,
  cnh_validade date,
  status       text not null default 'pendente' check (status in ('pendente','aprovado','recusado','bloqueado')),
  motivo       text,
  convite      text references public.convites(codigo) on delete set null,
  aprovado_em  timestamptz,
  aprovado_por uuid,
  criado_em    timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create unique index if not exists perfis_documento_un on public.perfis(documento);
alter table public.perfis enable row level security;
drop policy if exists perfis_ver on public.perfis;
create policy perfis_ver on public.perfis for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
-- gravação só pelas funções abaixo (sem insert/update/delete direto)

-- 4) Documentos enviados (arquivo fica no Storage privado "documentos/<user_id>/...")
create table if not exists public.documentos (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tipo      text not null check (tipo in ('selfie','cnh','crlv','cnpj','antt','comprovante','outro')),
  caminho   text not null,
  validade  date,
  criado_em timestamptz not null default now()
);
create index if not exists documentos_user_idx on public.documentos(user_id);
alter table public.documentos enable row level security;

create or replace function public.cadastro_editavel() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.perfis where user_id = auth.uid() and status in ('pendente','recusado'));
$$;

drop policy if exists documentos_ver on public.documentos;
create policy documentos_ver on public.documentos for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists documentos_inserir on public.documentos;
create policy documentos_inserir on public.documentos for insert to authenticated
  with check (user_id = auth.uid() and caminho like auth.uid()::text || '/%' and public.cadastro_editavel());
drop policy if exists documentos_apagar on public.documentos;
create policy documentos_apagar on public.documentos for delete to authenticated
  using ((user_id = auth.uid() and public.cadastro_editavel()) or public.is_admin());

-- 5) Storage privado para os documentos (até 8 MB; imagens ou PDF)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documentos','documentos', false, 8388608, array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists docs_storage_enviar on storage.objects;
create policy docs_storage_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and (storage.foldername(name))[1] = auth.uid()::text and public.cadastro_editavel());
drop policy if exists docs_storage_ver on storage.objects;
create policy docs_storage_ver on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));
drop policy if exists docs_storage_apagar on storage.objects;
create policy docs_storage_apagar on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and (((storage.foldername(name))[1] = auth.uid()::text and public.cadastro_editavel()) or public.is_admin()));

-- 6) Funções
-- 6.1 Conferir convite antes de criar a conta (pode ser chamada sem login)
create or replace function public.verificar_convite(p_codigo text) returns text
language sql stable security definer set search_path = public as $$
  select tipo from public.convites
  where codigo = upper(trim(p_codigo)) and ativo and usos < usos_max and (expira_em is null or expira_em > now());
$$;

-- validação comum dos dados
create or replace function public._validar_cadastro(p_tipo text, d jsonb) returns void
language plpgsql immutable set search_path = public as $$
declare doc text := regexp_replace(coalesce(d->>'documento',''), '\D', '', 'g');
        tel text := regexp_replace(coalesce(d->>'telefone',''), '\D', '', 'g');
        pes text := coalesce(nullif(d->>'pessoa',''),'pf');
begin
  if length(trim(coalesce(d->>'nome',''))) < 3 then raise exception 'Informe o nome completo'; end if;
  if pes not in ('pf','pj') then raise exception 'Tipo de pessoa inválido'; end if;
  if pes = 'pf' and length(doc) <> 11 then raise exception 'CPF deve ter 11 números'; end if;
  if pes = 'pj' and length(doc) <> 14 then raise exception 'CNPJ deve ter 14 números'; end if;
  if length(tel) not between 10 and 11 then raise exception 'Telefone com DDD inválido'; end if;
  if p_tipo = 'prestador' then
    if coalesce(d->>'veiculo','') not in ('moto','carro','utilitario','caminhao') then raise exception 'Escolha o tipo de veículo'; end if;
    if length(regexp_replace(coalesce(d->>'placa',''), '[^A-Za-z0-9]', '', 'g')) <> 7 then raise exception 'Placa inválida'; end if;
  end if;
end $$;

-- 6.2 Criar o cadastro usando o convite (usuário logado, ainda sem perfil)
create or replace function public.registrar_cadastro(p_convite text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare c public.convites; uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb);
begin
  if uid is null then raise exception 'Entre com sua conta primeiro'; end if;
  if exists (select 1 from public.membros where user_id = uid and papel in ('admin','funcionario','orcamento')) then
    raise exception 'Esta conta já faz parte da equipe da RL'; end if;
  if exists (select 1 from public.perfis where user_id = uid) then raise exception 'Você já tem um cadastro'; end if;
  select * into c from public.convites where codigo = upper(trim(p_convite)) for update;
  if c.codigo is null or not c.ativo or c.usos >= c.usos_max or (c.expira_em is not null and c.expira_em <= now()) then
    raise exception 'Convite inválido, vencido ou já usado'; end if;
  perform public._validar_cadastro(c.tipo, d);
  if exists (select 1 from public.perfis where documento = regexp_replace(d->>'documento','\D','','g')) then
    raise exception 'Já existe um cadastro com este CPF/CNPJ. Fale com a RL.'; end if;
  insert into public.perfis (user_id, email, tipo, pessoa, nome, documento, telefone, cidade, veiculo, placa, modelo, cnh_validade, convite)
  values (uid, lower(auth.email()), c.tipo, coalesce(nullif(d->>'pessoa',''),'pf'), trim(d->>'nome'),
          regexp_replace(d->>'documento','\D','','g'), regexp_replace(d->>'telefone','\D','','g'),
          nullif(trim(d->>'cidade'),''),
          case when c.tipo='prestador' then d->>'veiculo' end,
          case when c.tipo='prestador' then upper(regexp_replace(d->>'placa','[^A-Za-z0-9]','','g')) end,
          case when c.tipo='prestador' then nullif(trim(d->>'modelo'),'') end,
          case when c.tipo='prestador' then nullif(d->>'cnh_validade','')::date end,
          c.codigo);
  insert into public.membros (user_id, email, papel, ativo) values (uid, lower(auth.email()), c.tipo, false)
  on conflict (user_id) do update set papel = excluded.papel, ativo = false, email = excluded.email;
  update public.convites set usos = usos + 1 where codigo = c.codigo;
  return c.tipo;
end $$;

-- 6.3 Corrigir os dados (só enquanto pendente ou recusado; volta para análise)
create or replace function public.atualizar_cadastro(p_dados jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare p public.perfis; d jsonb := coalesce(p_dados,'{}'::jsonb);
begin
  select * into p from public.perfis where user_id = auth.uid() for update;
  if p.user_id is null then raise exception 'Cadastro não encontrado'; end if;
  if p.status not in ('pendente','recusado') then raise exception 'Cadastro aprovado: para mudar dados, fale com a RL'; end if;
  perform public._validar_cadastro(p.tipo, d);
  if exists (select 1 from public.perfis where documento = regexp_replace(d->>'documento','\D','','g') and user_id <> p.user_id) then
    raise exception 'Já existe um cadastro com este CPF/CNPJ. Fale com a RL.'; end if;
  update public.perfis set
    pessoa = coalesce(nullif(d->>'pessoa',''),'pf'), nome = trim(d->>'nome'),
    documento = regexp_replace(d->>'documento','\D','','g'), telefone = regexp_replace(d->>'telefone','\D','','g'),
    cidade = nullif(trim(d->>'cidade'),''),
    veiculo = case when p.tipo='prestador' then d->>'veiculo' end,
    placa = case when p.tipo='prestador' then upper(regexp_replace(d->>'placa','[^A-Za-z0-9]','','g')) end,
    modelo = case when p.tipo='prestador' then nullif(trim(d->>'modelo'),'') end,
    cnh_validade = case when p.tipo='prestador' then nullif(d->>'cnh_validade','')::date end,
    status = 'pendente', motivo = null, atualizado_em = now()
  where user_id = p.user_id;
end $$;

-- 6.4 Administrador aprova ou recusa
create or replace function public.decidir_cadastro(p_user uuid, p_aprovar boolean, p_motivo text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if not p_aprovar and length(trim(coalesce(p_motivo,''))) < 3 then raise exception 'Informe o motivo da recusa'; end if;
  update public.perfis set
    status = case when p_aprovar then 'aprovado' else 'recusado' end,
    motivo = case when p_aprovar then null else trim(p_motivo) end,
    aprovado_em = case when p_aprovar then now() else null end,
    aprovado_por = case when p_aprovar then auth.uid() else null end,
    atualizado_em = now()
  where user_id = p_user;
  if not found then raise exception 'Cadastro não encontrado'; end if;
  update public.membros set ativo = p_aprovar where user_id = p_user and papel in ('prestador','contratante');
end $$;

-- 6.5 Bloquear e desbloquear também marcam o cadastro
create or replace function public.bloquear_usuario(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if p_user = auth.uid() then raise exception 'Você não pode bloquear a si mesmo'; end if;
  update public.membros set ativo = false where user_id = p_user;
  update public.perfis set status = 'bloqueado', atualizado_em = now() where user_id = p_user;
end $$;

create or replace function public.desbloquear_cadastro(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  update public.perfis set status = 'aprovado', motivo = null, aprovado_em = now(), aprovado_por = auth.uid(), atualizado_em = now()
  where user_id = p_user and status = 'bloqueado';
  if not found then raise exception 'Cadastro não está bloqueado'; end if;
  update public.membros set ativo = true where user_id = p_user and papel in ('prestador','contratante');
end $$;

-- 6.6 Liberar equipe não mexe em quem é prestador/contratante
create or replace function public.liberar_usuario(p_email text, p_papel text default 'funcionario') returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if p_papel not in ('admin','funcionario','orcamento') then raise exception 'Perfil inválido'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'O usuário % ainda não criou o acesso', p_email; end if;
  if uid = auth.uid() and p_papel <> 'admin' then raise exception 'Você não pode tirar seu próprio acesso de administrador'; end if;
  if exists (select 1 from public.perfis where user_id = uid) then
    raise exception 'Este e-mail é de um prestador/contratante. Use a área Cadastros.'; end if;
  insert into public.membros (user_id, email, papel, ativo) values (uid, lower(trim(p_email)), p_papel, true)
  on conflict (user_id) do update set papel = excluded.papel, ativo = true, email = excluded.email;
  return 'ok';
end $$;

-- 6.7 Lista de usuários da equipe não mostra prestadores/contratantes
create or replace function public.listar_usuarios()
returns table (user_id uuid, email text, papel text, ativo boolean, liberado boolean, criado_em timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select u.id, u.email::text, m.papel, coalesce(m.ativo,false), (m.user_id is not null), u.created_at
    from auth.users u left join public.membros m on m.user_id = u.id
    where not exists (select 1 from public.perfis p where p.user_id = u.id)
      and coalesce(m.papel,'') not in ('prestador','contratante')
    order by (m.user_id is not null), u.created_at desc;
end $$;

-- 7) Permissões das funções
revoke all on function public.cadastro_editavel(), public.verificar_convite(text), public._validar_cadastro(text,jsonb),
  public.registrar_cadastro(text,jsonb), public.atualizar_cadastro(jsonb), public.decidir_cadastro(uuid,boolean,text),
  public.bloquear_usuario(uuid), public.desbloquear_cadastro(uuid), public.liberar_usuario(text,text), public.listar_usuarios()
  from public, anon;
grant execute on function public.verificar_convite(text) to anon, authenticated;
grant execute on function public.cadastro_editavel(), public.registrar_cadastro(text,jsonb), public.atualizar_cadastro(jsonb),
  public.decidir_cadastro(uuid,boolean,text), public.bloquear_usuario(uuid), public.desbloquear_cadastro(uuid),
  public.liberar_usuario(text,text), public.listar_usuarios() to authenticated;
