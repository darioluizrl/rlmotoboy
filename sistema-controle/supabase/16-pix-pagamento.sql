-- 16: PIX obrigatório no cadastro + pagamento do motoboy após a entrega
--     (empresa vê o PIX, envia comprovante ou marca "já paguei"; motoboy confirma "recebi";
--      sem confirmação em 48h a empresa fica bloqueada para soltar novos serviços)
alter table public.perfis add column if not exists pix_tipo  text check (pix_tipo in ('cpf','cnpj','email','telefone','aleatoria'));
alter table public.perfis add column if not exists pix_chave text check (length(pix_chave) <= 120);
alter table public.perfis add column if not exists pix_nome  text check (length(pix_nome) <= 120);
alter table public.perfis add column if not exists pix_banco text check (length(pix_banco) <= 80);

alter table public.servicos add column if not exists pago_em            timestamptz;
alter table public.servicos add column if not exists pag_comprovante    text;
alter table public.servicos add column if not exists recebido_em        timestamptz;
alter table public.servicos add column if not exists recebido_por_admin uuid;

-- validação do PIX (usada no cadastro e na troca de PIX)
create or replace function public._validar_pix(d jsonb) returns void
language plpgsql immutable set search_path = public as $$
declare t text := coalesce(d->>'pix_tipo',''); k text := trim(coalesce(d->>'pix_chave','')); n text := regexp_replace(coalesce(d->>'pix_chave',''),'\D','','g');
begin
  if t not in ('cpf','cnpj','email','telefone','aleatoria') then raise exception 'Escolha o tipo da chave PIX'; end if;
  if k = '' then raise exception 'Informe a chave PIX'; end if;
  if t = 'cpf' and length(n) <> 11 then raise exception 'Chave PIX (CPF) deve ter 11 números'; end if;
  if t = 'cnpj' and length(n) <> 14 then raise exception 'Chave PIX (CNPJ) deve ter 14 números'; end if;
  if t = 'telefone' and length(n) not between 10 and 13 then raise exception 'Chave PIX (telefone) inválida'; end if;
  if t = 'email' and k !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Chave PIX (e-mail) inválida'; end if;
  if t = 'aleatoria' and length(regexp_replace(k,'[^0-9A-Za-z]','','g')) <> 32 then raise exception 'Chave PIX aleatória inválida (32 letras e números)'; end if;
  if length(trim(coalesce(d->>'pix_nome',''))) < 5 or position(' ' in trim(coalesce(d->>'pix_nome',''))) = 0 then raise exception 'Informe o nome completo de quem recebe o PIX'; end if;
  if length(trim(coalesce(d->>'pix_banco',''))) < 2 then raise exception 'Informe o banco da chave PIX'; end if;
end $$;

create or replace function public._salvar_pix(p_user uuid, d jsonb) returns void
language sql security definer set search_path = public as $$
  update public.perfis set pix_tipo = d->>'pix_tipo',
         pix_chave = case when d->>'pix_tipo' in ('cpf','cnpj','telefone') then regexp_replace(d->>'pix_chave','\D','','g')
                          when d->>'pix_tipo' = 'email' then lower(trim(d->>'pix_chave')) else trim(d->>'pix_chave') end,
         pix_nome = trim(d->>'pix_nome'), pix_banco = trim(d->>'pix_banco'), atualizado_em = now()
  where user_id = p_user;
$$;
revoke all on function public._salvar_pix(uuid,jsonb) from public, anon, authenticated;

-- cadastro e edição passam a exigir e salvar o PIX
do $$
declare d text;
begin
  d := pg_get_functiondef('public._validar_cadastro'::regproc);
  if position('_validar_pix' in d) = 0 then
    d := regexp_replace(d, '\nend \$function\$', E'\n  perform public._validar_pix(d);\nend $function$');
    execute d;
  end if;
  d := pg_get_functiondef('public.registrar_cadastro'::regproc);
  if position('_salvar_pix' in d) = 0 then
    d := replace(d, '  update public.convites set usos', E'  perform public._salvar_pix(uid, d);\n  update public.convites set usos');
    execute d;
  end if;
  d := pg_get_functiondef('public.atualizar_cadastro'::regproc);
  if position('_salvar_pix' in d) = 0 then
    d := replace(d, '  update public.membros set papel', E'  perform public._salvar_pix(p.user_id, d);\n  update public.membros set papel');
    execute d;
  end if;
