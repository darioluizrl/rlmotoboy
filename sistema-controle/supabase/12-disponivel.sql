-- Botão "Disponível" do motoboy/motorista:
-- • Ligado: o app manda a localização, ele vê e recebe serviços e aparece no mapa da RL.
-- • Desligado: não vê serviços, não se candidata e some do mapa (a não ser que esteja em um serviço).
alter table public.perfis add column if not exists disponivel boolean not null default false;
alter table public.perfis add column if not exists disponivel_em timestamptz;

create or replace function public.minha_disponibilidade(p_ligar boolean) returns boolean
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo();
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  update public.perfis set disponivel = coalesce(p_ligar,false), disponivel_em = now() where user_id = auth.uid();
  if not coalesce(p_ligar,false) then
    delete from public.localizacoes where user_id = auth.uid();
    update public.candidaturas set status = 'desistiu' where prestador_id = auth.uid() and status = 'ativa';
  end if;
  return coalesce(p_ligar,false);
end $$;
revoke all on function public.minha_disponibilidade(boolean) from public, anon;
grant execute on function public.minha_disponibilidade(boolean) to authenticated;

create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, criado_em timestamptz, distancia_km numeric, candidatos int, max_candidatos int, eu_candidato boolean)
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); cfg jsonb; r0 numeric; rmax numeric; amp int; todos int; maxc int;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  if not me.disponivel then raise exception 'Ligue o botão Disponível para receber serviços'; end if;
  if p_lat is null or p_lon is null or p_lat not between -34 and 6 or p_lon not between -75 and -28 then raise exception 'Localização inválida'; end if;
  insert into public.localizacoes (user_id, lat, lon, atualizado_em) values (auth.uid(), p_lat, p_lon, now())
  on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, atualizado_em = now();
  select c.valor into cfg from public.config_sistema c where c.chave = 'distribuicao';
  r0 := coalesce((cfg->>'raio_inicial_km')::numeric, 3); rmax := coalesce((cfg->>'raio_maximo_km')::numeric, 10);
  amp := coalesce((cfg->>'minutos_ate_ampliar')::int, 5); todos := coalesce((cfg->>'minutos_para_todos')::int, 10);
  maxc := coalesce((cfg->>'max_candidatos')::int, 3);
  return query
    select q.id, q.numero, q.retirada, q.paradas, q.km, q.minutos, q.veiculo, q.valor, q.agendado_para, q.obs, q.criado_em, q.dist, q.ncand, q.maxc, q.eu
    from (
      select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.criado_em,
             round(public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision)::numeric, 1) as dist,
             (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status = 'ativa') as ncand,
             maxc as maxc,
             exists (select 1 from public.candidaturas c where c.servico_id = s.id and c.prestador_id = auth.uid() and c.status = 'ativa') as eu,
             s.criado_em <= now() - make_interval(mins => todos) as p_todos
      from public.servicos s
      where s.status = 'aberto' and s.criado_por <> auth.uid()
        and (s.agendado_para is null or s.agendado_para > now() - interval '30 minutes')
        and case s.veiculo when 'moto' then me.veiculo = 'moto'
                           when 'carro' then me.veiculo in ('carro','utilitario')
                           when 'utilitario' then me.veiculo in ('utilitario','caminhao')
                           else me.veiculo = 'caminhao' end
        and (  public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision) <= r0
            or (s.criado_em <= now() - make_interval(mins => amp)
                and public._dist_km(p_lat, p_lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision) <= rmax)
            or s.criado_em <= now() - make_interval(mins => todos))
    ) q
    where q.eu or q.ncand < q.maxc
    order by q.eu desc, q.dist asc, q.criado_em asc
    limit 50;
end $$;

create or replace function public.servico_candidatar(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); s public.servicos; cfg jsonb; maxc int; n int; loc public.localizacoes; dist numeric; rmax numeric; todos int;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  if not me.disponivel then raise exception 'Ligue o botão Disponível para receber serviços'; end if;
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
  todos := coalesce((cfg->>'minutos_para_todos')::int, 10);
  select * into loc from public.localizacoes where user_id = auth.uid();
  if loc.user_id is null or loc.atualizado_em < now() - interval '10 minutes' then raise exception 'Libere sua localização para se candidatar'; end if;
  dist := round(public._dist_km(loc.lat, loc.lon, (s.retirada->>'la')::double precision, (s.retirada->>'lo')::double precision)::numeric, 1);
  if dist > rmax and s.criado_em > now() - make_interval(mins => todos) then raise exception 'Você está longe demais da retirada'; end if;
  if exists (select 1 from public.candidaturas where servico_id = p_id and prestador_id = auth.uid() and status = 'ativa') then return 'ja'; end if;
  select count(*) into n from public.candidaturas where servico_id = p_id and status = 'ativa';
  if n >= maxc then raise exception 'Este serviço já tem % candidatos', maxc; end if;
  insert into public.candidaturas (servico_id, prestador_id, distancia_km) values (p_id, auth.uid(), dist)
  on conflict (servico_id, prestador_id) do update set status = 'ativa', distancia_km = excluded.distancia_km, criado_em = now();
  return 'ok';
end $$;

create or replace function public.adm_motoboys()
returns table(user_id uuid, nome text, veiculo text, placa text, telefone text, lat double precision, lon double precision,
              atualizado_em timestamptz, situacao text, servico_numero bigint, servico_id uuid, rastreio_ver text, agora timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    with srv as (
      select distinct on (s.pego_por) s.pego_por, s.id, s.numero, s.status, s.rastreio_ver
      from public.servicos s where s.status in ('aceito','em_andamento') and s.pego_por is not null
      order by s.pego_por, (s.status = 'em_andamento') desc, s.atualizado_em desc
    ), pos as (
      select p.user_id, p.nome, p.veiculo, p.placa, p.telefone,
             case when r.atualizado_em is not null and r.atualizado_em > coalesce(l.atualizado_em,'-infinity') then r.lat else l.lat end as lat,
             case when r.atualizado_em is not null and r.atualizado_em > coalesce(l.atualizado_em,'-infinity') then r.lon else l.lon end as lon,
             greatest(l.atualizado_em, r.atualizado_em) as quando,
             srv.status as sst, srv.numero, srv.id as sid, srv.rastreio_ver
      from public.perfis p
      join public.membros m on m.user_id = p.user_id and m.ativo and m.removido_em is null
      left join public.localizacoes l on l.user_id = p.user_id
      left join srv on srv.pego_por = p.user_id
      left join public.rastreios r on r.token_ver = srv.rastreio_ver
      where p.recebe and p.status = 'aprovado' and (p.disponivel or srv.status is not null)
    )
    select pos.user_id, pos.nome, pos.veiculo, pos.placa, pos.telefone, pos.lat, pos.lon, pos.quando,
           case when pos.sst = 'em_andamento' then 'em_servico' when pos.sst = 'aceito' then 'escolhido' else 'livre' end,
           pos.numero, pos.sid, pos.rastreio_ver, now()
    from pos
    where pos.lat is not null and (pos.quando > now() - interval '15 minutes' or pos.sst is not null)
    order by 9 desc, pos.nome;
end $$;
