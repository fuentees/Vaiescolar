# Checklist de producao do VaiEscolar

## Publicacao

- Executar `npm ci`, `npm test` e `npm run migrate` em ambiente controlado.
- Configurar `DATABASE_URL`, `JWT_SECRET`, `PAYMENT_ENCRYPTION_KEY` e credenciais Firebase como segredos.
- Definir `PUBLIC_BASE_URL` com HTTPS e `CORS_ORIGIN` somente com os dominios web autorizados.
- Manter `/health` monitorado e alertar para HTTP diferente de 200, pool aguardando ou manutencao falha.

## Banco e recuperacao

- Ativar backups automaticos do provedor e conservar ao menos 30 dias.
- Gerar um `pg_dump` semanal adicional em armazenamento privado e criptografado.
- Verificar o arquivo com `npm run backup:verify -- backup.sql`.
- A cada trimestre, restaurar em um banco temporario e executar os testes de jornada completa.
- Nunca armazenar backup, `.env`, chave Firebase ou token de pagamento no Git.

## Capacidade

- Homologar primeiro com `LOAD_CONCURRENCY=20 LOAD_REQUESTS_PER_SECOND=20 LOAD_DURATION_SECONDS=60 npm run load:test`.
- Repetir com 50 e 100 conexoes apenas fora do horario de uso.
- Considerar aprovado quando erros forem inferiores a 1%, p95 estiver dentro da meta e o pool nao acumular espera.
- Aumentar `DB_POOL_MAX` somente respeitando o limite total de conexoes do banco dividido pelas instancias do servidor.

## Pagamentos

- Usar credenciais de sandbox antes de producao.
- Criar uma cobranca de valor minimo, confirmar webhook e conferir idempotencia.
- A ativacao deve depender da consulta autenticada ao provedor, nunca apenas do corpo recebido no webhook.
- Registrar estorno, atraso, cancelamento e conciliacao manual.

## Aplicativos

- Testar Android 10, 12, 13, 14 e 15, inclusive bateria restrita e app encerrado.
- Validar login, permissoes, GPS em segundo plano, push com som, chat, falta, emergencia, contrato e atualizacao.
- Publicar AAB assinado pela Play Console; atualizacao interna serve apenas como aviso/facilitador.

## LGPD e operacao

- Publicar politica de privacidade e termos revisados por profissional juridico brasileiro.
- Coletar apenas dados necessarios, registrar consentimento e disponibilizar canal do titular.
- Definir responsavel por incidentes, suporte, exclusao/exportacao e comunicacao aos clientes.
- Formalizar operador/controlador e fornecedores (Supabase, Render, Google/Firebase e gateway).
