-- 26: mensagens do banco com o nome novo (MegaEntregas -> Soltou, Pegou). Só textos; regras iguais.
do $$
declare r record; d text;
begin
  for r in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.prokind = 'f' and p.prosrc ilike '%MegaEntregas%' loop
    d := pg_get_functiondef(r.oid);
    d := replace(d, 'Por enquanto a MegaEntregas está aceitando', 'Por enquanto o Soltou, Pegou está aceitando');
    d := replace(d, 'fale com a MegaEntregas', 'fale com o suporte do Soltou, Pegou');
    d := replace(d, 'Fale com a MegaEntregas', 'Fale com o suporte do Soltou, Pegou');
    d := replace(d, 'Removido pela MegaEntregas', 'Removido pela administração do Soltou, Pegou');
    d := replace(d, 'liberado na MegaEntregas', 'liberado no Soltou, Pegou');
    d := replace(d, 'equipe MegaEntregas', 'equipe do Soltou, Pegou');
    d := replace(d, 'administração MegaEntregas', 'administração do Soltou, Pegou');
    d := replace(d, 'MegaEntregas', 'Soltou, Pegou');
    execute d;
  end loop;
end $$;
