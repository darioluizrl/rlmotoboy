-- Passo 4 da Central RL: candidatura (até N por serviço), escolha e chat do serviço
-- • Quem recebe se candidata a um serviço aberto perto dele (limite em config_sistema.distribuicao.max_candidatos).
-- • Quem enviou vê os candidatos e escolhe um. Os outros ficam como "não escolhido".
-- • Depois da escolha abre o chat entre os dois. Todos os administradores leem e podem escrever.

create table if not exists public.candidaturas (
  servico_id   uuid not null references public.servicos(id) on delete cascade,
  prestador_id uuid not null references auth.users(id),
  status       text not null default 'ativa' check (status in ('ativa','escolhida','recusada','desistiu')),
  distancia_km numeric,
  criado_em    timestamptz not null default now(),
  primary key (servico_id, prestador_id)
);
alter table public.candidaturas enable row level security;
drop policy if exists candidaturas_ver on public.candidaturas;
create policy candidaturas_ver on public.candidaturas for select to authenticated using (
  prestador_id = auth.uid() or public.is_admin()
  or exists (select 1 from public.servicos s where s.id = servico_id and s.criado_por = auth.uid()));

create table if not exists public.mensagens (
  id         bigint generated always as identity primary key,
  servico_id uuid not null references public.servicos(id) on delete cascade,
  autor      uuid not null references auth.users(id),
  texto      text not null check (length(texto) between 1 and 1000),
  criado_em  timestamptz not null default now()
);
create index if not exists mensagens_servico on public.mensagens (servico_id, id);
alter table public.mensagens enable row level security;
drop policy if exists mensagens_ver on public.mensagens;
create policy mensagens_ver on public.mensagens for select to authenticated using (
  public.is_admin()
  or exists (select 1 from public.servicos s where s.id = servico_id and (s.criado_por = auth.uid() or s.pego_por = auth.uid())));
do $$ begin
  alter publication supabase_realtime add table public.mensagens;
exception when duplicate_object then null; end $$;

-- candidatar
create or replace function public.servico_candidatar(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); s public.servicos; cfg jsonb; maxc int; n int; loc public.localizacoes; dist numeric; rmax numeric;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  select * into s from public.servicos where id = p_id for update;
  if s.id is null or s.status <> 'aberto' then raise exception 'Este serviço não está mais aberto'; end if;
  if s.criado_por = auth.uid() then raise exception 'Você não pode pegar o próprio serviço'; end if;
  if not (s.veiculo = 'moto' and me.veiculo = 'moto'
          or s.veiculo = 'carro' and me.veiculo in ('carro','utilitario')
          or s.veiculo = 'utilitario' and me.veiculo in ('utilitario','caminhao')
          or s.veiculo = 'caminhao' and me.veiculo = 'caminhao') then
    raise exception 'Este serviço é para outro tipo de veículo'; end if;
  select c.valor into cfg from public.config_sistema c where c.chave = 'distribuicao';
  maxc := coalesce((cfg->>'max_candidatos')::int, 3); rmax := coalesce((cfg->>'raio_maximo_km')::numeric, 10);
  select * into loc from public.localizacoes where user_id = auth.uid();
  if loc.user_id is null or loc.atualizado_em < now() - interval '10 minutes' then raise exception 'Libere sua localização para se candidatar'; end if;
  dist := round(public._dist_km(loc.lat, loc.lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision)::numeric, 1);
  if dist > rmax then raise exception 'Você está longe demais da retirada'; end if;
  if exists (select 1 from public.candidaturas where servico_id = p_id and prestador_id = auth.uid() and status = 'ativa') then return 'ja'; end if;
  select count(*) into n from public.candidaturas where servico_id = p_id and status = 'ativa';
  if n >= maxc then raise exception 'Este serviço já tem % candidatos', maxc; end if;
  insert into public.candidaturas (servico_id, prestador_id, distancia_km) values (p_id, auth.uid(), dist)
  on conflict (servico_id, prestador_id) do update set status = 'ativa', distancia_km = excluded.distancia_km, criado_em = now();
  return 'ok';
end $$;

