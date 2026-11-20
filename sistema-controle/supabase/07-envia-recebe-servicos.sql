-- Passo 3 da Central RL: quem envia, quem recebe (ou os dois) e os serviços
-- • No cadastro a pessoa marca "envio serviços", "recebo serviços" ou os dois.
-- • Quem envia solta o serviço (retirada, entregas, veículo, valor oferecido).
-- • Quem recebe vê os serviços abertos perto dele (precisa liberar a localização).

-- 1) Envia / recebe no cadastro
alter table public.perfis add column if not exists envia  boolean not null default false;
alter table public.perfis add column if not exists recebe boolean not null default false;
update public.perfis set envia = true  where tipo = 'contratante' and not envia and not recebe;
update public.perfis set recebe = true where tipo = 'prestador'   and not envia and not recebe;
alter table public.perfis drop constraint if exists perfis_envia_ou_recebe;
alter table public.perfis add constraint perfis_envia_ou_recebe check (envia or recebe);

create or replace function public._validar_cadastro(p_tipo text, d jsonb) returns void
language plpgsql immutable set search_path = public as $$
declare doc text := regexp_replace(coalesce(d->>'documento',''), '\D', '', 'g');
        tel text := regexp_replace(coalesce(d->>'telefone',''), '\D', '', 'g');
        pes text := coalesce(nullif(d->>'pessoa',''),'pf');
        env boolean := coalesce((d->>'envia')::boolean, p_tipo = 'contratante');
        rec boolean := coalesce((d->>'recebe')::boolean, p_tipo = 'prestador');
begin
  if not (env or rec) then raise exception 'Marque se você envia serviços, recebe serviços ou os dois'; end if;
  if length(trim(coalesce(d->>'nome',''))) < 3 then raise exception 'Informe o nome completo'; end if;
  if pes not in ('pf','pj') then raise exception 'Tipo de pessoa inválido'; end if;
  if pes = 'pf' and length(doc) <> 11 then raise exception 'CPF deve ter 11 números'; end if;
  if pes = 'pj' and length(doc) <> 14 then raise exception 'CNPJ deve ter 14 números'; end if;
  if length(tel) not between 10 and 11 then raise exception 'Telefone com DDD inválido'; end if;
  if rec then
    if coalesce(d->>'veiculo','') not in ('moto','carro','utilitario','caminhao') then raise exception 'Escolha o tipo de veículo'; end if;
    if length(regexp_replace(coalesce(d->>'placa',''), '[^A-Za-z0-9]', '', 'g')) <> 7 then raise exception 'Placa inválida'; end if;
  end if;
end $$;

