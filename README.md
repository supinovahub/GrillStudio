# GrillStudio

Plataforma de atendimento, qualificação, agendamento e acompanhamento comercial de leads imobiliários.

## Comece por aqui

1. Leia [`CONTEXT.md`](./CONTEXT.md) para conhecer a linguagem do domínio.
2. Leia [`docs/product/README-Pacote-Tecnico-v1.md`](./docs/product/README-Pacote-Tecnico-v1.md) para navegar pela especificação.
3. Leia os ADRs relevantes em [`docs/adr/`](./docs/adr/).
4. Siga [`AGENTS.md`](./AGENTS.md) e a configuração em [`docs/agents/`](./docs/agents/).

## Estado

O repositório contém a fundação documental e as skills de engenharia. A implementação da aplicação ainda não começou.

## Ambientes e execução por agentes

O projeto usa uma Preview Branch Supabase efêmera por pull request; não existe dependência de Supabase local. Leia [`docs/agents/cloud-preview-workflow.md`](./docs/agents/cloud-preview-workflow.md).

Para inspecionar a próxima onda sem alterar nada:

```bash
node scripts/run-waves.mjs
```

Depois que GitHub, checks obrigatórios e integração Supabase estiverem configurados, o operador pode iniciar as ondas:

```bash
node scripts/run-waves.mjs --run --max=3
```