create or replace function public.servico_desistir(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.candidaturas set status = 'desistiu' where servico_id = p_id and prestador_id = auth.uid() and status = 'ativa';
  if not found then raise exception 'Você não tem candidatura ativa neste serviço'; end if;
  return 'ok';
end $$;

-- quem enviou (ou administrador) vê os candidatos
create or replace function public.servico_candidatos(p_id uuid)
returns table(prestador_id uuid, nome text, veiculo text, modelo text, placa text, cidade text, distancia_km numeric,
              status text, criado_em timestamptz, servicos_feitos bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.servicos s where s.id = p_id and (s.criado_por = auth.uid() or public.is_admin())) then
    raise exception 'Serviço não encontrado'; end if;
  return query
    select c.prestador_id, p.nome, p.veiculo, p.modelo,
           left(p.placa,3) || '-' || right(p.placa,2) as placa,   -- placa parcial antes da escolha
           p.cidade, c.distancia_km, c.status, c.criado_em,
           (select count(*) from public.servicos x where x.pego_por = c.prestador_id and x.status = 'concluido')
    from public.candidaturas c join public.perfis p on p.user_id = c.prestador_id
    where c.servico_id = p_id and c.status in ('ativa','escolhida')
    order by c.status = 'escolhida' desc, c.criado_em;
end $$;

create or replace function public.servico_escolher(p_id uuid, p_prestador uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where id = p_id for update;
  if s.id is null or s.criado_por <> auth.uid() then raise exception 'Serviço não encontrado'; end if;
  if s.status <> 'aberto' then raise exception 'Este serviço já tem alguém escolhido'; end if;
  if not exists (select 1 from public.candidaturas where servico_id = p_id and prestador_id = p_prestador and status = 'ativa') then
    raise exception 'Este candidato desistiu. Escolha outro.'; end if;
  if not exists (select 1 from public.membros m join public.perfis p on p.user_id = m.user_id
                 where m.user_id = p_prestador and m.ativo and m.removido_em is null and p.status = 'aprovado') then
    raise exception 'Este candidato não está mais ativo. Escolha outro.'; end if;
  update public.servicos set status = 'aceito', pego_por = p_prestador, atualizado_em = now() where id = p_id;
  update public.candidaturas set status = case when prestador_id = p_prestador then 'escolhida' else 'recusada' end
  where servico_id = p_id and status = 'ativa';
  insert into public.mensagens (servico_id, autor, texto)
  values (p_id, auth.uid(), 'Serviço confirmado. Combine os detalhes da retirada por aqui.');
  return 'ok';
end $$;

-- quem recebe: as próprias candidaturas e os serviços pegos
create or replace function public.meus_trabalhos()
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, status text, minha text, criado_em timestamptz, quem_enviou text)
language sql stable security definer set search_path = public as $$
  select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.status,
         c.status, s.criado_em, case when s.pego_por = auth.uid() then p.nome end
  from public.candidaturas c join public.servicos s on s.id = c.servico_id join public.perfis p on p.user_id = s.criado_por
  where c.prestador_id = auth.uid() and c.criado_em > now() - interval '30 days'
    and (c.status = 'ativa' or (c.status = 'escolhida' and s.status in ('aceito','em_andamento','concluido')) or c.status = 'recusada')
  order by (c.status = 'escolhida' and s.status in ('aceito','em_andamento')) desc, c.criado_em desc
  limit 30;
$$;

-- chat
create or replace function public.chat_listar(p_id uuid, p_depois bigint default 0)
returns table(id bigint, autor uuid, nome text, papel text, texto text, criado_em timestamptz)
language plpgsql security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where servicos.id = p_id;
  if s.id is null or not (s.criado_por = auth.uid() or s.pego_por = auth.uid() or public.is_admin()) then
    raise exception 'Conversa não encontrada'; end if;
  return query
    select m.id, m.autor,
           coalesce(p.nome, split_part(mb.email,'@',1)),
           case when m.autor = s.criado_por then 'enviou' when m.autor = s.pego_por then 'pegou' else 'rl' end,
           m.texto, m.criado_em
    from public.mensagens m left join public.perfis p on p.user_id = m.autor left join public.membros mb on mb.user_id = m.autor
    where m.servico_id = p_id and m.id > coalesce(p_depois,0)
    order by m.id limit 500;
end $$;

create or replace function public.chat_enviar(p_id uuid, p_texto text) returns bigint
language plpgsql security definer set search_path = public as $$
declare s public.servicos; novo bigint; t text := btrim(coalesce(p_texto,''));
begin
  select * into s from public.servicos where id = p_id;
  if s.id is null or not (s.criado_por = auth.uid() or s.pego_por = auth.uid() or public.is_admin()) then
    raise exception 'Conversa não encontrada'; end if;
  if s.pego_por is null then raise exception 'O chat abre quando alguém for escolhido para o serviço'; end if;
  if not public.is_admin() and s.status in ('cancelado') then raise exception 'Este serviço foi cancelado'; end if;
  if length(t) = 0 then raise exception 'Mensagem vazia'; end if;
  if length(t) > 1000 then raise exception 'Mensagem muito longa (máximo 1000 letras)'; end if;
  if not public.is_admin() and (select count(*) from public.mensagens where autor = auth.uid() and criado_em > now() - interval '1 minute') >= 20 then
    raise exception 'Muitas mensagens seguidas. Espere um pouco.'; end if;
  insert into public.mensagens (servico_id, autor, texto) values (p_id, auth.uid(), t) returning id into novo;
  return novo;
end $$;

-- lista dos serviços perto: agora diz quantos candidatos já tem e se eu já me candidatei; esconde os lotados
drop function if exists public.servicos_proximos(double precision, double precision);
create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, criado_em timestamptz, distancia_km numeric, candidatos int, max_candidatos int, eu_candidato boolean)
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); cfg jsonb; r0 numeric; rmax numeric; amp int; maxc int;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  if p_lat is null or p_lon is null or p_lat not between -34 and 6 or p_lon not between -75 and -28 then raise exception 'Localização inválida'; end if;
  insert into public.localizacoes (user_id, lat, lon, atualizado_em) values (auth.uid(), p_lat, p_lon, now())
  on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, atualizado_em = now();
  select c.valor into cfg from public.config_sistema c where c.chave = 'distribuicao';
  r0 := coalesce((cfg->>'raio_inicial_km')::numeric, 3); rmax := coalesce((cfg->>'raio_maximo_km')::numeric, 10);
  amp := coalesce((cfg->>'minutos_ate_ampliar')::int, 5); maxc := coalesce((cfg->>'max_candidatos')::int, 3);
  return query
    select q.* from (
      select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.criado_em,
             round(public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision)::numeric, 1) as dist,
             (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status = 'ativa') as ncand,
             maxc as maxc,
             exists (select 1 from public.candidaturas c where c.servico_id = s.id and c.prestador_id = auth.uid() and c.status = 'ativa') as eu
      from public.servicos s
      where s.status = 'aberto' and s.criado_por <> auth.uid()
        and (s.agendado_para is null or s.agendado_para > now() - interval '30 minutes')
        and case s.veiculo when 'moto' then me.veiculo = 'moto'
                           when 'carro' then me.veiculo in ('carro','utilitario')
                           when 'utilitario' then me.veiculo in ('utilitario','caminhao')
                           else me.veiculo = 'caminhao' end
        and (  public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision) <= r0
            or (s.criado_em <= now() - make_interval(mins => amp)
                and public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision) <= rmax))
    ) q
    where q.eu or q.ncand < q.maxc
    order by q.eu desc, q.dist asc, q.criado_em asc
    limit 50;
