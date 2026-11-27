-- 27: posição do motoboy livre mais frequente (leve: só grava a posição, no máximo 1 vez a cada 4 s)
create or replace function public.minha_posicao(p_lat double precision, p_lon double precision)
returns boolean language plpgsql security definer set search_path to 'public' as $$
declare me public.perfis := public._perfil_ativo(); uid uuid := auth.uid();
begin
  if me.user_id is null or not coalesce(me.recebe, false) or not coalesce(me.disponivel, false) then return false; end if;
  if p_lat is null or p_lon is null or p_lat not between -34 and 6 or p_lon not between -75 and -28 then return false; end if;
  insert into public.localizacoes (user_id, lat, lon, atualizado_em) values (uid, p_lat, p_lon, now())
  on conflict (user_id) do update set lat = excluded.lat, lon = excluded.lon, atualizado_em = now()
    where public.localizacoes.atualizado_em < now() - interval '4 seconds';
  return true;
end $$;
revoke all on function public.minha_posicao(double precision, double precision) from public, anon;
grant execute on function public.minha_posicao(double precision, double precision) to authenticated;
