-- 20: o mesmo cadastro pode enviar e receber serviços (motoboy que também solta trabalho)
create or replace function public.adm_uso(p_user uuid, p_envia boolean, p_recebe boolean)
returns text language plpgsql security definer set search_path = public as $$
declare p public.perfis;
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if not coalesce(p_envia,false) and not coalesce(p_recebe,false) then raise exception 'O cadastro precisa enviar, receber ou os dois'; end if;
  select * into p from public.perfis where user_id = p_user;
  if p.user_id is null then raise exception 'Cadastro não encontrado'; end if;
  if p_recebe and p.veiculo is null then raise exception 'Para receber serviços o cadastro precisa ter veículo, placa e CNH. Peça para a pessoa completar em "Meu cadastro".'; end if;
  update public.perfis set envia = p_envia, recebe = p_recebe,
         gestao = case when p_envia then gestao else false end,
         disponivel = case when p_recebe then disponivel else false end,
         atualizado_em = now()
   where user_id = p_user;
  return 'ok';
end $$;

-- a própria pessoa (cadastro aprovado) liga ou desliga "também envio serviços"
create or replace function public.meu_uso_envia(p_ligar boolean)
returns text language plpgsql security definer set search_path = public as $$
declare p public.perfis;
begin
  select * into p from public.perfis where user_id = auth.uid();
  if p.user_id is null then raise exception 'Cadastro não encontrado'; end if;
  if p.status <> 'aprovado' then raise exception 'Seu cadastro precisa estar aprovado'; end if;
  if not p_ligar and not p.recebe then raise exception 'Seu cadastro é só de envio — não dá para desligar'; end if;
  update public.perfis set envia = p_ligar, gestao = case when p_ligar then gestao else false end, atualizado_em = now() where user_id = auth.uid();
  return 'ok';
end $$;

revoke all on function public.adm_uso(uuid, boolean, boolean), public.meu_uso_envia(boolean) from public, anon;
grant execute on function public.adm_uso(uuid, boolean, boolean), public.meu_uso_envia(boolean) to authenticated;
