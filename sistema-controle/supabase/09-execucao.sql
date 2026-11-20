-- Passo 5 da Central RL: execução do serviço
-- • Quem pegou toca "Iniciar": o serviço fica em andamento e o rastreio ao vivo é criado.
-- • Em cada ponto: "Cheguei" (começa a contar a espera) e depois
--     retirada  → nome de quem entregou a carga
--     entrega   → nome e RG de quem recebeu
-- • Espera: os primeiros N minutos em cada ponto são grátis; depois cobra R$ X/min (config_sistema.espera),
--   somado ao repasse do motoboy.
-- • Na última entrega o serviço fica concluído e o rastreio é encerrado.

alter table public.servicos add column if not exists rastreio_ver  text;
alter table public.servicos add column if not exists iniciado_em   timestamptz;
alter table public.servicos add column if not exists concluido_em  timestamptz;
alter table public.servicos add column if not exists espera_min    int     not null default 0;
alter table public.servicos add column if not exists espera_valor  numeric not null default 0;

-- o código que deixa o celular do motoboy mandar posição fica separado (quem enviou não vê)
create table if not exists public.servico_tokens (
  servico_id uuid primary key references public.servicos(id) on delete cascade,
  token_moto text not null
);
alter table public.servico_tokens enable row level security;   -- sem políticas: só pelas funções

create or replace function public._srv_meu(p_id uuid) returns public.servicos
language plpgsql security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where id = p_id for update;
  if s.id is null or s.pego_por is distinct from auth.uid() then raise exception 'Serviço não encontrado'; end if;
  return s;
end $$;

create or replace function public._espera_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select c.valor from public.config_sistema c where c.chave = 'espera'), '{"minutos_gratis":15,"valor_minuto":0.5}'::jsonb);
$$;

-- minutos cobrados num ponto: (feito - chegou) - grátis, arredondando para cima
create or replace function public._espera_ponto(p jsonb, gratis int) returns int language sql immutable as $$
  select case when p->>'chegou_em' is null or p->>'feito_em' is null then 0
              else greatest(0, ceil(extract(epoch from ((p->>'feito_em')::timestamptz - (p->>'chegou_em')::timestamptz)) / 60.0)::int - gratis) end;
$$;