end $$;

-- trocar o PIX a qualquer momento (mesmo com cadastro aprovado)
create or replace function public.meu_pix(p_dados jsonb) returns text
language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from public.perfis where user_id = auth.uid()) then raise exception 'Complete seu cadastro primeiro'; end if;
  perform public._validar_pix(p_dados);
  perform public._salvar_pix(auth.uid(), p_dados);
  return 'ok';
end $$;

-- pagamentos em atraso de uma empresa (concluído há mais de 48h e o motoboy não confirmou)
create or replace function public._pag_atrasados(p_user uuid) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.servicos
  where criado_por = p_user and status = 'concluido' and recebido_em is null and concluido_em < now() - interval '48 hours';
$$;
create or replace function public.meus_pagamentos_atrasados() returns int
language sql stable security definer set search_path = public as $$ select public._pag_atrasados(auth.uid()); $$;

-- soltar serviço: bloqueado se houver pagamento em atraso
do $$
declare d text;
begin
  d := pg_get_functiondef('public.servico_soltar'::regproc);
  if position('_pag_atrasados' in d) = 0 then
    d := regexp_replace(d, E'\nbegin\n', E'\nbegin\n  if public._pag_atrasados(auth.uid()) > 0 then raise exception ''Você tem pagamento de motoboy/motorista sem confirmação há mais de 48 horas. Pague e peça para ele confirmar o recebimento para voltar a soltar serviços.''; end if;\n');
    execute d;
  end if;
end $$;

