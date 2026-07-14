# Passagem de contexto — Chatwoot e Quepasa

Atualizado em 14 de julho de 2026. Este documento permite retomar o projeto com Codex, Claude Code ou outro assistente sem depender do histórico do chat.

## Segurança e limites

- Não fazer deploy, push, merge, mudança de Portainer ou alteração no Quepasa sem autorização explícita do usuário.
- Não registrar neste repositório chaves de API, senhas, tokens, QR codes, segredos de webhook ou URLs assinadas.
- Uma chave de Portainer foi exposta em conversa anterior e deve ser rotacionada pelo responsável. Não está neste documento.
- `referencias_prints/` é material do usuário e permanece sem versionamento; não alterar nem incluir em commits.

## Estado dos worktrees

| Item | Estado |
| --- | --- |
| Repositório principal | `/Volumes/delvechioSSD/Chatwoot` |
| Branch principal | `main`, antes deste documento no commit `b7db76f` |
| Alteração de confiabilidade | `feat/quepasa-reliable-ingestion` |
| Worktree da alteração | `tmp/worktrees/quepasa-reliable-ingestion` |
| Último commit da alteração | `a0c107c docs: add quepasa reliability handoff` |
| Branding laranja transparente | worktree `tmp/worktrees/orange-transparent-brand`, commit `578e713`; não foi para produção |

Commits técnicos da alteração Quepasa:

- `8046857 feat(quepasa): persist inbound webhook events`
- `dd63917 fix(quepasa): keep durable queue independent of worker flag`
- `c43bd09 fix(dev): configure local postgres password`

Antes de mudar qualquer coisa na branch Quepasa, executar no worktree correspondente:

```bash
git status --short
git log --oneline -5
```

## Produção conhecida

- A stack Chatwoot é gerenciada manualmente pelo Portainer, sem deploy automático do Git.
- A imagem observada em produção foi `delvechiotech/chatwoot:1.0.4`.
- O Quepasa é uma integração customizada do fork; atualizações oficiais de Chatwoot ou Quepasa exigem portabilidade e validação dos patches locais.
- Existem dois clientes em produção e o objetivo é evitar perda de mensagens e desconexões.
- A VPS produtiva tem 2 vCPU e 8 GB RAM. Não há folga segura para uma segunda stack completa nela.

## Diagnóstico inicial da integração Quepasa

Fluxo de entrada original:

`webhook Quepasa -> controller -> Sidekiq high -> IncomingMessageQuepasaService`

Pontos positivos: validação de segredo, fila alta, transações e propagação de erros.

Riscos identificados:

- evento bruto não era persistido antes de chegar ao worker;
- deduplicação não era atômica;
- não havia ordenação por inbox;
- chamadas HTTP ao Quepasa não tinham timeout explícito;
- download de anexos podia falhar sem retry confiável;
- não havia monitoramento/reconexão proativa da sessão WhatsApp;
- não existiam specs específicos da integração.

O código não parecia desconectar WhatsApp ativamente, mas não monitorava nem recuperava sessões. Os dois episódios relatados precisam ser correlacionados com logs do Quepasa para identificar a causa real.

## Implementação já feita na branch Quepasa

1. Migração `20260714190000_create_quepasa_webhook_events.rb` cria a tabela durável `quepasa_webhook_events` com payload, status, tentativas, erro e agendamento de retry.
2. Modelo `QuepasaWebhookEvent` com estados `pending`, `processing`, `processed` e `failed`; possui deduplicação e recuperação de eventos abandonados.
3. O controller do webhook pode persistir antes de agendar o job.
4. `Webhooks::QuepasaEventsJob` processa eventos persistidos em ordem por inbox, impede ultrapassar evento ativo e aplica retry com backoff.
5. `Webhooks::QuepasaEventRecoveryJob` recupera pendências periodicamente.
6. `Whatsapp::QuepasaConnectionMonitorJob` verifica conexões a cada cinco minutos e registra alerta. Ele não reconecta automaticamente nesta primeira fase.
7. O cliente Quepasa usa timeout HTTP configurável.
8. O Compose local usa `POSTGRES_PASSWORD` vindo de `.env`, para viabilizar PostgreSQL local. Isso não altera stack remota existente.