create or replace function public.servico_iniciar(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.servicos := public._srv_meu(p_id); moto text; ver text;
begin
  if s.status = 'em_andamento' then
    select token_moto into moto from public.servico_tokens where servico_id = p_id;
    return jsonb_build_object('moto', moto, 'ver', s.rastreio_ver);
  end if;
  if s.status <> 'aceito' then raise exception 'Este serviço não pode ser iniciado agora'; end if;
  moto := replace(gen_random_uuid()::text,'-',''); ver := replace(gen_random_uuid()::text,'-','');
  insert into public.rastreios (token_moto, token_ver, titulo, agendado, origem, destinos, km, status, iniciado_em)
  values (moto, ver, 'Serviço #' || s.numero,
          case when s.agendado_para is not null then to_char(s.agendado_para at time zone 'America/Sao_Paulo','DD/MM/YYYY "às" HH24:MI') end,
          s.retirada, s.paradas, s.km, 'aguardando', null);
  insert into public.servico_tokens (servico_id, token_moto) values (p_id, moto)
  on conflict (servico_id) do update set token_moto = excluded.token_moto;
  update public.servicos set status = 'em_andamento', iniciado_em = now(), rastreio_ver = ver, atualizado_em = now() where id = p_id;
  insert into public.mensagens (servico_id, autor, texto) values (p_id, auth.uid(), '▶ Serviço iniciado. Estou a caminho da retirada.');
  return jsonb_build_object('moto', moto, 'ver', ver);
end $$;

-- p_ponto: 0 = retirada, 1..N = entregas
create or replace function public.servico_chegou(p_id uuid, p_ponto int) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos := public._srv_meu(p_id); n int := jsonb_array_length(s.paradas);
begin
  if s.status <> 'em_andamento' then raise exception 'Inicie o serviço primeiro'; end if;
  if p_ponto < 0 or p_ponto > n then raise exception 'Ponto inválido'; end if;
  if p_ponto = 0 then
    if s.retirada->>'chegou_em' is null then
      update public.servicos set retirada = s.retirada || jsonb_build_object('chegou_em', now()), atualizado_em = now() where id = p_id;
    end if;
  else
    if s.retirada->>'feito_em' is null then raise exception 'Faça a retirada primeiro'; end if;
    if s.paradas->(p_ponto-1)->>'chegou_em' is null then
      update public.servicos set paradas = jsonb_set(s.paradas, array[(p_ponto-1)::text], (s.paradas->(p_ponto-1)) || jsonb_build_object('chegou_em', now())),
             atualizado_em = now() where id = p_id;
    end if;
  end if;
  return 'ok';
end $$;

create or replace function public.servico_retirada(p_id uuid, p_nome text) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos := public._srv_meu(p_id); nome text := btrim(coalesce(p_nome,'')); r jsonb; g int;
begin
  if s.status <> 'em_andamento' then raise exception 'Inicie o serviço primeiro'; end if;
  if s.retirada->>'feito_em' is not null then raise exception 'A retirada já foi registrada'; end if;
  if length(nome) < 2 or length(nome) > 80 then raise exception 'Digite o nome de quem entregou a carga'; end if;
  g := coalesce((public._espera_cfg()->>'minutos_gratis')::int, 15);
  r := s.retirada || jsonb_build_object('chegou_em', coalesce(s.retirada->>'chegou_em', now()::text), 'feito_em', now(), 'nome', nome);
  r := r || jsonb_build_object('espera_min', public._espera_ponto(r, g));
  update public.servicos set retirada = r, atualizado_em = now() where id = p_id;
  perform public._srv_totais(p_id);
  insert into public.mensagens (servico_id, autor, texto) values (p_id, auth.uid(), '📦 Carga retirada. Entregue por: ' || nome);
  return 'ok';
end $$;

create or replace function public.servico_entrega(p_id uuid, p_ponto int, p_nome text, p_rg text) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos := public._srv_meu(p_id); n int := jsonb_array_length(s.paradas);
        nome text := btrim(coalesce(p_nome,'')); rg text := upper(regexp_replace(coalesce(p_rg,''), '[^0-9A-Za-z]', '', 'g'));
        p jsonb; g int; feitas int; ult boolean;
begin
  if s.status <> 'em_andamento' then raise exception 'Inicie o serviço primeiro'; end if;
  if s.retirada->>'feito_em' is null then raise exception 'Faça a retirada primeiro'; end if;
  if p_ponto < 1 or p_ponto > n then raise exception 'Entrega inválida'; end if;
  if s.paradas->(p_ponto-1)->>'feito_em' is not null then raise exception 'Esta entrega já foi registrada'; end if;
  if length(nome) < 2 or length(nome) > 80 then raise exception 'Digite o nome de quem recebeu'; end if;
  if length(rg) not between 5 and 14 then raise exception 'Digite o RG de quem recebeu'; end if;
  g := coalesce((public._espera_cfg()->>'minutos_gratis')::int, 15);
  p := (s.paradas->(p_ponto-1)) || jsonb_build_object('chegou_em', coalesce(s.paradas->(p_ponto-1)->>'chegou_em', now()::text),
                                                     'feito_em', now(), 'nome', nome, 'rg', rg);
  p := p || jsonb_build_object('espera_min', public._espera_ponto(p, g));
  update public.servicos set paradas = jsonb_set(s.paradas, array[(p_ponto-1)::text], p), atualizado_em = now() where id = p_id;
  select count(*) into feitas from public.servicos x, jsonb_array_elements(x.paradas) e where x.id = p_id and e->>'feito_em' is not null;
  ult := feitas >= n;
  perform public._srv_totais(p_id);
  insert into public.mensagens (servico_id, autor, texto)
  values (p_id, auth.uid(), '✅ Entrega ' || p_ponto || ' feita. Recebido por: ' || nome || ' (RG final ' || right(rg,3) || ')');
  if ult then
    update public.servicos set status = 'concluido', concluido_em = now(), atualizado_em = now() where id = p_id;
    update public.rastreios set status = 'finalizado', finalizado_em = now()
    where token_ver = (select rastreio_ver from public.servicos where id = p_id);
    insert into public.mensagens (servico_id, autor, texto) values (p_id, auth.uid(), '🏁 Serviço concluído.');
  end if;
  return case when ult then 'concluido' else 'ok' end;
end $$;

create or replace function public._srv_totais(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare s public.servicos; m int; vm numeric;
begin
  select * into s from public.servicos where id = p_id;
  select coalesce((s.retirada->>'espera_min')::int,0) + coalesce(sum((e->>'espera_min')::int),0) into m
  from jsonb_array_elements(s.paradas) e;
  vm := coalesce((public._espera_cfg()->>'valor_minuto')::numeric, 0.5);
  update public.servicos set espera_min = m, espera_valor = round(m * vm, 2) where id = p_id;
end $$;

-- celular de quem pegou: código para mandar a posição enquanto o serviço está em andamento
create or replace function public.servico_meu_rastreio(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.servicos; moto text;
begin
  select * into s from public.servicos where id = p_id;
  if s.id is null or s.pego_por is distinct from auth.uid() or s.status <> 'em_andamento' then return null; end if;
  select token_moto into moto from public.servico_tokens where servico_id = p_id;
  return jsonb_build_object('moto', moto, 'ver', s.rastreio_ver);
end $$;

-- quem recebe: lista de trabalhos agora traz os pontos e a espera
drop function if exists public.meus_trabalhos();
create or replace function public.meus_trabalhos()
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos int, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, status text, minha text, criado_em timestamptz, quem_enviou text,
              espera_min int, espera_valor numeric, iniciado_em timestamptz, concluido_em timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.status,
         c.status, s.criado_em, case when s.pego_por = auth.uid() then p.nome end,
         s.espera_min, s.espera_valor, s.iniciado_em, s.concluido_em
  from public.candidaturas c join public.servicos s on s.id = c.servico_id join public.perfis p on p.user_id = s.criado_por
  where c.prestador_id = auth.uid() and c.criado_em > now() - interval '30 days'
    and (c.status = 'ativa' or (c.status = 'escolhida' and s.status in ('aceito','em_andamento','concluido')) or c.status = 'recusada')
  order by (c.status = 'escolhida' and s.status in ('aceito','em_andamento')) desc, c.criado_em desc
  limit 30;
$$;

drop function if exists public.adm_servicos(int);
create or replace function public.adm_servicos(p_dias int default 7)
returns table(id uuid, numero bigint, status text, retirada jsonb, paradas jsonb, km numeric, veiculo text, valor numeric,
              agendado_para timestamptz, criado_em timestamptz, quem_enviou text, quem_pegou text, candidatos int, mensagens int,
              espera_min int, espera_valor numeric, rastreio_ver text, iniciado_em timestamptz, concluido_em timestamptz)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select s.id, s.numero, s.status, s.retirada, s.paradas, s.km, s.veiculo, s.valor, s.agendado_para, s.criado_em,
           pe.nome, pp.nome,
           (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status in ('ativa','escolhida')),
           (select count(*)::int from public.mensagens m where m.servico_id = s.id),
           s.espera_min, s.espera_valor, s.rastreio_ver, s.iniciado_em, s.concluido_em
    from public.servicos s left join public.perfis pe on pe.user_id = s.criado_por left join public.perfis pp on pp.user_id = s.pego_por
    where s.criado_em > now() - make_interval(days => greatest(1, least(coalesce(p_dias,7), 90)))
    order by s.criado_em desc limit 300;
end $$;

revoke all on function public.servico_iniciar(uuid), public.servico_chegou(uuid,int), public.servico_retirada(uuid,text),
  public.servico_entrega(uuid,int,text,text), public.servico_meu_rastreio(uuid), public.meus_trabalhos(), public.adm_servicos(int),
  public._srv_meu(uuid), public._srv_totais(uuid) from public, anon;
grant execute on function public.servico_iniciar(uuid), public.servico_chegou(uuid,int), public.servico_retirada(uuid,text),
  public.servico_entrega(uuid,int,text,text), public.servico_meu_rastreio(uuid), public.meus_trabalhos(), public.adm_servicos(int)
  to authenticated;
