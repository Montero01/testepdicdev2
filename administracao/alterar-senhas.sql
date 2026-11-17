-- MODELOS ADMINISTRATIVOS. NÃO EXECUTADOS NESTA ENTREGA.
-- Execute somente no SQL Editor do seu próprio Supabase, como postgres.
-- Substitua os e-mails e escolha senhas temporárias diferentes para cada pessoa.
-- Este método direto não aplica todas as políticas do Supabase Auth nem revoga
-- sessões existentes. O fluxo Auth/Admin API é preferível na operação normal.
-- As senhas digitadas podem permanecer no histórico de consultas do SQL Editor.
-- pgcrypto foi verificado no schema extensions deste projeto.

-- 1) UMA CONTA
update auth.users
set encrypted_password = extensions.crypt(
      'SUBSTITUA_POR_SENHA_TEMPORARIA_UNICA',
      extensions.gen_salt('bf', 12)
    ),
    updated_at = now()
where lower(email) = lower('colaborador@exemplo.invalid')
returning id, email;

-- 2) VÁRIAS CONTAS, COM SENHAS DIFERENTES
with novas_senhas(email, senha) as (
  values
    ('pessoa1@exemplo.invalid', 'SUBSTITUA_POR_SENHA_UNICA_DA_PESSOA_1'),
    ('pessoa2@exemplo.invalid', 'SUBSTITUA_POR_SENHA_UNICA_DA_PESSOA_2')
)
update auth.users as usuario
set encrypted_password = extensions.crypt(
      novas_senhas.senha,
      extensions.gen_salt('bf', 12)
    ),
    updated_at = now()
from novas_senhas
where lower(usuario.email) = lower(novas_senhas.email)
returning usuario.id, usuario.email;

-- Confira os e-mails retornados: nenhuma linha significa conta não encontrada.
-- Depois, cada pessoa pode definir sua própria senha em Meu perfil → Trocar senha.
-- Não inclua esses comandos nem senhas administrativas em JavaScript público.
