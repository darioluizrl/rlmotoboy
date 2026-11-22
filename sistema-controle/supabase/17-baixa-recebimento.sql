-- 17: regra corrigida — quem fica bloqueado é o MOTOBOY/MOTORISTA que não dá baixa no recebimento em 48h
--     (não recebe serviços novos). Se não recebeu, toca "Não recebi": sai do bloqueio e gera alerta para os admins.
alter table public.servicos add column if not exists nao_recebi_em  timestamptz;
alter table public.servicos add column if not exists nao_recebi_obs text check (length(nao_recebi_obs) <= 500);

-- tira o bloqueio da empresa (versão anterior)
do $$
declare d text;
begin
  d := pg_get_functiondef('public.servico_soltar'::regproc);
  d := regexp_replace(d, E'\n  if public._pag_atrasados\\(auth.uid\\(\\)\\) > 0 then raise exception [^\n]*\n', E'\n');
  execute d;
end $$;
drop function if exists public.meus_pagamentos_atrasados();
drop function if exists public._pag_atrasados(uuid);

-- baixas pendentes do motoboy: concluído há mais de 48h, sem "recebi" e sem "não recebi"
create or replace function public._baixas_pendentes(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.servicos
  where pego_por = p_user and status = 'concluido' and recebido_em is null and nao_recebi_em is null
    and concluido_em < now() - interval '48 hours';
$$;
create or replace function public.minhas_baixas_pendentes() returns int
language sql stable security definer set search_path = public as $$ select public._baixas_pendentes(auth.uid()); $$;

do $$
declare d text; chk text := E'\n  if public._baixas_pendentes(auth.uid()) > 0 then raise exception ''Você tem serviço concluído há mais de 48 horas sem baixa do pagamento. Toque em "Recebi o pagamento" ou "Não recebi" para voltar a receber serviços.''; end if;\n';
begin
  d := pg_get_functiondef('public.servicos_proximos'::regproc);
  if position('_baixas_pendentes' in d) = 0 then execute regexp_replace(d, E'\nbegin\n', E'\nbegin' || chk); end if;
  d := pg_get_functiondef('public.servico_candidatar'::regproc);
  if position('_baixas_pendentes' in d) = 0 then execute regexp_replace(d, E'\nbegin\n', E'\nbegin' || chk); end if;
  d := pg_get_functiondef('public.minha_disponibilidade'::regproc);
  if position('_baixas_pendentes' in d) = 0 then
    execute regexp_replace(d, E'\nbegin\n', E'\nbegin\n  if p_ligar and public._baixas_pendentes(auth.uid()) > 0 then raise exception ''Você tem serviço concluído há mais de 48 horas sem baixa do pagamento. Toque em "Recebi o pagamento" ou "Não recebi" para voltar a receber serviços.''; end if;\n');
  end if;
end $$;

-- "recebi" também encerra um aviso de "não recebi"
create or replace function public.servico_recebi(p_id uuid) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos; adm boolean := false;
begin
  select * into s from public.servicos where id = p_id for update;
  if s.id is null then raise exception 'Serviço não encontrado'; end if;
  if s.pego_por is distinct from auth.uid() then
    if public.is_admin() then adm := true; else raise exception 'Serviço não encontrado'; end if;
  end if;
  if s.status <> 'concluido' then raise exception 'O serviço ainda não foi concluído'; end if;
  if s.recebido_em is not null then return 'ok'; end if;
  update public.servicos set recebido_em = now(), recebido_por_admin = case when adm then auth.uid() end, atualizado_em = now() where id = p_id;
  insert into public.mensagens (servico_id, autor, texto)
  values (p_id, auth.uid(), case when adm then '✅ Pagamento confirmado pela administração MegaEntregas.' else '✅ Recebi o pagamento. Obrigado!' end);
  return 'ok';
end $$;

-- motoboy avisa que NÃO recebeu → alerta para os admins
create or replace function public.servico_nao_recebi(p_id uuid, p_obs text) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where id = p_id for update;
  if s.id is null or s.pego_por is distinct from auth.uid() then raise exception 'Serviço não encontrado'; end if;
  if s.status <> 'concluido' then raise exception 'O serviço ainda não foi concluído'; end if;
  if s.recebido_em is not null then raise exception 'Você já confirmou o recebimento deste serviço'; end if;
  update public.servicos set nao_recebi_em = now(), nao_recebi_obs = nullif(left(trim(coalesce(p_obs,'')),500),''), atualizado_em = now() where id = p_id;
  insert into public.mensagens (servico_id, autor, texto)
  values (p_id, auth.uid(), '⚠️ Avisei que NÃO recebi o pagamento' || coalesce(': ' || nullif(trim(p_obs),''), '') || '. A administração MegaEntregas vai verificar.');
  return 'ok';
end $$;

-- alertas para a administração: "não recebi" em aberto e baixas atrasadas
create or replace function public.adm_alertas_pagamento()
returns table(id uuid, numero bigint, tipo text, quem_enviou text, quem_pegou text, tel_enviou text, tel_pegou text,
              valor numeric, concluido_em timestamptz, pago_em timestamptz, pag_comprovante text, nao_recebi_em timestamptz, nao_recebi_obs text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select s.id, s.numero, case when s.nao_recebi_em is not null then 'nao_recebi' else 'sem_baixa' end,
           pe.nome, pp.nome, pe.telefone, pp.telefone, s.valor + coalesce(s.espera_valor,0), s.concluido_em, s.pago_em,
           s.pag_comprovante, s.nao_recebi_em, s.nao_recebi_obs
    from public.servicos s left join public.perfis pe on pe.user_id = s.criado_por left join public.perfis pp on pp.user_id = s.pego_por
    where s.status = 'concluido' and s.recebido_em is null
      and (s.nao_recebi_em is not null or s.concluido_em < now() - interval '48 hours')
    order by (s.nao_recebi_em is not null) desc, s.concluido_em;
end $$;

drop function if exists public.meus_trabalhos();
create or replace function public.meus_trabalhos()
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos integer, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, status text, minha text, criado_em timestamptz, quem_enviou text,
              espera_min integer, espera_valor numeric, iniciado_em timestamptz, concluido_em timestamptz,
              pago_em timestamptz, recebido_em timestamptz, pag_comprovante text, nao_recebi_em timestamptz)
language sql stable security definer set search_path = public as $$
  select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.status,
         c.status, s.criado_em, case when s.pego_por = auth.uid() then p.nome end,
         s.espera_min, s.espera_valor, s.iniciado_em, s.concluido_em,
         case when s.pego_por = auth.uid() then s.pago_em end, case when s.pego_por = auth.uid() then s.recebido_em end,
         case when s.pego_por = auth.uid() then s.pag_comprovante end, case when s.pego_por = auth.uid() then s.nao_recebi_em end
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
              pago_em timestamptz, recebido_em timestamptz, pag_comprovante text, nao_recebi_em timestamptz, nao_recebi_obs text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select s.id, s.numero, s.status, s.retirada, s.paradas, s.km, s.veiculo, s.valor, s.agendado_para, s.criado_em,
           pe.nome, pp.nome,
           (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status in ('ativa','escolhida')),
           (select count(*)::int from public.mensagens m where m.servico_id = s.id),
           s.espera_min, s.espera_valor, s.rastreio_ver, s.iniciado_em, s.concluido_em, s.pago_em, s.recebido_em, s.pag_comprovante,
           s.nao_recebi_em, s.nao_recebi_obs
    from public.servicos s left join public.perfis pe on pe.user_id = s.criado_por left join public.perfis pp on pp.user_id = s.pego_por
    where s.criado_em > now() - make_interval(days => greatest(1, least(coalesce(p_dias,7), 90)))
       or (s.status = 'concluido' and s.recebido_em is null)
    order by s.criado_em desc limit 300;
end $$;

revoke all on function public._baixas_pendentes(uuid) from public, anon;
grant execute on function public._baixas_pendentes(uuid) to authenticated;
revoke all on function public.minhas_baixas_pendentes(), public.servico_nao_recebi(uuid,text), public.adm_alertas_pagamento(),
  public.meus_trabalhos(), public.adm_servicos(integer), public.servico_recebi(uuid) from public, anon;
grant execute on function public.minhas_baixas_pendentes(), public.servico_nao_recebi(uuid,text), public.adm_alertas_pagamento(),
  public.meus_trabalhos(), public.adm_servicos(integer), public.servico_recebi(uuid) to authenticated;
