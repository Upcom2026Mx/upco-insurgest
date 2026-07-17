-- Upco InsurGest — Segundo factor (TOTP) para agentes y promotorías, exigido en la BASE
-- Pegar completo en Supabase > SQL Editor > New query > Run
--
-- POR QUÉ ESTO Y NO SOLO UNA PANTALLA:
-- Si el segundo factor solo vive en la pantalla de la app, no sirve de nada: quien tenga el correo
-- y la contraseña puede hablarle directo a la API de Supabase, saltarse mi pantalla, y traerse los
-- datos igual. El 2FA de verdad exige que la BASE rechace cualquier sesión que no haya pasado el
-- segundo factor. Eso es lo que hace este archivo.
--
-- CÓMO, SIN TOCAR LAS 18 POLÍTICAS QUE YA EXISTEN:
-- Postgres permite políticas RESTRICTIVAS, que se suman con AND a las permisivas. Así que basta
-- una por tabla: las reglas de "cada agente ve lo suyo" quedan intactas y encima se exige el aal2.
--
-- QUIEN NO TIENE 2FA ACTIVADO NO SE ENTERA: la función deja pasar aal1 si el usuario no tiene
-- ningún factor verificado. O sea, correr esto hoy no bloquea a nadie.

-- aal = Authenticator Assurance Level. aal1 = entró con contraseña. aal2 = además pasó el TOTP.
-- Lee auth.mfa_factors, que un usuario normal no puede consultar — por eso security definer.
create or replace function public.mfa_ok() returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select case
    when exists (
      select 1 from auth.mfa_factors f
      where f.user_id = (select auth.uid()) and f.status = 'verified'
    )
    then coalesce((select auth.jwt()->>'aal'), 'aal1') = 'aal2'
    else true
  end;
$$;
grant execute on function public.mfa_ok() to authenticated;

-- Una por tabla. `to authenticated` es importante: deja fuera a anon, así el portal del cliente
-- (que es anónimo y pasa por funciones security definer) sigue funcionando igual.
create policy "exige 2fa cuando esta activado" on agentes
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

create policy "exige 2fa cuando esta activado" on promotorias
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

create policy "exige 2fa cuando esta activado" on clientes
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

create policy "exige 2fa cuando esta activado" on polizas
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

create policy "exige 2fa cuando esta activado" on vehiculos
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

create policy "exige 2fa cuando esta activado" on solicitudes
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

create policy "exige 2fa cuando esta activado" on solicitudes_servicio
  as restrictive for all to authenticated
  using (public.mfa_ok()) with check (public.mfa_ok());

-- Los PDFs de pólizas y las fotos de solicitudes también son datos de clientes: si la tabla queda
-- protegida pero el archivo no, el candado se brinca por Storage.
create policy "exige 2fa cuando esta activado en storage"
  on storage.objects
  as restrictive for all to authenticated
  using (bucket_id not in ('polizas','solicitudes') or public.mfa_ok())
  with check (bucket_id not in ('polizas','solicitudes') or public.mfa_ok());
