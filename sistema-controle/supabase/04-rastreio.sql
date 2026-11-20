-- Rastreio de corridas por link (motoboy libera; RL e cliente acompanham)
-- Os links levam códigos secretos aleatórios gerados pelo sistema da RL:
--   m = código do motoboy (pode enviar posição e finalizar)   v = código de acompanhamento (só ver)
-- Ninguém lê a tabela diretamente: tudo passa pelas funções abaixo. Guarda só a última posição.

create table if not exists public.rastreios (
  token_moto    text primary key check (token_moto ~ '^[a-f0-9]{32}$'),
  token_ver     text not null unique check (token_ver ~ '^[a-f0-9]{32}$'),
  titulo        text,
  agendado      text,
  origem        jsonb,
  destinos      jsonb,
  km            numeric,
  status        text not null default 'aguardando' check (status in ('aguardando','em_rota','finalizado')),
  lat           double precision,
  lon           double precision,
  precisao      double precision,
  atualizado_em timestamptz,
  iniciado_em   timestamptz,
  finalizado_em timestamptz,
  criado_em     timestamptz not null default now()
);
alter table public.rastreios enable row level security;
-- sem políticas: acesso direto bloqueado para todos (só as funções security definer abaixo)

-- motoboy abre o link pela 1ª vez: cria o rastreio com os dados da O.S. (se ainda não existir)
create or replace function public.rastreio_abrir(p_moto text, p_ver text, p_dados jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.rastreios; d jsonb := coalesce(p_dados,'{}'::jsonb);
begin
  if p_moto !~ '^[a-f0-9]{32}$' or p_ver !~ '^[a-f0-9]{32}$' or p_moto = p_ver then raise exception 'Link inválido'; end if;
  select * into r from public.rastreios where token_moto = p_moto;
  if r.token_moto is null then
    if exists (select 1 from public.rastreios where token_ver = p_ver) then raise exception 'Link inválido'; end if;
    if (select count(*) from public.rastreios where criado_em > now() - interval '1 hour') >= 300 then raise exception 'Muitos rastreios agora, tente em instantes'; end if;
    if octet_length(d::text) > 20000 or jsonb_typeof(coalesce(d->'d','[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(d->'d','[]'::jsonb)) > 30 then raise exception 'Dados inválidos'; end if;
    delete from public.rastreios where criado_em < now() - interval '7 days';
    insert into public.rastreios (token_moto, token_ver, titulo, agendado, origem, destinos, km)
    values (p_moto, p_ver, left(d->>'t',80), left(d->>'a',60), d->'o', coalesce(d->'d','[]'::jsonb),
            case when (d->>'km') ~ '^[0-9]+(\.[0-9]+)?$' then (d->>'km')::numeric end)
    returning * into r;
  elsif r.token_ver <> p_ver then raise exception 'Link inválido';
  end if;
  return jsonb_build_object('titulo',r.titulo,'agendado',r.agendado,'origem',r.origem,'destinos',r.destinos,'km',r.km,
    'status',r.status,'iniciado_em',r.iniciado_em,'finalizado_em',r.finalizado_em);
end $$;

-- motoboy envia a posição (no máximo a cada 8 s; só até finalizar e por até 24 h depois de iniciar)
create or replace function public.rastreio_posicao(p_moto text, p_lat double precision, p_lon double precision, p_prec double precision default null)
returns text language plpgsql security definer set search_path = public as $$
declare r public.rastreios;
begin
  select * into r from public.rastreios where token_moto = p_moto for update;
  if r.token_moto is null then raise exception 'Link inválido'; end if;
  if r.status = 'finalizado' then return 'finalizado'; end if;
  if r.iniciado_em is not null and r.iniciado_em < now() - interval '24 hours' then return 'expirado'; end if;
  if p_lat is null or p_lon is null or p_lat not between -34 and 6 or p_lon not between -75 and -28 then raise exception 'Posição inválida'; end if;
  if r.atualizado_em is not null and r.atualizado_em > now() - interval '4 seconds' then return 'ok'; end if;
  update public.rastreios set lat = p_lat, lon = p_lon, precisao = p_prec, atualizado_em = now(),
    status = 'em_rota', iniciado_em = coalesce(iniciado_em, now())
  where token_moto = p_moto;
  return 'ok';
end $$;

-- motoboy finaliza (para o rastreio)
create or replace function public.rastreio_finalizar(p_moto text)
returns text language plpgsql security definer set search_path = public as $$
begin
  update public.rastreios set status = 'finalizado', finalizado_em = now() where token_moto = p_moto and status <> 'finalizado';
  if not found and not exists (select 1 from public.rastreios where token_moto = p_moto) then raise exception 'Link inválido'; end if;
  return 'finalizado';
end $$;

-- RL / cliente acompanham (só leitura, com o código de acompanhamento)
create or replace function public.rastreio_ver(p_ver text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('titulo',titulo,'agendado',agendado,'origem',origem,'destinos',destinos,'km',km,'status',status,
    'lat',lat,'lon',lon,'precisao',precisao,'atualizado_em',atualizado_em,'iniciado_em',iniciado_em,'finalizado_em',finalizado_em,'agora',now())
  from public.rastreios where token_ver = p_ver and p_ver ~ '^[a-f0-9]{32}$';
$$;

revoke all on function public.rastreio_abrir(text,text,jsonb), public.rastreio_posicao(text,double precision,double precision,double precision),
  public.rastreio_finalizar(text), public.rastreio_ver(text) from public;
grant execute on function public.rastreio_abrir(text,text,jsonb), public.rastreio_posicao(text,double precision,double precision,double precision),
  public.rastreio_finalizar(text), public.rastreio_ver(text) to anon, authenticated;

-- painel Operacional: vários rastreios de uma vez (só os códigos de acompanhamento informados; até 150)
create or replace function public.rastreio_varios(p_vers text[])
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('v',token_ver,'titulo',titulo,'agendado',agendado,'origem',origem,'destinos',destinos,'km',km,'status',status,
    'lat',lat,'lon',lon,'atualizado_em',atualizado_em,'iniciado_em',iniciado_em,'finalizado_em',finalizado_em,'agora',now())), '[]'::jsonb)
  from public.rastreios
  where token_ver in (select unnest(p_vers[1:150]))
    and token_ver ~ '^[a-f0-9]{32}$';
$$;
revoke all on function public.rastreio_varios(text[]) from public;
grant execute on function public.rastreio_varios(text[]) to anon, authenticated;