Variáveis necessárias em web e Sidekiq quando houver deploy:

```env
QUEPASA_DURABLE_EVENTS_ENABLED=false
QUEPASA_HTTP_TIMEOUT=10
```

`QUEPASA_DURABLE_EVENTS_ENABLED` é global na versão atual. Com `false`, o fluxo legado continua. Não ativar para os dois clientes simultaneamente. Antes de rollout produtivo, implementar e testar ativação explícita por inbox.

## Validação local concluída

Docker Desktop foi instalado no Mac. No worktree Quepasa, foram executados:

```text
docker compose up -d postgres redis
docker compose build base
docker compose run --rm base bundle exec rails db:prepare
docker compose run --rm base bundle exec rspec \
  spec/models/quepasa_webhook_event_spec.rb \
  spec/jobs/webhooks/quepasa_events_job_spec.rb
```

Resultado:

- imagem `chatwoot:development` construída;
- banco `chatwoot_test` criado;
- migração durável aplicada;
- `6 examples, 0 failures`;
- sintaxe Ruby, YAML e `git diff --check` aprovados anteriormente.

A primeira montagem levou cerca de 15 minutos porque compilou 369 gems Ruby, incluindo extensões nativas, e instalou 1.045 pacotes Node. O cache Docker está presente, portanto execuções futuras tendem a ser mais rápidas.

## O que ainda falta validar

- fluxo ponta a ponta com sessão Quepasa e WhatsApp de teste reais;
- payloads da versão Quepasa instalada;
- anexos que falham no download e retry;
- recuperação real de uma sessão WhatsApp desconectada;
- carga, métricas e alertas;
- rollout e rollback em ambiente semelhante à produção.

Conclusão: a alteração está pronta para **homologação controlada**, não está aprovada para produção.

## Próximo passo: VPS de homologação Hostinger

O usuário possui uma VPS Hostinger com n8n existente. Dados mostrados em print: Ubuntu 24.04, 2 vCPU, 8 GB RAM e 100 GB de disco. Essa configuração permite instalar Portainer, mas não garante capacidade para Chatwoot de homologação junto ao n8n; medir consumo real é obrigatório.

Ordem segura:

1. Obter acesso SSH root por chave já configurada e fazer auditoria somente de leitura: Docker, contêineres, CPU/RAM/disco, portas e proxy/rede usados pelo n8n.
2. Criar snapshot/backup manual na Hostinger antes de instalar componentes.
3. Instalar Portainer separado, protegido em HTTPS e sem expor Docker por TCP. Não alterar nem reiniciar o n8n.
4. Criar stack isolada de homologação: Chatwoot, PostgreSQL e Redis próprios; nunca usar banco ou Redis de produção.
5. Usar sessão Quepasa e número WhatsApp de teste, não números dos clientes.
6. Adicionar ativação por inbox antes de habilitar a fila durável em qualquer produção.
7. Testar texto, mídia, duplicidade, restart de Sidekiq, falha temporária Quepasa e atraso no worker.
8. Em produção, se autorizado: deploy primeiro com a flag durável em `false`; validar saúde. Só depois ativar um inbox de teste e observar; rollback é voltar a flag para `false`.

## Instrução para o próximo agente

1. Leia este documento e `AGENTS.md` inteiros.
2. Não misture a branch Quepasa com os worktrees de branding.
3. Não faça instalação, alteração remota, push, merge ou deploy sem confirmação explícita.
4. Para acesso a Portainer ou Hostinger, use uma credencial atual fornecida por canal seguro; nunca reutilize segredo enviado em chat anterior.
