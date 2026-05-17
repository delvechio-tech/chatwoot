# Release 1.0.0 — Chatwoot com Quepasa nativo

## Compatibilidade homologada

| Componente | Versão |
| --- | --- |
| Chatwoot | `delvechiotech/chatwoot:1.0.0` |
| Quepasa | `v3.26.0427.1756` |
| Imagem Quepasa validada | `codeleaks/quepasa:latest@sha256:f156fc4fc774600be19cec4cc3d9c7c36a50d7968f5670e12cc82378e056382d` |

## O que esta release entrega

- Provedor nativo do Quepasa disponível dentro do fluxo de criação de inbox WhatsApp.
- Processamento de eventos do Quepasa na fila `high`, reduzindo atraso de entrada.
- `read_sync` desativado por padrão para evitar conflitos de sincronização observados em produção.
- Stack de exemplo segura para Portainer/Swarm:
  - sem volume em `/app/public`
  - com credenciais obrigatórias do Quepasa explícitas
  - com recursos recomendados para Sidekiq
- Documentação de instalação e troubleshooting pronta para uso por terceiros.

## Regras de instalação

1. Use `delvechiotech/chatwoot:1.0.0`.
2. Use o Quepasa homologado `v3.26.0427.1756`.
3. Não use `codeleaks/quepasa:latest` sem digest em produção.
4. Não monte `/app/public` no Chatwoot.
5. Configure obrigatoriamente:
   - `QUEPASA_API_URL`
   - `QUEPASA_MASTER_KEY`
   - `QUEPASA_USER`
   - `QUEPASA_PASSWORD`

## Checklist rápido de aceite

1. A opção **WhatsApp API** aparece no Chatwoot.
2. O QR Code é gerado.
3. O bot aparece como `Ready` no Quepasa.
4. Uma mensagem real do celular entra no Chatwoot em poucos segundos.
5. Uma resposta enviada pelo Chatwoot chega ao celular corretamente.
6. As mensagens permanecem em ordem.

## Observação importante

Se uma instalação já possuía inboxes antigos antes da release `1.0.0`, a mudança de padrão para `read_sync: false` não altera automaticamente registros já existentes. Esses inboxes precisam ser ajustados explicitamente uma vez.
