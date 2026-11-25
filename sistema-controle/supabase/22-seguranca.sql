-- 22: correções do teste de segurança (MegaEntregas)

-- 1) Checagem de dono com NULL: num serviço sem motoboy (pego_por nulo), "not (a or null)" dava nulo
--    e deixava passar qualquer pessoa. Agora nulo conta como "não".
do $$
declare f text; d text;
begin
  foreach f in array array['public.servico_previsao(uuid)','public.chat_listar(uuid,bigint)','public.chat_enviar(uuid,text)'] loop
    d := pg_get_functiondef(f::regprocedure);
    d := replace(d, 'if s.id is null or not (s.criado_por = auth.uid() or s.pego_por = auth.uid() or public.is_admin()) then',
                    'if s.id is null or not coalesce(s.criado_por = auth.uid() or s.pego_por = auth.uid() or public.is_admin(), false) then');
    execute d;
  end loop;
end $$;

-- 2) Funções internas não ficam expostas na API (só são usadas por dentro de outras funções)
revoke execute on function public._perfil_ativo(), public._exige_dono(), public._espera_cfg(), public.is_dono(),
  public._quer_veic(public.perfis, text), public._veic_liberado(text), public._baixas_pendentes(uuid),
  public._srv_meu(uuid), public._srv_totais(uuid), public._validar_cadastro(text, jsonb)
  from public, anon, authenticated;

-- 3) Previsões só para quem entrou (a página pública de rastreio usa servico_previsao_publica)
revoke execute on function public.servico_previsao(uuid), public.servicos_previsoes(uuid[]) from public, anon;
grant execute on function public.servico_previsao(uuid), public.servicos_previsoes(uuid[]) to authenticated;

-- 4) Encurtador de links não é usado pelo app: fecha a criação de links pela API
revoke execute on function public.encurtar(text) from public, anon, authenticated;

-- 5) search_path fixo nas funções auxiliares
alter function public._dist_km set search_path = public;
alter function public._ponto_ok set search_path = public;
alter function public._espera_ponto set search_path = public;
alter function public._veic_compat(text) set search_path = public;
