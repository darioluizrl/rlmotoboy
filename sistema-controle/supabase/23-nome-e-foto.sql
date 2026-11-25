-- 23: quem envia vê nome e FOTO (selfie do cadastro) de quem se candidatou;
--     motoboy/motorista vê o nome ou a empresa de quem está enviando.

drop function if exists public.servico_candidatos(uuid);
create function public.servico_candidatos(p_id uuid)
returns table(prestador_id uuid, nome text, veiculo text, modelo text, placa text, cidade text, distancia_km numeric, status text,
              criado_em timestamptz, servicos_feitos bigint, foto text)
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.servicos s where s.id = p_id and (s.criado_por = auth.uid() or public.is_admin())) then
    raise exception 'Serviço não encontrado'; end if;
  return query
    select c.prestador_id, p.nome, p.veiculo, p.modelo,
           left(p.placa,3) || '-' || right(p.placa,2),
           p.cidade, c.distancia_km, c.status, c.criado_em,
           (select count(*) from public.servicos x where x.pego_por = c.prestador_id and x.status = 'concluido'),
           (select d.caminho from public.documentos d where d.user_id = c.prestador_id and d.tipo = 'selfie' order by d.criado_em desc limit 1)
    from public.candidaturas c join public.perfis p on p.user_id = c.prestador_id
    where c.servico_id = p_id and c.status in ('ativa','escolhida')
    order by c.status = 'escolhida' desc, c.criado_em;
end $$;
revoke all on function public.servico_candidatos(uuid) from public, anon;
grant execute on function public.servico_candidatos(uuid) to authenticated;

-- a selfie de quem se candidatou pode ser vista por quem soltou o serviço (só a selfie, só enquanto candidato/escolhido)
drop policy if exists selfie_para_quem_envia on storage.objects;
create policy selfie_para_quem_envia on storage.objects for select to authenticated using (
  bucket_id = 'documentos' and exists (
    select 1 from public.documentos d
      join public.candidaturas c on c.prestador_id = d.user_id and c.status in ('ativa','escolhida')
      join public.servicos s on s.id = c.servico_id and s.criado_por = auth.uid()
    where d.caminho = storage.objects.name and d.tipo = 'selfie'));

-- motoboy vê quem envia: na lista de serviços perto e nos trabalhos dele
do $$
declare d text;
begin
  d := pg_get_functiondef('public.servicos_proximos(double precision, double precision)'::regprocedure);
  if position('quem_envia' in d) = 0 then
    d := replace(d, 'aumentado_em timestamp with time zone, forma_pag text)', 'aumentado_em timestamp with time zone, forma_pag text, quem_envia text)');
    d := replace(d, 'q.valor_inicial, q.aumentado_em, q.forma_pag', 'q.valor_inicial, q.aumentado_em, q.forma_pag, q.quem_envia');
    d := replace(d, 's.valor_inicial, s.aumentado_em, s.forma_pag,', 's.valor_inicial, s.aumentado_em, s.forma_pag, (select coalesce(nullif(pe.marca_nome,''''), pe.nome) from public.perfis pe where pe.user_id = s.criado_por) as quem_envia,');
    if position('q.quem_envia' in d) = 0 or position('as quem_envia' in d) = 0 or position('forma_pag text, quem_envia text' in d) = 0 then raise exception 'servicos_proximos: troca não aplicada'; end if;
    execute 'drop function public.servicos_proximos(double precision, double precision)';
    execute d;
  end if;
  d := pg_get_functiondef('public.meus_trabalhos()'::regprocedure);
  if position('marca_nome' in d) = 0 then
    d := replace(d, 'case when s.pego_por = auth.uid() then p.nome end', 'coalesce(nullif(p.marca_nome,''''), p.nome)');
    if position('marca_nome' in d) = 0 then raise exception 'meus_trabalhos: troca não aplicada'; end if;
    execute d;
  end if;
end $$;
revoke all on function public.servicos_proximos(double precision, double precision) from public, anon;
grant execute on function public.servicos_proximos(double precision, double precision) to authenticated;
