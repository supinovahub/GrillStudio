# GrillStudio

Plataforma de atendimento, qualificação, agendamento e acompanhamento comercial de leads imobiliários.

## Comece por aqui

1. Leia [`CONTEXT.md`](./CONTEXT.md) para conhecer a linguagem do domínio.
2. Leia [`docs/product/README-Pacote-Tecnico-v1.md`](./docs/product/README-Pacote-Tecnico-v1.md) para navegar pela especificação.
3. Leia os ADRs relevantes em [`docs/adr/`](./docs/adr/).
4. Siga [`AGENTS.md`](./AGENTS.md) e a configuração em [`docs/agents/`](./docs/agents/).

## Estado

A fundação executável inclui a PWA em Next.js 16, Auth SSR, o shell autenticado
da Operação, isolamento inicial por RLS, proteção de ambiente e observabilidade
básica. Modo produção nasce desligado.

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

## Aplicação

Use Node.js 22 e instale as dependências bloqueadas:

```bash
corepack enable
pnpm install --frozen-lockfile
```

O app só inicia quando as variáveis de identidade e as credenciais públicas
apontam de forma inequívoca para a Preview Branch do PR. Copie apenas os nomes
de [`.env.example`](./.env.example); os valores são injetados pelo orquestrador
e nunca são versionados. E-mails de recuperação só saem para endereços
explicitamente presentes em `PREVIEW_AUTH_EMAIL_ALLOWLIST`.

```bash
pnpm dev
```

Checks sem credenciais:

```bash
pnpm lint
pnpm typecheck
pnpm test:unit
```

O verificador externo aguarda `Supabase Preview` no SHA, resolve credenciais
efêmeras daquela branch, executa `build` e `test:blackbox` com fixtures
sintéticas e publica `Agent verified`. Não há fallback para o projeto principal
nem para Supabase local.
