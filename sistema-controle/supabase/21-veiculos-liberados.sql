-- 21: tipos de veículo liberados pelo dono (começa só com moto) + ajustes do motoboy/motorista
alter table public.config_sistema drop constraint if exists config_sistema_chave_check;
alter table public.config_sistema add constraint config_sistema_chave_check check (chave = any (array['distribuicao','espera','creditos','mapa','veiculos']));
insert into public.config_sistema (chave, valor) values ('veiculos', '{"moto":true,"carro":false,"utilitario":false,"caminhao":false}')
on conflict (chave) do nothing;

alter table public.perfis add column if not exists quer_veiculos text[];

-- veículos que cada tipo de prestador consegue atender
create or replace function public._veic_compat(p_veic text) returns text[] language sql immutable as $$
  select case p_veic when 'moto' then array['moto'] when 'carro' then array['carro']
                     when 'utilitario' then array['carro','utilitario'] when 'caminhao' then array['utilitario','caminhao'] else array[]::text[] end;
$$;

create or replace function public._veic_liberado(p_veic text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select (valor->>p_veic)::boolean from public.config_sistema where chave = 'veiculos'), p_veic = 'moto');
$$;

create or replace function public.veiculos_liberados() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select valor from public.config_sistema where chave = 'veiculos'), '{"moto":true,"carro":false,"utilitario":false,"caminhao":false}'::jsonb);
$$;

-- o prestador quer este serviço? (liberado no sistema + está nos ajustes dele)
create or replace function public._quer_veic(p public.perfis, p_veic text) returns boolean language sql stable security definer set search_path = public as $$
  select public._veic_liberado(p_veic) and (p.quer_veiculos is null or cardinality(p.quer_veiculos) = 0 or p_veic = any(p.quer_veiculos));
$$;

-- ajustes do motoboy/motorista: quais tipos de serviço quer receber
create or replace function public.meus_ajustes(p_quer text[]) returns text language plpgsql security definer set search_path = public as $$
declare me public.perfis := public._perfil_ativo(); v text; ok text[] := array[]::text[];
begin
  if me.user_id is null then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not me.recebe then raise exception 'Seu cadastro não recebe serviços'; end if;
  foreach v in array coalesce(p_quer, array[]::text[]) loop
    if v = any(public._veic_compat(me.veiculo)) and public._veic_liberado(v) and not v = any(ok) then ok := ok || v; end if;
  end loop;
  if cardinality(ok) = 0 then raise exception 'Escolha pelo menos um tipo de serviço'; end if;
  update public.perfis set quer_veiculos = ok, atualizado_em = now() where user_id = me.user_id;
  return 'ok';
end $$;

-- dono: salvar veículos liberados
do $$
declare d text;
begin
  d := pg_get_functiondef('public.cfg_salvar'::regproc);
  if position('''veiculos''' in d) = 0 then
    d := replace(d, E'  else\n    raise exception ''Configuração desconhecida'';',
      E'  elsif p_chave = ''veiculos'' then\n    v := jsonb_build_object(''moto'',coalesce((p_valor->>''moto'')::boolean,false),''carro'',coalesce((p_valor->>''carro'')::boolean,false),\n                            ''utilitario'',coalesce((p_valor->>''utilitario'')::boolean,false),''caminhao'',coalesce((p_valor->>''caminhao'')::boolean,false));\n    if not (v->>''moto'')::boolean and not (v->>''carro'')::boolean and not (v->>''utilitario'')::boolean and not (v->>''caminhao'')::boolean then\n      raise exception ''Libere pelo menos um tipo de veículo''; end if;\n  else\n    raise exception ''Configuração desconhecida'';');
    execute d;
  end if;

  -- cadastro: só veículo liberado
  d := pg_get_functiondef('public._validar_cadastro'::regproc);
  if position('_veic_liberado' in d) = 0 then
    d := replace(d, ' IMMUTABLE', ' STABLE');
    d := replace(d, E'raise exception ''Escolha o tipo de veículo''; end if;',
      E'raise exception ''Escolha o tipo de veículo''; end if;\n    if not public._veic_liberado(d->>''veiculo'') then raise exception ''Por enquanto a MegaEntregas está aceitando só os veículos liberados. Escolha outro ou aguarde a liberação.''; end if;');
    execute d;
  end if;

  -- soltar serviço: só veículo liberado
  d := pg_get_functiondef('public.servico_soltar'::regproc);
  if position('_veic_liberado' in d) = 0 then
    d := replace(d, E'  ag := nullif(', E'  if not public._veic_liberado(p->>''veiculo'') then raise exception ''Esse tipo de veículo ainda não está liberado na MegaEntregas''; end if;\n  ag := nullif(');
    execute d;
  end if;

  -- lista de serviços próximos: respeita liberação + ajustes do prestador
  d := pg_get_functiondef('public.servicos_proximos(double precision, double precision)'::regprocedure);
  if position('_quer_veic' in d) = 0 then
    d := replace(d, 'where s.status = ''aberto'' and s.criado_por <> auth.uid()', 'where s.status = ''aberto'' and s.criado_por <> auth.uid() and public._quer_veic(me, s.veiculo)');
    execute d;
  end if;
end $$;

revoke all on function public.meus_ajustes(text[]) from public, anon;
grant execute on function public.meus_ajustes(text[]) to authenticated;
grant execute on function public.veiculos_liberados() to anon, authenticated;
