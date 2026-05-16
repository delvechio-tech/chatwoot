# Chatwoot + Quepasa nativo

Este fork inclui um provedor nativo de WhatsApp via Quepasa. Para que a instalação funcione de forma previsível em produção, use:

- `deployment/portainer-stack-quepasa-service.example.yml` para o serviço Quepasa
- `deployment/portainer-stack-quepasa.example.yml` para o Chatwoot

e mantenha os pontos abaixo.

## Requisitos obrigatórios

- `QUEPASA_API_URL`
- `QUEPASA_MASTER_KEY`
- `QUEPASA_USER`
- `QUEPASA_PASSWORD`
- `FRONTEND_URL`
- Postgres, Redis e volumes persistentes do Chatwoot

`QUEPASA_API_URL` não possui fallback implícito. Isso evita que uma instalação nova tente conversar com um domínio privado de outra instalação por engano.

## Boas práticas adotadas neste fork

- Eventos recebidos do Quepasa são processados na fila `high`, para que mensagens de WhatsApp não aguardem atrás de tarefas de baixa prioridade.
- `read_sync` fica desativado por padrão. Algumas sessões do WhatsApp podem responder com conflitos de estado ao marcar mensagens como lidas automaticamente; ative esse recurso apenas depois de validar o comportamento da sua conta.
- Não monte `/app/public` como volume. Esse caminho contém assets gerados pela imagem; sobrescrevê-lo com um volume antigo pode esconder a interface nativa do Quepasa.
- Use uma versão pinada e testada do Quepasa. O exemplo oficial usa o digest compatível validado com este fork, em vez de depender de `latest` puro.
- Para produção, mantenha o Sidekiq com folga de recurso suficiente. A stack de exemplo recomenda `2 CPU / 2048 MB` para o worker.

## Checklist pós-deploy

1. Abra a tela de criação de inbox do WhatsApp e confirme que a opção **WhatsApp API** aparece.
2. Crie a inbox e gere o QR Code.
3. No Quepasa, confirme que o bot aparece como `Ready`.
4. Envie uma mensagem real pelo WhatsApp.
5. Confirme que:
   - o webhook foi entregue ao Chatwoot;
   - a conversa apareceu em poucos segundos;
   - as mensagens mantiveram a ordem correta.

## Erros comuns

### A opção `WhatsApp API` não aparece no Chatwoot

Verifique se a stack monta `/app/public`. Se montar, remova esse volume e atualize os serviços `chatwoot_app` e `chatwoot_sidekiq`.

### `username validation: sql: no rows in result set`

Configure explicitamente `QUEPASA_USER` e `QUEPASA_PASSWORD` na stack do Chatwoot. O usuário precisa existir ou ser criado automaticamente pelo Quepasa com a `MASTERKEY` configurada.

### `table servers has no column named metadata`

Esse erro costuma indicar banco antigo/incompatível do Quepasa. Em uma instalação nova, recrie o volume/banco do Quepasa antes de subir uma versão compatível.

### Mensagens demoram a aparecer no Chatwoot

Confirme que a imagem em uso contém este fork atualizado. Neste projeto, os eventos do Quepasa rodam na fila `high`; versões antigas processavam esses eventos na fila `low`, o que podia gerar atraso e mensagens fora de ritmo.
