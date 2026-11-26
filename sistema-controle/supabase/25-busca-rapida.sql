-- 25: busca de serviços próximos mais rápida (mesmas regras, distância calculada uma vez por serviço,
--     veículos permitidos calculados uma vez por chamada, nome de quem envia só para os 50 do resultado)
create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
 returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos integer, veiculo text, valor numeric, agendado_para timestamp with time zone, obs text, criado_em timestamp with time zone, distancia_km numeric, candidatos integer, max_candidatos integer, eu_candidato boolean, valor_inicial numeric, aumentado_em timestamp with time zone, forma_pag text, quem_envia text)
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare me public.perfis := public._perfil_ativo(); cfg jsonb; r0 numeric; rmax numeric; amp int; todos int; maxc int;
        uid uuid := auth.uid(); v_ok text[]; t_amp timestamptz; t_todos timestamptz; cl double precision := cos(radians(p_lat));
begin
  if public._baixas_pendentes(uid) > 0 then raise exception 'Você tem serviço concluído há mais de 48 horas sem baixa do pagamento. Toque em "Recebi o pagamento" ou "Não recebi" para voltar a receber serviços.'; end if;
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não está marcado para receber serviços'; end if;
  if not me.disponivel then raise exception 'Ligue o botão Disponível para receber serviços'; end if;
  if p_lat is null or p_lon is null or p_lat not between -34 and 6 or p_lon not between -75 and -28 then raise exception 'Localização inválida'; end if;
  insert into public.localizacoes (user_id, lat, lon, atualizado_em) values (uid, p_lat, p_lon, now())
  on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, atualizado_em = now();
  select c.valor into cfg from public.config_sistema c where c.chave = 'distribuicao';
  r0 := coalesce((cfg->>'raio_inicial_km')::numeric, 3); rmax := coalesce((cfg->>'raio_maximo_km')::numeric, 10);
  amp := coalesce((cfg->>'minutos_ate_ampliar')::int, 5); todos := coalesce((cfg->>'minutos_para_todos')::int, 10);
  maxc := coalesce((cfg->>'max_candidatos')::int, 3);
  t_amp := now() - make_interval(mins => amp); t_todos := now() - make_interval(mins => todos);
  -- tipos de serviço que este motoboy pode e quer pegar (calculado uma vez)
  v_ok := array(select v from unnest(array['moto','carro','utilitario','caminhao']) v
                where public._quer_veic(me, v)
                  and case v when 'moto' then me.veiculo = 'moto'
                             when 'carro' then me.veiculo in ('carro','utilitario')
                             when 'utilitario' then me.veiculo in ('utilitario','caminhao')
                             else me.veiculo = 'caminhao' end);
  return query
    select q.id, q.numero, q.retirada, q.paradas, q.km, q.minutos, q.veiculo, q.valor, q.agendado_para, q.obs, q.criado_em,
           round(q.d::numeric, 1), q.ncand, maxc, q.eu, q.valor_inicial, q.aumentado_em, q.forma_pag,
           (select coalesce(nullif(pe.marca_nome,''), pe.nome) from public.perfis pe where pe.user_id = q.criado_por)
    from (
      select s.*, dd.d,
             (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status = 'ativa') as ncand,
             exists (select 1 from public.candidaturas c where c.servico_id = s.id and c.prestador_id = uid and c.status = 'ativa') as eu
      from public.servicos s
      cross join lateral (select 12742 * asin(sqrt(
               power(sin(radians((s.retirada->>'la')::double precision - p_lat) / 2), 2)
             + cl * cos(radians((s.retirada->>'la')::double precision))
               * power(sin(radians((s.retirada->>'lo')::double precision - p_lon) / 2), 2))) as d) dd
      where s.status = 'aberto' and s.criado_por <> uid and s.veiculo = any(v_ok)
        and (s.agendado_para is null or s.agendado_para > now() - interval '30 minutes')
        and (dd.d <= r0 or (s.criado_em <= t_amp and dd.d <= rmax) or s.criado_em <= t_todos)
    ) q
    where q.eu or q.ncand < maxc
    order by q.eu desc, (q.aumentado_em > now() - interval '10 minutes') desc nulls last, round(q.d::numeric, 1) asc, q.criado_em asc
    limit 50;
end $function$;
