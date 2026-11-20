-- Distribuição em 3 fases (tempo contado desde que o serviço foi solto):
--   0 até "minutos_ate_ampliar"            → só quem está até "raio_inicial_km" da retirada
--   depois, até "minutos_para_todos"        → até "raio_maximo_km"
--   depois de "minutos_para_todos" sem ninguém escolhido → TODOS (qualquer distância), mesmo veículo
update public.config_sistema set valor = valor || '{"minutos_para_todos":10}'::jsonb
where chave = 'distribuicao' and not (valor ? 'minutos_para_todos');



create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, criado_em timestamptz, distancia_km numeric, candidatos int, max_candidatos int, eu_candidato boolean)
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); cfg jsonb; r0 numeric; rmax numeric; amp int; todos int; maxc int;
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
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
       or coalesce((p_valor->>'minutos_para_todos')::int, 10) not between 1 and 240
       or coalesce((p_valor->>'minutos_para_todos')::int, 10) < (p_valor->>'minutos_ate_ampliar')::int
       or (p_valor->>'max_candidatos')::int not between 1 and 20 then
      raise exception 'Valores de distribuição inválidos'; end if;
    v := jsonb_build_object('raio_inicial_km',(p_valor->>'raio_inicial_km')::numeric,'minutos_ate_ampliar',(p_valor->>'minutos_ate_ampliar')::int,
                            'raio_maximo_km',(p_valor->>'raio_maximo_km')::numeric,'minutos_para_todos',coalesce((p_valor->>'minutos_para_todos')::int,10),
                            'max_candidatos',(p_valor->>'max_candidatos')::int);
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