end $$;

-- painel da RL: todos os serviços com quem enviou, quem pegou e quantos candidatos
create or replace function public.adm_servicos(p_dias int default 7)
returns table(id uuid, numero bigint, status text, retirada jsonb, paradas jsonb, km numeric, veiculo text, valor numeric,
              agendado_para timestamptz, criado_em timestamptz, quem_enviou text, quem_pegou text, candidatos int, mensagens int)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select s.id, s.numero, s.status, s.retirada, s.paradas, s.km, s.veiculo, s.valor, s.agendado_para, s.criado_em,
           pe.nome, pp.nome,
           (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status in ('ativa','escolhida')),
           (select count(*)::int from public.mensagens m where m.servico_id = s.id)
    from public.servicos s left join public.perfis pe on pe.user_id = s.criado_por left join public.perfis pp on pp.user_id = s.pego_por
    where s.criado_em > now() - make_interval(days => greatest(1, least(coalesce(p_dias,7), 90)))
    order by s.criado_em desc limit 300;
end $$;

revoke all on function public.servico_candidatar(uuid), public.servico_desistir(uuid), public.servico_candidatos(uuid),
  public.servico_escolher(uuid,uuid), public.meus_trabalhos(), public.chat_listar(uuid,bigint), public.chat_enviar(uuid,text),
  public.servicos_proximos(double precision,double precision), public.adm_servicos(int) from public, anon;
grant execute on function public.servico_candidatar(uuid), public.servico_desistir(uuid), public.servico_candidatos(uuid),
  public.servico_escolher(uuid,uuid), public.meus_trabalhos(), public.chat_listar(uuid,bigint), public.chat_enviar(uuid,text),
  public.servicos_proximos(double precision,double precision), public.adm_servicos(int) to authenticated;
