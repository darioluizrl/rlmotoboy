-- Passo 2 da Central RL: perfil RL (dono) e menu Configuração
-- • "dono" = a RL. Só existe um. Tem tudo o que o administrador tem e mais:
--   adicionar, mudar perfil, bloquear, remover e restaurar QUALQUER usuário, e mudar as regras do sistema.
-- • Administradores continuam aprovando cadastros, mas não bloqueiam nem removem ninguém.
-- • Remover não apaga: tira o acesso e guarda o histórico (serviços, conversas, financeiro).

-- 1) Perfil dono
alter table public.membros drop constraint if exists membros_papel_check;
alter table public.membros add constraint membros_papel_check
  check (papel in ('dono','admin','funcionario','orcamento','prestador','contratante'));
alter table public.membros add column if not exists removido_em timestamptz;
create unique index if not exists membros_um_dono on public.membros ((true)) where papel = 'dono';

create or replace function public.is_dono() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.membros where user_id = auth.uid() and ativo and papel = 'dono');
$$;
-- o dono também é administrador em todas as regras que já existem
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.membros where user_id = auth.uid() and ativo and papel in ('dono','admin'));
$$;

-- regras da tabela docs (dados internos da RL) passam a aceitar o dono
drop policy if exists docs_ler on public.docs;
create policy docs_ler on public.docs for select to authenticated using (
  public.papel_atual() in ('dono','admin','funcionario')
  or (public.papel_atual() = 'orcamento' and colecao in ('orcamentos','clientes','config')));
