-- 14: marca própria de quem envia (nome + logo nos comprovantes) e painel de gestão liberado pelo dono
alter table public.perfis add column if not exists marca_nome text check (length(marca_nome) <= 80);
alter table public.perfis add column if not exists marca_logo text check (marca_logo is null or (marca_logo like 'data:image/%' and length(marca_logo) <= 200000));
alter table public.perfis add column if not exists gestao boolean not null default false;
alter table public.perfis add column if not exists gestao_em timestamptz;

-- quem envia define a própria marca (no cadastro ou depois). p_logo: null = mantém, '' = tira
create or replace function public.minha_marca(p_nome text, p_logo text) returns text
language plpgsql security definer set search_path = public as $$
declare p public.perfis;
begin
  select * into p from public.perfis where user_id = auth.uid();
  if p.user_id is null then raise exception 'Complete seu cadastro primeiro'; end if;
  if not p.envia then raise exception 'A marca nos recibos é para quem envia serviços'; end if;
  if p_logo is not null and p_logo <> '' and (p_logo not like 'data:image/%' or length(p_logo) > 200000) then
    raise exception 'Logo inválido ou muito grande'; end if;
  update public.perfis set marca_nome = nullif(left(trim(coalesce(p_nome,'')),80),''),
         marca_logo = case when p_logo is null then marca_logo when p_logo = '' then null else p_logo end,
         atualizado_em = now()
  where user_id = auth.uid();
  return 'ok';
end $$;

-- o dono liga/desliga o painel de gestão de uma empresa
create or replace function public.cfg_gestao(p_user uuid, p_ligar boolean) returns text
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  update public.perfis set gestao = p_ligar, gestao_em = now(), atualizado_em = now() where user_id = p_user and envia;
  if not found then raise exception 'O painel de gestão é para quem envia serviços'; end if;
  return 'ok';
end $$;

drop function if exists public.cfg_usuarios();
create or replace function public.cfg_usuarios()
returns table(user_id uuid, email text, nome text, papel text, tipo text, ativo boolean, cadastro text,
              removido_em timestamptz, criado_em timestamptz, ultimo_acesso timestamptz, envia boolean, gestao boolean)
language plpgsql security definer set search_path = public as $$
begin
  perform public._exige_dono();
  return query
    select u.id, u.email::text, p.nome, m.papel, p.tipo, coalesce(m.ativo,false), p.status,
           m.removido_em, u.created_at, u.last_sign_in_at, coalesce(p.envia,false), coalesce(p.gestao,false)
    from auth.users u
    left join public.membros m on m.user_id = u.id
    left join public.perfis  p on p.user_id = u.id
    order by (m.papel = 'dono') desc nulls last, u.created_at desc;
end $$;

-- painel de gestão: os serviços da própria empresa no período (só com o painel liberado)
create or replace function public.gestao_servicos(p_ini date, p_fim date)
returns table(id uuid, numero bigint, criado_em timestamptz, concluido_em timestamptz, status text, retirada jsonb, paradas jsonb,
              km numeric, veiculo text, valor numeric, valor_inicial numeric, espera_min int, espera_valor numeric,
              agendado_para timestamptz, quem_pegou text, placa text)
language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo();
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.gestao then raise exception 'O painel de gestão não está liberado para sua conta. Fale com a MegaEntregas.'; end if;
  if p_ini is null or p_fim is null or p_fim < p_ini or p_fim - p_ini > 400 then raise exception 'Período inválido'; end if;
  return query
    select s.id, s.numero, s.criado_em, s.concluido_em, s.status, s.retirada, s.paradas, s.km, s.veiculo, s.valor, s.valor_inicial,
           coalesce(s.espera_min,0), coalesce(s.espera_valor,0), s.agendado_para, pp.nome, pp.placa
    from public.servicos s
    left join public.perfis pp on pp.user_id = s.pego_por
    where s.criado_por = auth.uid()
      and s.criado_em >= (p_ini::timestamp at time zone 'America/Sao_Paulo')
      and s.criado_em <  ((p_fim + 1)::timestamp at time zone 'America/Sao_Paulo')
    order by s.criado_em desc
    limit 5000;
end $$;

revoke all on function public.minha_marca(text,text) from public, anon;
revoke all on function public.cfg_gestao(uuid,boolean) from public, anon;
revoke all on function public.cfg_usuarios() from public, anon;
revoke all on function public.gestao_servicos(date,date) from public, anon;
grant execute on function public.minha_marca(text,text), public.cfg_gestao(uuid,boolean), public.cfg_usuarios(),
  public.gestao_servicos(date,date) to authenticated;
