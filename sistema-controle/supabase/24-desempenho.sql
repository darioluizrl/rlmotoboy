-- 24: desempenho — regras de acesso avaliadas uma vez por consulta + índices das chaves estrangeiras
alter policy membros_ver on public.membros
  using ((user_id = (select auth.uid())) or (select public.is_admin()));
alter policy perfis_ver on public.perfis
  using ((user_id = (select auth.uid())) or (select public.is_admin()));
alter policy documentos_ver on public.documentos
  using ((user_id = (select auth.uid())) or (select public.is_admin()));
alter policy documentos_inserir on public.documentos
  with check ((user_id = (select auth.uid()))
    and (caminho like ((select auth.uid())::text || '/%'))
    and (select public.cadastro_editavel()));
alter policy documentos_apagar on public.documentos
  using (((user_id = (select auth.uid())) and (select public.cadastro_editavel())) or (select public.is_admin()));
alter policy servicos_ver on public.servicos
  using ((criado_por = (select auth.uid())) or (pego_por = (select auth.uid())) or (select public.is_admin()));
alter policy localizacoes_ver on public.localizacoes
  using ((user_id = (select auth.uid())) or (select public.is_admin()));
alter policy candidaturas_ver on public.candidaturas
  using ((prestador_id = (select auth.uid())) or (select public.is_admin())
    or exists (select 1 from public.servicos s
               where s.id = candidaturas.servico_id and s.criado_por = (select auth.uid())));
alter policy mensagens_ver on public.mensagens
  using ((select public.is_admin())
    or exists (select 1 from public.servicos s
               where s.id = mensagens.servico_id
                 and (s.criado_por = (select auth.uid()) or s.pego_por = (select auth.uid()))));

create index if not exists candidaturas_prestador_idx on public.candidaturas (prestador_id);
create index if not exists mensagens_autor_idx on public.mensagens (autor);
create index if not exists perfis_convite_idx on public.perfis (convite);
create index if not exists servicos_criado_por_idx on public.servicos (criado_por);
create index if not exists servicos_pego_por_idx on public.servicos (pego_por);