drop policy if exists docs_inserir on public.docs;
create policy docs_inserir on public.docs for insert to authenticated with check (
  public.papel_atual() in ('dono','admin','funcionario')
  or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos'));
drop policy if exists docs_alterar on public.docs;
create policy docs_alterar on public.docs for update to authenticated using (
  public.papel_atual() in ('dono','admin','funcionario')
  or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos')) with check (
  public.papel_atual() in ('dono','admin','funcionario')
  or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos'));
drop policy if exists docs_apagar on public.docs;
create policy docs_apagar on public.docs for delete to authenticated using (
  public.papel_atual() in ('dono','admin','funcionario')
  or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos'));

-- 2) Regras do sistema (todos que estão logados leem; só o dono grava)
create table if not exists public.config_sistema (
  chave          text primary key check (chave in ('distribuicao','espera','creditos')),
  valor          jsonb not null,
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid
);
alter table public.config_sistema enable row level security;
drop policy if exists config_ler on public.config_sistema;
create policy config_ler on public.config_sistema for select to authenticated using (public.is_membro());
insert into public.config_sistema (chave, valor) values
  ('distribuicao', '{"raio_inicial_km":3,"minutos_ate_ampliar":5,"raio_maximo_km":10,"max_candidatos":3}'),
  ('espera',       '{"minutos_gratis":15,"valor_minuto":0.50}'),
  ('creditos',     '{"valor_credito":0.50,"creditos_envia":2,"creditos_pega":1}')
on conflict (chave) do nothing;

-- 3) Funções do menu Configuração (todas exigem o dono)
create or replace function public._exige_dono() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_dono() then raise exception 'Apenas a RL (dono do sistema) pode fazer isso'; end if;
end $$;

-- 3.1 Lista completa: equipe, quem solta serviço, motoboys/motoristas e quem só criou o acesso
create or replace function public.cfg_usuarios()
returns table(user_id uuid, email text, nome text, papel text, tipo text, ativo boolean, cadastro text,
              removido_em timestamptz, criado_em timestamptz, ultimo_acesso timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return query
    select u.id, u.email::text, p.nome, m.papel, p.tipo, coalesce(m.ativo,false), p.status,
           m.removido_em, u.created_at, u.last_sign_in_at
    from auth.users u
    left join public.membros m on m.user_id = u.id
    left join public.perfis  p on p.user_id = u.id
    order by (m.papel = 'dono') desc nulls last, u.created_at desc;
end $$;

-- 3.2 Adicionar à equipe ou mudar o perfil de alguém da equipe
create or replace function public.cfg_definir_papel(p_email text, p_papel text) returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform public._exige_dono();
  if p_papel not in ('admin','funcionario','orcamento') then raise exception 'Perfil inválido'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'O e-mail % ainda não criou o acesso no sistema', p_email; end if;
  if uid = auth.uid() then raise exception 'Você não pode mudar o seu próprio perfil'; end if;
  if exists (select 1 from public.perfis where user_id = uid) then
    raise exception 'Este e-mail é de uma empresa/motoboy. O perfil dele vem do cadastro.'; end if;
  insert into public.membros (user_id, email, papel, ativo, removido_em)
  values (uid, lower(trim(p_email)), p_papel, true, null)
  on conflict (user_id) do update set papel = excluded.papel, ativo = true, removido_em = null, email = excluded.email;
  return 'ok';
end $$;

-- 3.3 Bloquear / desbloquear qualquer um (menos a RL)
create or replace function public.cfg_bloquear(p_user uuid, p_bloquear boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  if p_user = auth.uid() then raise exception 'Você não pode bloquear a si mesmo'; end if;
  if not exists (select 1 from auth.users where id = p_user) then raise exception 'Usuário não encontrado'; end if;
  if exists (select 1 from public.membros where user_id = p_user and removido_em is not null) then
    raise exception 'Este usuário foi removido. Use Restaurar.'; end if;
  if p_bloquear then
    update public.membros set ativo = false where user_id = p_user;
    update public.perfis  set status = 'bloqueado', atualizado_em = now() where user_id = p_user;
  else
    update public.membros set ativo = true where user_id = p_user;
    update public.perfis  set status = 'aprovado', motivo = null, aprovado_em = coalesce(aprovado_em, now()),
                              aprovado_por = coalesce(aprovado_por, auth.uid()), atualizado_em = now()
    where user_id = p_user and status = 'bloqueado';
  end if;
  return 'ok';
end $$;

-- 3.4 Remover (tira o acesso e guarda o histórico) / restaurar
create or replace function public.cfg_remover(p_user uuid, p_remover boolean) returns text
language plpgsql security definer set search_path = public as $$
declare em text;
begin
  perform public._exige_dono();
  if p_user = auth.uid() then raise exception 'Você não pode remover a si mesmo'; end if;
  select email into em from auth.users where id = p_user;
  if em is null then raise exception 'Usuário não encontrado'; end if;
  if p_remover then
    -- quem só tinha criado o acesso ganha uma linha para ficar marcado como removido
    insert into public.membros (user_id, email, papel, ativo, removido_em)
    values (p_user, lower(em), coalesce((select tipo from public.perfis where user_id = p_user),'funcionario'), false, now())
    on conflict (user_id) do update set ativo = false, removido_em = now();
    update public.perfis set status = 'bloqueado', motivo = 'Removido pela RL', atualizado_em = now() where user_id = p_user;
  else
    update public.membros set ativo = true, removido_em = null where user_id = p_user;
    update public.perfis set status = 'aprovado', motivo = null, atualizado_em = now() where user_id = p_user and status = 'bloqueado';
  end if;
  return 'ok';
end $$;

-- 3.5 Salvar regras do sistema (com conferência dos valores)
create or replace function public.cfg_salvar(p_chave text, p_valor jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  perform public._exige_dono();
  if p_chave = 'distribuicao' then
    if (p_valor->>'raio_inicial_km')::numeric not between 0.5 and 50
       or (p_valor->>'raio_maximo_km')::numeric not between 0.5 and 100
       or (p_valor->>'raio_maximo_km')::numeric < (p_valor->>'raio_inicial_km')::numeric
       or (p_valor->>'minutos_ate_ampliar')::int not between 1 and 120
       or (p_valor->>'max_candidatos')::int not between 1 and 20 then
      raise exception 'Valores de distribuição inválidos'; end if;
    v := jsonb_build_object('raio_inicial_km',(p_valor->>'raio_inicial_km')::numeric,'minutos_ate_ampliar',(p_valor->>'minutos_ate_ampliar')::int,
                            'raio_maximo_km',(p_valor->>'raio_maximo_km')::numeric,'max_candidatos',(p_valor->>'max_candidatos')::int);
  elsif p_chave = 'espera' then
    if (p_valor->>'minutos_gratis')::int not between 0 and 120 or (p_valor->>'valor_minuto')::numeric not between 0 and 50 then
      raise exception 'Valores de espera inválidos'; end if;
    v := jsonb_build_object('minutos_gratis',(p_valor->>'minutos_gratis')::int,'valor_minuto',(p_valor->>'valor_minuto')::numeric);
  elsif p_chave = 'creditos' then
    if coalesce((p_valor->>'valor_credito')::numeric,1) not between 0.01 and 1000
       or coalesce((p_valor->>'creditos_envia')::numeric,1) not between 0 and 1000
       or coalesce((p_valor->>'creditos_pega')::numeric,1) not between 0 and 1000 then
      raise exception 'Valores de créditos inválidos'; end if;
    v := jsonb_build_object('valor_credito',(p_valor->>'valor_credito')::numeric,
                            'creditos_envia',(p_valor->>'creditos_envia')::numeric,'creditos_pega',(p_valor->>'creditos_pega')::numeric);
  else
    raise exception 'Configuração desconhecida';
  end if;
  update public.config_sistema set valor = v, atualizado_em = now(), atualizado_por = auth.uid() where chave = p_chave;
  return 'ok';
end $$;

-- 4) Bloquear/desbloquear e liberar equipe passam a ser só da RL
create or replace function public.bloquear_usuario(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform public.cfg_bloquear(p_user, true); end $$;
create or replace function public.desbloquear_cadastro(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin perform public.cfg_bloquear(p_user, false); end $$;
create or replace function public.liberar_usuario(p_email text, p_papel text default 'funcionario') returns text
language plpgsql security definer set search_path = public as $$
begin return public.cfg_definir_papel(p_email, p_papel); end $$;

-- 4b) Administrador aprova/recusa cadastro, mas não reativa quem a RL bloqueou ou removeu
create or replace function public.decidir_cadastro(p_user uuid, p_aprovar boolean, p_motivo text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if not public.is_dono() and exists (select 1 from public.perfis where user_id = p_user and status = 'bloqueado') then
    raise exception 'Este cadastro foi bloqueado pela RL. Só a RL pode liberar.'; end if;
  if not p_aprovar and length(trim(coalesce(p_motivo,''))) < 3 then raise exception 'Informe o motivo da recusa'; end if;
  update public.perfis set
    status = case when p_aprovar then 'aprovado' else 'recusado' end,
    motivo = case when p_aprovar then null else trim(p_motivo) end,
    aprovado_em = case when p_aprovar then now() else null end,
    aprovado_por = case when p_aprovar then auth.uid() else null end,
    atualizado_em = now()
  where user_id = p_user;
  if not found then raise exception 'Cadastro não encontrado'; end if;
  update public.membros set ativo = p_aprovar where user_id = p_user and papel in ('prestador','contratante') and removido_em is null;
end $$;

revoke all on function public.cfg_usuarios() from public, anon;
revoke all on function public.cfg_definir_papel(text,text) from public, anon;
revoke all on function public.cfg_bloquear(uuid,boolean) from public, anon;
revoke all on function public.cfg_remover(uuid,boolean) from public, anon;
revoke all on function public.cfg_salvar(text,jsonb) from public, anon;
grant execute on function public.cfg_usuarios(), public.cfg_definir_papel(text,text), public.cfg_bloquear(uuid,boolean),
  public.cfg_remover(uuid,boolean), public.cfg_salvar(text,jsonb), public.is_dono() to authenticated;

-- 5) A RL vira dono (só no ambiente onde este arquivo for aplicado)
update public.membros set papel = 'dono' where lower(email) = 'darioluizserafim@gmail.com';
