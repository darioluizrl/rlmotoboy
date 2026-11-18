-- Perfil "orcamento": só cria/edita orçamentos (lê clientes e configurações para montar o orçamento)
alter table public.membros drop constraint if exists membros_papel_check;
alter table public.membros add constraint membros_papel_check check (papel in ('admin','funcionario','orcamento'));

create or replace function public.papel_atual() returns text
language sql stable security definer set search_path = public as $$
  select papel from public.membros where user_id = auth.uid() and ativo;
$$;
revoke all on function public.papel_atual() from public, anon;
grant execute on function public.papel_atual() to authenticated;

drop policy if exists docs_membros on public.docs;
drop policy if exists docs_ler on public.docs;
drop policy if exists docs_inserir on public.docs;
drop policy if exists docs_alterar on public.docs;
drop policy if exists docs_apagar on public.docs;

create policy docs_ler on public.docs for select to authenticated
  using ( public.papel_atual() in ('admin','funcionario')
       or (public.papel_atual() = 'orcamento' and colecao in ('orcamentos','clientes','config')) );

create policy docs_inserir on public.docs for insert to authenticated
  with check ( public.papel_atual() in ('admin','funcionario')
       or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos') );

create policy docs_alterar on public.docs for update to authenticated
  using ( public.papel_atual() in ('admin','funcionario')
       or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos') )
  with check ( public.papel_atual() in ('admin','funcionario')
       or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos') );

create policy docs_apagar on public.docs for delete to authenticated
  using ( public.papel_atual() in ('admin','funcionario')
       or (public.papel_atual() = 'orcamento' and colecao = 'orcamentos') );

create or replace function public.liberar_usuario(p_email text, p_papel text default 'funcionario') returns text
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_admin() then raise exception 'Apenas administradores'; end if;
  if p_papel not in ('admin','funcionario','orcamento') then raise exception 'Perfil inválido'; end if;
  select id into uid from auth.users where lower(email) = lower(trim(p_email));
  if uid is null then raise exception 'O usuário % ainda não criou o acesso', p_email; end if;
  if uid = auth.uid() and p_papel <> 'admin' then raise exception 'Você não pode tirar seu próprio acesso de administrador'; end if;
  insert into public.membros (user_id, email, papel, ativo) values (uid, lower(trim(p_email)), p_papel, true)
  on conflict (user_id) do update set papel = excluded.papel, ativo = true, email = excluded.email;
  return 'ok';
end $$;