create or replace function public.registrar_cadastro(p_convite text, p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare c public.convites; uid uuid := auth.uid(); d jsonb := coalesce(p_dados,'{}'::jsonb); env boolean; rec boolean;
begin
  if uid is null then raise exception 'Entre com sua conta primeiro'; end if;
  if exists (select 1 from public.membros where user_id = uid and papel in ('dono','admin','funcionario','orcamento')) then
    raise exception 'Esta conta já faz parte da equipe da RL'; end if;
  if exists (select 1 from public.perfis where user_id = uid) then raise exception 'Você já tem um cadastro'; end if;
  select * into c from public.convites where codigo = upper(trim(p_convite)) for update;
  if c.codigo is null or not c.ativo or c.usos >= c.usos_max or (c.expira_em is not null and c.expira_em <= now()) then
    raise exception 'Convite inválido, vencido ou já usado'; end if;
  perform public._validar_cadastro(c.tipo, d);
  env := coalesce((d->>'envia')::boolean, c.tipo = 'contratante');
  rec := coalesce((d->>'recebe')::boolean, c.tipo = 'prestador');
  if exists (select 1 from public.perfis where documento = regexp_replace(d->>'documento','\D','','g')) then
    raise exception 'Já existe um cadastro com este CPF/CNPJ. Fale com a RL.'; end if;
  insert into public.perfis (user_id, email, tipo, envia, recebe, pessoa, nome, documento, telefone, cidade, veiculo, placa, modelo, cnh_validade, convite)
  values (uid, lower(auth.email()), case when rec then 'prestador' else 'contratante' end, env, rec,
          coalesce(nullif(d->>'pessoa',''),'pf'), trim(d->>'nome'),
          regexp_replace(d->>'documento','\D','','g'), regexp_replace(d->>'telefone','\D','','g'),
          nullif(trim(d->>'cidade'),''),
          case when rec then d->>'veiculo' end,
          case when rec then upper(regexp_replace(d->>'placa','[^A-Za-z0-9]','','g')) end,
          case when rec then nullif(trim(d->>'modelo'),'') end,
          case when rec then nullif(d->>'cnh_validade','')::date end,
          c.codigo);
  insert into public.membros (user_id, email, papel, ativo) values (uid, lower(auth.email()), case when rec then 'prestador' else 'contratante' end, false)
  on conflict (user_id) do update set papel = excluded.papel, ativo = false, email = excluded.email;
  update public.convites set usos = usos + 1 where codigo = c.codigo;
  return c.tipo;
end $$;

create or replace function public.atualizar_cadastro(p_dados jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare p public.perfis; d jsonb := coalesce(p_dados,'{}'::jsonb); env boolean; rec boolean;
begin
  select * into p from public.perfis where user_id = auth.uid() for update;
  if p.user_id is null then raise exception 'Cadastro não encontrado'; end if;
  if p.status not in ('pendente','recusado') then raise exception 'Cadastro aprovado: para mudar dados, fale com a RL'; end if;
  env := coalesce((d->>'envia')::boolean, p.envia);
  rec := coalesce((d->>'recebe')::boolean, p.recebe);
  perform public._validar_cadastro(p.tipo, d || jsonb_build_object('envia',env,'recebe',rec));
  if exists (select 1 from public.perfis where documento = regexp_replace(d->>'documento','\D','','g') and user_id <> p.user_id) then
    raise exception 'Já existe um cadastro com este CPF/CNPJ. Fale com a RL.'; end if;
  update public.perfis set
    envia = env, recebe = rec, tipo = case when rec then 'prestador' else 'contratante' end,
    pessoa = coalesce(nullif(d->>'pessoa',''),'pf'), nome = trim(d->>'nome'),
    documento = regexp_replace(d->>'documento','\D','','g'), telefone = regexp_replace(d->>'telefone','\D','','g'),
    cidade = nullif(trim(d->>'cidade'),''),
    veiculo = case when rec then d->>'veiculo' end,
    placa = case when rec then upper(regexp_replace(d->>'placa','[^A-Za-z0-9]','','g')) end,
    modelo = case when rec then nullif(trim(d->>'modelo'),'') end,
    cnh_validade = case when rec then nullif(d->>'cnh_validade','')::date end,
    status = 'pendente', motivo = null, atualizado_em = now()
  where user_id = p.user_id;
  update public.membros set papel = case when rec then 'prestador' else 'contratante' end where user_id = p.user_id;
end $$;

-- 2) Chave pública do Mapbox para o app (só para quem já foi aprovado; não fica no código público)
alter table public.config_sistema drop constraint if exists config_sistema_chave_check;
alter table public.config_sistema add constraint config_sistema_chave_check check (chave in ('distribuicao','espera','creditos','mapa'));

-- 3) Serviços
create table if not exists public.servicos (
  id            uuid primary key default gen_random_uuid(),
  numero        bigint generated always as identity,
  criado_por    uuid not null references auth.users(id),
  retirada      jsonb not null,                       -- {e, la, lo}
  paradas       jsonb not null,                       -- [{e, la, lo, t}]
  km            numeric not null check (km > 0 and km < 1000),
  minutos       int,
  veiculo       text not null check (veiculo in ('moto','carro','utilitario','caminhao')),
  valor         numeric not null check (valor >= 5 and valor <= 50000),
  agendado_para timestamptz,
  obs           text check (length(obs) <= 500),
  status        text not null default 'aberto' check (status in ('aberto','aceito','em_andamento','concluido','cancelado')),
  pego_por      uuid references auth.users(id),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);
create index if not exists servicos_abertos on public.servicos (status, criado_em) where status = 'aberto';
alter table public.servicos enable row level security;
drop policy if exists servicos_ver on public.servicos;
create policy servicos_ver on public.servicos for select to authenticated
  using (criado_por = auth.uid() or pego_por = auth.uid() or public.is_admin());
