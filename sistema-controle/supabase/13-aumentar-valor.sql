-- 13: quem enviou pode AUMENTAR o valor de um serviço aberto; ele é reenviado
-- (sobe para o topo da lista dos motoboys, com o aviso "valor aumentado").
-- O alcance não diminui: continua contando do momento em que foi solto.
alter table public.servicos add column if not exists valor_inicial numeric;
alter table public.servicos add column if not exists aumentado_em timestamptz;
alter table public.servicos add column if not exists aumentos int not null default 0;

create or replace function public.servico_aumentar(p_id uuid, p_valor numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where id = p_id for update;
  if s.id is null or s.criado_por <> auth.uid() then raise exception 'Serviço não encontrado'; end if;
  if s.status <> 'aberto' then raise exception 'Só dá para aumentar o valor de um serviço que ainda está aberto'; end if;
  p_valor := round(p_valor, 2);
  if p_valor is null or p_valor <= s.valor then raise exception 'O novo valor precisa ser maior que o atual'; end if;
  if p_valor > 50000 then raise exception 'Valor muito alto'; end if;
  if s.aumentos >= 20 then raise exception 'Limite de aumentos para este serviço'; end if;
  update public.servicos set valor = p_valor, valor_inicial = coalesce(s.valor_inicial, s.valor),
         aumentado_em = now(), aumentos = s.aumentos + 1, atualizado_em = now()
  where id = p_id;
  return p_valor;
end $$;
revoke all on function public.servico_aumentar(uuid, numeric) from public, anon;
grant execute on function public.servico_aumentar(uuid, numeric) to authenticated;

drop function if exists public.servicos_proximos(double precision, double precision);
create or replace function public.servicos_proximos(p_lat double precision, p_lon double precision)
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, criado_em timestamptz, distancia_km numeric, candidatos int, max_candidatos int, eu_candidato boolean,
              valor_inicial numeric, aumentado_em timestamptz)
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
    select q.id, q.numero, q.retirada, q.paradas, q.km, q.minutos, q.veiculo, q.valor, q.agendado_para, q.obs, q.criado_em, q.dist, q.ncand, q.maxc, q.eu, q.valor_inicial, q.aumentado_em
    from (
      select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.criado_em, s.valor_inicial, s.aumentado_em,
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