-- empresa vê o PIX de quem fez o serviço (só depois de concluído)
create or replace function public.servico_pix(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare s public.servicos; p public.perfis;
begin
  select * into s from public.servicos where id = p_id;
  if s.id is null or (s.criado_por <> auth.uid() and not public.is_admin()) then raise exception 'Serviço não encontrado'; end if;
  if s.status <> 'concluido' then raise exception 'O PIX aparece quando o serviço for concluído'; end if;
  select * into p from public.perfis where user_id = s.pego_por;
  return jsonb_build_object('quem', p.nome, 'pix_tipo', p.pix_tipo, 'pix_chave', p.pix_chave, 'pix_nome', p.pix_nome, 'pix_banco', p.pix_banco,
    'telefone', p.telefone, 'valor', s.valor + coalesce(s.espera_valor,0), 'frete', s.valor, 'espera', coalesce(s.espera_valor,0),
    'pago_em', s.pago_em, 'recebido_em', s.recebido_em, 'comprovante', s.pag_comprovante);
end $$;

-- empresa informa o pagamento (com comprovante ou sem)
create or replace function public.servico_paguei(p_id uuid, p_comprovante text) returns text
language plpgsql security definer set search_path = public as $$
declare s public.servicos;
begin
  select * into s from public.servicos where id = p_id for update;
  if s.id is null or s.criado_por <> auth.uid() then raise exception 'Serviço não encontrado'; end if;
  if s.status <> 'concluido' then raise exception 'O serviço ainda não foi concluído'; end if;
  if s.recebido_em is not null then raise exception 'O recebimento já foi confirmado'; end if;
  if p_comprovante is not null and p_comprovante !~ ('^' || p_id::text || '/') then raise exception 'Comprovante inválido'; end if;
  update public.servicos set pago_em = coalesce(pago_em, now()), pag_comprovante = coalesce(p_comprovante, pag_comprovante), atualizado_em = now()
  where id = p_id;
  insert into public.mensagens (servico_id, autor, texto)
  values (p_id, auth.uid(), case when p_comprovante is not null then '💸 Pagamento feito. O comprovante está no serviço. Confira e toque em "Recebi o pagamento".'
                               else '💸 Pagamento feito (sem comprovante). Confira e toque em "Recebi o pagamento".' end);
  return 'ok';
end $$;

-- motoboy/motorista confirma que recebeu (ou um admin resolve)
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

-- lista do motoboy com a situação do pagamento
drop function if exists public.meus_trabalhos();
create or replace function public.meus_trabalhos()
returns table(id uuid, numero bigint, retirada jsonb, paradas jsonb, km numeric, minutos integer, veiculo text, valor numeric,
              agendado_para timestamptz, obs text, status text, minha text, criado_em timestamptz, quem_enviou text,
              espera_min integer, espera_valor numeric, iniciado_em timestamptz, concluido_em timestamptz,
              pago_em timestamptz, recebido_em timestamptz, pag_comprovante text)
language sql stable security definer set search_path = public as $$
  select s.id, s.numero, s.retirada, s.paradas, s.km, s.minutos, s.veiculo, s.valor, s.agendado_para, s.obs, s.status,
         c.status, s.criado_em, case when s.pego_por = auth.uid() then p.nome end,
         s.espera_min, s.espera_valor, s.iniciado_em, s.concluido_em,
         case when s.pego_por = auth.uid() then s.pago_em end, case when s.pego_por = auth.uid() then s.recebido_em end,
         case when s.pego_por = auth.uid() then s.pag_comprovante end
  from public.candidaturas c join public.servicos s on s.id = c.servico_id join public.perfis p on p.user_id = s.criado_por
  where c.prestador_id = auth.uid() and c.criado_em > now() - interval '30 days'
    and (c.status = 'ativa' or (c.status = 'escolhida' and s.status in ('aceito','em_andamento','concluido')) or c.status = 'recusada')
  order by (c.status = 'escolhida' and s.status = 'concluido' and s.recebido_em is null) desc,
           (c.status = 'escolhida' and s.status in ('aceito','em_andamento')) desc, c.criado_em desc
  limit 30;
$$;

-- painel da administração com a situação do pagamento
drop function if exists public.adm_servicos(integer);
create or replace function public.adm_servicos(p_dias integer default 7)
returns table(id uuid, numero bigint, status text, retirada jsonb, paradas jsonb, km numeric, veiculo text, valor numeric,
              agendado_para timestamptz, criado_em timestamptz, quem_enviou text, quem_pegou text, candidatos integer, mensagens integer,
              espera_min integer, espera_valor numeric, rastreio_ver text, iniciado_em timestamptz, concluido_em timestamptz,
              pago_em timestamptz, recebido_em timestamptz, pag_comprovante text)
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  return query
    select s.id, s.numero, s.status, s.retirada, s.paradas, s.km, s.veiculo, s.valor, s.agendado_para, s.criado_em,
           pe.nome, pp.nome,
           (select count(*)::int from public.candidaturas c where c.servico_id = s.id and c.status in ('ativa','escolhida')),
           (select count(*)::int from public.mensagens m where m.servico_id = s.id),
           s.espera_min, s.espera_valor, s.rastreio_ver, s.iniciado_em, s.concluido_em, s.pago_em, s.recebido_em, s.pag_comprovante
    from public.servicos s left join public.perfis pe on pe.user_id = s.criado_por left join public.perfis pp on pp.user_id = s.pego_por
    where s.criado_em > now() - make_interval(days => greatest(1, least(coalesce(p_dias,7), 90)))
    order by s.criado_em desc limit 300;
end $$;

-- comprovantes de pagamento (pasta = id do serviço)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pagamentos','pagamentos', false, 8388608, array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do nothing;
drop policy if exists pag_enviar on storage.objects;
create policy pag_enviar on storage.objects for insert to authenticated
  with check (bucket_id = 'pagamentos' and exists (select 1 from public.servicos s where s.id::text = (storage.foldername(name))[1]
              and s.criado_por = auth.uid() and s.status = 'concluido'));
drop policy if exists pag_ver on storage.objects;
create policy pag_ver on storage.objects for select to authenticated
  using (bucket_id = 'pagamentos' and (public.is_admin() or exists (select 1 from public.servicos s where s.id::text = (storage.foldername(name))[1]
              and (s.criado_por = auth.uid() or s.pego_por = auth.uid()))));

revoke all on function public.meu_pix(jsonb), public.servico_pix(uuid), public.servico_paguei(uuid,text), public.servico_recebi(uuid),
  public.meus_trabalhos(), public.adm_servicos(integer), public.meus_pagamentos_atrasados() from public, anon;
grant execute on function public.meu_pix(jsonb), public.servico_pix(uuid), public.servico_paguei(uuid,text), public.servico_recebi(uuid),
  public.meus_trabalhos(), public.adm_servicos(integer), public.meus_pagamentos_atrasados() to authenticated;
revoke all on function public._pag_atrasados(uuid), public._validar_pix(jsonb) from public, anon;
grant execute on function public._pag_atrasados(uuid), public._validar_pix(jsonb) to authenticated;