-- sem insert/update/delete direto: só pelas funções

create table if not exists public.localizacoes (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  lat           double precision not null,
  lon           double precision not null,
  atualizado_em timestamptz not null default now()
);
alter table public.localizacoes enable row level security;
drop policy if exists localizacoes_ver on public.localizacoes;
create policy localizacoes_ver on public.localizacoes for select to authenticated using (user_id = auth.uid() or public.is_admin());

create or replace function public._perfil_ativo() returns public.perfis
language sql stable security definer set search_path = public as $$
  select p.* from public.perfis p join public.membros m on m.user_id = p.user_id
  where p.user_id = auth.uid() and p.status = 'aprovado' and m.ativo and m.removido_em is null;
$$;

create or replace function public._dist_km(lat1 double precision, lon1 double precision, lat2 double precision, lon2 double precision)
returns double precision language sql immutable as $$
  select 6371 * 2 * asin(sqrt(power(sin(radians(lat2-lat1)/2),2) + cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lon2-lon1)/2),2)));
$$;

create or replace function public._ponto_ok(p jsonb) returns boolean language sql immutable as $$
  select length(trim(coalesce(p->>'e',''))) between 5 and 300
     and (p->>'la')::double precision between -34 and 6 and (p->>'lo')::double precision between -75 and -28;
$$;

create or replace function public.servico_soltar(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); novo uuid; ag timestamptz;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.envia then raise exception 'Seu cadastro não está marcado para enviar serviços'; end if;
  if not public._ponto_ok(p->'retirada') then raise exception 'Endereço de retirada inválido'; end if;
  if jsonb_typeof(p->'paradas') <> 'array' or jsonb_array_length(p->'paradas') not between 1 and 20 then raise exception 'Informe de 1 a 20 entregas'; end if;
  if exists (select 1 from jsonb_array_elements(p->'paradas') x where not public._ponto_ok(x)) then raise exception 'Endereço de entrega inválido'; end if;
  ag := nullif(p->>'agendado_para','')::timestamptz;
  if ag is not null and (ag < now() - interval '10 minutes' or ag > now() + interval '60 days') then raise exception 'Data do agendamento inválida'; end if;
  insert into public.servicos (criado_por, retirada, paradas, km, minutos, veiculo, valor, agendado_para, obs)
  values (auth.uid(), p->'retirada', p->'paradas', (p->>'km')::numeric, nullif(p->>'minutos','')::int, p->>'veiculo',
          round((p->>'valor')::numeric, 2), ag, nullif(trim(p->>'obs'),''))
  returning id into novo;
  return novo;
end $$;

create or replace function public.servico_cancelar(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
begin
  update public.servicos set status = 'cancelado', atualizado_em = now()
  where id = p_id and criado_por = auth.uid() and status = 'aberto';
  if not found then raise exception 'Só dá para cancelar um serviço seu que ainda está aberto'; end if;
  return 'ok';
end $$;

-- quem recebe: guarda onde ele está e devolve os serviços abertos perto dele
create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, criado_em timestamptz, distancia_km numeric)
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); cfg jsonb; r0 numeric; rmax numeric; amp int;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  if p_lat is null or p_lon is null or p_lat not between -34 and 6 or p_lon not between -75 and -28 then raise exception 'Localização inválida'; end if;
  insert into public.localizacoes (user_id, lat, lon, atualizado_em) values (auth.uid(), p_lat, p_lon, now())
  on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, atualizado_em = now();
  select c.valor into cfg from public.config_sistema c where c.chave = 'distribuicao';
  r0 := coalesce((cfg->>'raio_inicial_km')::numeric, 3); rmax := coalesce((cfg->>'raio_maximo_km')::numeric, 10); amp := coalesce((cfg->>'minutos_ate_ampliar')::int, 5);
  return query
    select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.criado_em,
           round(public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision)::numeric, 1)
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
    order by 12 asc, s.criado_em asc
    limit 50;
end $$;

revoke all on function public.servico_soltar(jsonb), public.servico_cancelar(uuid), public.servicos_proximos(double precision,double precision) from public, anon;
grant execute on function public.servico_soltar(jsonb), public.servico_cancelar(uuid), public.servicos_proximos(double precision,double precision) to authenticated;
