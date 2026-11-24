-- 19: forma de pagamento do serviço: PIX ou dinheiro (por enquanto só essas duas)
alter table public.servicos add column if not exists forma_pag text not null default 'pix' check (forma_pag in ('pix','dinheiro'));

do $$
declare d text;
begin
  d := pg_get_functiondef('public.servico_soltar'::regproc);
  if position('forma_pag' in d) = 0 then
    d := replace(d, 'agendado_para, obs)', 'agendado_para, obs, forma_pag)');
    d := replace(d, 'ag, nullif(trim(p->>''obs''),''''))', 'ag, nullif(trim(p->>''obs''),''''), case when p->>''forma_pag'' = ''dinheiro'' then ''dinheiro'' else ''pix'' end)');
    d := replace(d, '  ag := nullif(', E'  if coalesce(p->>''forma_pag'',''pix'') not in (''pix'',''dinheiro'') then raise exception ''Forma de pagamento inválida (PIX ou dinheiro)''; end if;\n  ag := nullif(');
    execute d;
  end if;
  d := pg_get_functiondef('public.servico_paguei'::regproc);
  if position('forma_pag' in d) = 0 then
    d := replace(d, 'case when p_comprovante is not null then', 'case when s.forma_pag = ''dinheiro'' then ''💵 Pagamento feito em dinheiro. Confira e toque em "Recebi o pagamento".'' when p_comprovante is not null then');
    execute d;
  end if;
  d := pg_get_functiondef('public.servico_pix(uuid)'::regprocedure);
  if position('forma_pag' in d) = 0 then
    d := replace(d, '''comprovante'', s.pag_comprovante)', '''comprovante'', s.pag_comprovante, ''forma_pag'', s.forma_pag)');
    execute d;
  end if;
end $$;

drop function if exists public.servicos_proximos(double precision, double precision);
create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, criado_em timestamptz, distancia_km numeric, candidatos int, max_candidatos int, eu_candidato boolean,
              valor_inicial numeric, aumentado_em timestamptz, forma_pag text)
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); cfg jsonb; r0 numeric; rmax numeric; amp int; todos int; maxc int;
begin
  if public._baixas_pendentes(auth.uid()) > 0 then raise exception 'Você tem serviço concluído há mais de 48 horas sem baixa do pagamento. Toque em "Recebi o pagamento" ou "Não recebi" para voltar a receber serviços.'; end if;
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
    select q.id, q.numero, q.retirada, q.paradas, q.km, q.minutos, q.veiculo, q.valor, q.agendado_para, q.obs, q.criado_em, q.dist, q.ncand, q.maxc, q.eu, q.valor_inicial, q.aumentado_em, q.forma_pag
    from (
      select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.criado_em, s.valor_inicial, s.aumentado_em, s.forma_pag,
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
    order by q.eu desc, (q.aumentado_em > now() - interval '10 minutes') desc nulls last, q.dist asc, q.criado_em asc
    limit 50;
end $$;
revoke all on function public.servicos_proximos(double precision, double precision) from public, anon;
grant execute on function public.servicos_proximos(double precision, double precision) to authenticated;

drop function if exists public.meus_trabalhos();
create or replace function public.meus_trabalhos()
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos integer, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, status text, minha text, criado_em timestamptz, quem_enviou text,
              espera_min integer, espera_valor numeric, iniciado_em timestamptz, concluido_em timestamptz,
              pago_em timestamptz, recebido_em timestamptz, pag_comprovante text, nao_recebi_em timestamptz, forma_pag text)
language sql stable security definer set search_path = public as $$
  select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.status,
         c.status, s.criado_em, case when s.pego_por = auth.uid() then p.nome end,
         s.espera_min, s.espera_valor, s.iniciado_em, s.concluido_em,
         case when s.pego_por = auth.uid() then s.pago_em end, case when s.pego_por = auth.uid() then s.recebido_em end,
         case when s.pego_por = auth.uid() then s.pag_comprovante end, case when s.pego_por = auth.uid() then s.nao_recebi_em end, s.forma_pag
  from public.candidaturas c join public.servicos s on s.id = c.servico_id join public.perfis p on p.user_id = s.criado_por
  where c.prestador_id = auth.uid()
    and (c.criado_em > now() - interval '30 days' or (c.status = 'escolhida' and s.status = 'concluido' and s.recebido_em is null))
    and (c.status = 'ativa' or (c.status = 'escolhida' and s.status in ('aceito','em_andamento','concluido')) or c.status = 'recusada')
  order by (c.status = 'escolhida' and s.status = 'concluido' and s.recebido_em is null) desc,
           (c.status = 'escolhida' and s.status in ('aceito','em_andamento')) desc, c.criado_em desc
  limit 30;
$$;

drop function if exists public.adm_servicos(integer);
create or replace function public.adm_servicos(p_dias integer default 7)
returns table(id uuid, numero bigint, status text, retirada jsonb, paradas jsonb, km numeric, veiculo text, valor numeric,
              agendado_para timestamptz, criado_em timestamptz, quem_enviou text, quem_pegou text, candidatos integer, mensagens integer,
              espera_min integer, espera_valor numeric, rastreio_ver text, iniciado_em timestamptz, concluido_em timestamptz,
              pago_em timestamptz, recebido_em timestamptz, pag_comprovante text, nao_recebi_em timestamptz, nao_recebi_obs text, forma_pag text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select s.id, s.numero, s.status, s.retirada, s.paradas, s.km, s.veiculo, s.valor, s.agendado_para, s.criado_em,
           pe.nome, pp.nome,
           (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status in ('ativa','escolhida')),
           (select count(*)::int from public.mensagens m where m.servico_id = s.id),
           s.espera_min, s.espera_valor, s.rastreio_ver, s.iniciado_em, s.concluido_em, s.pago_em, s.recebido_em, s.pag_comprovante,
           s.nao_recebi_em, s.nao_recebi_obs, s.forma_pag
    from public.servicos s left join public.perfis pe on pe.user_id = s.criado_por left join public.perfis pp on pp.user_id = s.pego_por
    where s.criado_em > now() - make_interval(days => greatest(1, least(coalesce(p_dias,7), 90)))
       or (s.status = 'concluido' and s.recebido_em is null)
    order by s.criado_em desc limit 300;
end $$;

revoke all on function public.meus_trabalhos(), public.adm_servicos(integer) from public, anon;
grant execute on function public.meus_trabalhos(), public.adm_servicos(integer) to authenticated;
