-- Mapa geral da RL: todos os motoboys/motoristas ativos (posição recente) e se estão livres ou em serviço.
-- "Ativo" = mandou posição nos últimos 15 minutos (app aberto em "Serviços perto de mim" ou em serviço).
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
      where p.recebe and p.status = 'aprovado'
    )
    select pos.user_id, pos.nome, pos.veiculo, pos.placa, pos.telefone, pos.lat, pos.lon, pos.quando,
           case when pos.sst = 'em_andamento' then 'em_servico' when pos.sst = 'aceito' then 'escolhido' else 'livre' end,
           pos.numero, pos.sid, pos.rastreio_ver, now()
    from pos
    where pos.lat is not null and (pos.quando > now() - interval '15 minutes' or pos.sst is not null)
    order by 9 desc, pos.nome;
end $$;
revoke all on function public.adm_motoboys() from public, anon;
grant execute on function public.adm_motoboys() to authenticated;
