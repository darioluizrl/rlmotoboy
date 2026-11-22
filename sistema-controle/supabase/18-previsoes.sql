-- 18: previsão de retirada e de entrega (para empresa, motoboy/motorista, administração e o link público de rastreio)
-- Posição: rastreio ao vivo (em andamento) ou última localização do motoboy (Disponível). Velocidade média por veículo na cidade.
create or replace function public._previsao(s public.servicos) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  vel numeric := case s.veiculo when 'moto' then 28 when 'carro' then 22 when 'utilitario' then 20 else 18 end; -- km/h
  fat numeric := 1.35;              -- ruas x linha reta
  pts jsonb := jsonb_build_array(s.retirada) || coalesce(s.paradas,'[]'::jsonb);
  n int := jsonb_array_length(coalesce(s.paradas,'[]'::jsonb));
  legs numeric[] := '{}'; tot numeric := 0; d numeric; i int;
  plat double precision; plon double precision; pts_em timestamptz; gps boolean := false;
  t timestamptz; t_ret timestamptz; ret_real timestamptz := nullif(s.retirada->>'feito_em','')::timestamptz;
  ents jsonb := '[]'; prox int := null; agora timestamptz := now(); r jsonb;
begin
  -- tempo de cada trecho (rota do pedido quando houver; senão estimativa pela distância)
  for i in 1..n loop
    d := public._dist_km((pts->(i-1)->>'la')::float8,(pts->(i-1)->>'lo')::float8,(pts->i->>'la')::float8,(pts->i->>'lo')::float8);
    legs := legs || d; tot := tot + d;
  end loop;
  for i in 1..n loop
    legs[i] := case when coalesce(s.minutos,0) > 0 and tot > 0 then s.minutos * legs[i] / tot else legs[i] * fat / vel * 60 end;
  end loop;
  -- posição de quem pegou
  if s.status = 'em_andamento' and s.rastreio_ver is not null then
    select lat, lon, atualizado_em into plat, plon, pts_em from public.rastreios where token_ver = s.rastreio_ver and atualizado_em > agora - interval '10 minutes';
  end if;
  if plat is null and s.pego_por is not null and s.status in ('aceito','em_andamento') then
    select lat, lon, atualizado_em into plat, plon, pts_em from public.localizacoes where user_id = s.pego_por and atualizado_em > agora - interval '30 minutes';
  end if;
  gps := plat is not null;

  if s.status = 'concluido' then
    t_ret := ret_real;
  elsif s.status in ('aceito','em_andamento') and ret_real is null then
    t_ret := agora + make_interval(mins => case when gps then
               (public._dist_km(plat,plon,(s.retirada->>'la')::float8,(s.retirada->>'lo')::float8) * fat / vel * 60 + 3)::int else 20 end);
    if s.agendado_para is not null and s.agendado_para > t_ret then t_ret := s.agendado_para; end if;
  elsif s.status = 'aberto' then
    t_ret := s.agendado_para;  -- sem motoboy ainda: só tem horário se for agendado
  else
    t_ret := ret_real;
  end if;

  -- entregas
  t := case when ret_real is not null then ret_real else t_ret + interval '5 minutes' end;
  for i in 1..n loop
    if nullif(pts->i->>'feito_em','') is not null then
      ents := ents || jsonb_build_object('e', pts->i->>'e', 'real', pts->i->>'feito_em');
      t := (pts->i->>'feito_em')::timestamptz + interval '3 minutes';
    else
      if prox is null then prox := i; end if;
      if s.status in ('cancelado','concluido') or t is null then
        ents := ents || jsonb_build_object('e', pts->i->>'e', 'prev', null);
      else
        if i = prox and ret_real is not null and gps then
          t := greatest(t, agora) + make_interval(mins => (public._dist_km(plat,plon,(pts->i->>'la')::float8,(pts->i->>'lo')::float8) * fat / vel * 60 + 2)::int);
        else
          t := greatest(t, case when ret_real is not null then agora else t end) + make_interval(mins => ceil(legs[i])::int);
        end if;
        ents := ents || jsonb_build_object('e', pts->i->>'e', 'prev', t);
        t := t + interval '4 minutes';
      end if;
    end if;
  end loop;

  r := jsonb_build_object('status', s.status, 'agora', agora, 'gps', gps, 'gps_em', pts_em,
        'retirada', jsonb_build_object('e', s.retirada->>'e', 'prev', case when ret_real is null then t_ret end, 'real', ret_real),
        'entregas', ents, 'minutos_rota', round(coalesce(nullif(s.minutos,0), tot*fat/vel*60)));
  return r;
end $$;
revoke all on function public._previsao(public.servicos) from public, anon, authenticated;

create or replace function public.servico_previsao(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where id = p_id;
  if s.id is null or not (s.criado_por = auth.uid() or s.pego_por = auth.uid() or public.is_admin()) then raise exception 'Serviço não encontrado'; end if;
  return public._previsao(s);
end $$;

-- várias de uma vez (listas)
create or replace function public.servicos_previsoes(p_ids uuid[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(s.id, public._previsao(s)), '{}'::jsonb)
  from public.servicos s
  where s.id = any(p_ids[1:60]) and (s.criado_por = auth.uid() or s.pego_por = auth.uid() or public.is_admin());
$$;

-- link público de rastreio de um serviço MegaEntregas (código de acompanhamento)
create or replace function public.servico_previsao_publica(p_ver text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.servicos;
begin
  if p_ver !~ '^[a-f0-9]{32}$' then return null; end if;
  select * into s from public.servicos where rastreio_ver = p_ver;
  if s.id is null then return null; end if;
  return public._previsao(s) || jsonb_build_object('numero', s.numero, 'veiculo', s.veiculo);
end $$;

revoke all on function public.servico_previsao(uuid), public.servicos_previsoes(uuid[]), public.servico_previsao_publica(text) from public;
grant execute on function public.servico_previsao(uuid), public.servicos_previsoes(uuid[]) to authenticated;
grant execute on function public.servico_previsao_publica(text) to anon, authenticated;
