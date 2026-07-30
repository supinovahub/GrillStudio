# Mapa de Telas v1

## 1. Princípios de navegação

- Dono e gestor começam pela Central da operação.
- Corretor começa por Hoje.
- Inbox, Kanban e Agenda são diferentes visões das mesmas entidades, não bases separadas.
- A interface sempre mostra quem controla a conversa: Pedro, humano, aguardando ou pausado.
- Ações perigosas mostram impacto, prévia e confirmação.
- Configuração distingue rascunho, versão publicada e versão usada pela conversa.
- Busca respeita RLS e o escopo do usuário.

## 2. Árvore de rotas

```text
/
├── entrar
├── recuperar-senha
├── convite/[token]
├── aguardando-aprovacao
└── app
    ├── central
    ├── atendimentos
    │   └── [conversationId]
    ├── kanban
    ├── agenda
    │   └── calls/[callId]
    ├── campanhas
    │   ├── nova
    │   └── [campaignId]
    ├── leads
    │   ├── importar
    │   └── [opportunityId]
    ├── empreendimentos
    │   ├── novo
    │   └── [projectId]
    ├── pedro
    │   ├── personas
    │   │   ├── nova
    │   │   └── [personaId]
    │   ├── qualificacao
    │   ├── faqs
    │   ├── aprendizados
    │   ├── simulador
    │   ├── testes
    │   ├── experimentos
    │   └── modelos
    ├── relatorios
    ├── alertas
    ├── busca
    ├── hoje
    ├── meu-pipeline
    ├── perfil
    └── configuracoes
        ├── imobiliaria
        ├── equipe
        ├── papeis
        ├── whatsapp
        ├── meta
        ├── agenda
        ├── notificacoes
        ├── ia-e-orcamento
        ├── auditoria
        └── sistema
```

Rotas são conceituais. No código, route groups podem separar auth, app e papéis sem aparecer na URL.

## 3. Navegação por papel

### Dono/gestor — desktop

1. Central
2. Atendimentos
3. Kanban
4. Agenda
5. Campanhas
6. Leads
7. Empreendimentos
8. Pedro
9. Relatórios
10. Configurações

### Dono/gestor — celular

- Central
- Atendimentos
- Kanban
- Agenda
- Mais

### Corretor — desktop/celular

- Hoje
- Agenda
- Meu pipeline
- Atendimentos atribuídos
- Perfil

O backend continua autorizando cada recurso; esconder um item do menu não é controle de acesso.

## 4. Shell global

### Barra lateral/topo

- organização atual;
- busca global;
- saúde resumida;
- central de alertas;
- perfil;
- indicação inequívoca de ambiente local, piloto controlado ou produção;
- estado global do Pedro;
- kill switch acessível conforme permissão.

### Busca

Campos:

- nome;
- telefone;
- e-mail;
- ID da oportunidade;
- empreendimento;
- campanha.

Resultado mostra tipo, etapa, responsável e última interação. Não há comando em linguagem natural no MVP.

## 5. Central

### Usuários

Dono e gestor.

### Objetivo

Responder “o que precisa de mim agora?”.

### Seções

1. **Crítico agora**
   - call próxima sem corretor;
   - horário chegou sem corretor;
   - lead relata corretor ausente;
   - link pendente;
   - erro crítico do Pedro.
2. **Precisa de ação**
   - escalonamentos silenciosos;
   - resultado da call ausente;
   - conflito de aprendizado;
   - campanha aguardando aprovação.
3. **Acompanhar**
   - fila, jobs atrasados, conectores degradados;
   - conversas dormindo;
   - orçamento.
4. **Pedro e capacidade**
   - estado;
   - ativas/meta/teto;
   - aguardando;
   - pausa automática;
   - entrada normal habilitada?
5. **Resumo do dia**
   - novos leads;
   - qualificações;
   - calls agendadas/realizadas;
   - respostas humanas;
   - campanhas.

Cada item exibe lead, motivo, tempo de espera, responsável, última mensagem e ação principal.

### Estados

- normal;
- atenção;
- crítico;
- sem dados;
- dados atrasados;
- erro parcial de uma integração.

## 6. Atendimentos

### Desktop

Três painéis:

1. lista e filtros;
2. conversa;
3. contexto operacional.

### Lista

- nome/telefone;
- última mensagem;
- espera;
- origem;
- ownership;
- modo;
- etapa;
- alerta;
- tags.

Filtros: estado, origem, responsável, número, campanha, alerta, etapa, modo e SLA.

### Conversa

- mensagens e anexos;
- status de entrega;
- indicador de mensagem proposta/aprovada;
- versão de persona/modelo;
- assumir;
- devolver ao Pedro;
- pausar;
- abrir simulador a partir de uma mensagem;
- marcar resposta e fazer observação;
- escalar;
- enviar mídia permitida.

Ao devolver ao Pedro, modal obrigatório:

- retomar atendimento;
- entrar em follow-up;
- manter aguardando;
- encerrar/perder, se permitido.

### Contexto

Abas:

- resumo;
- qualificação;
- origem/Meta;
- empreendimento e materiais;
- call;
- follow-up;
- ownership e acessos;
- histórico de etapas;
- auditoria útil.

### Mobile

Lista, conversa e contexto são telas separadas. O cabeçalho da conversa mantém ownership e ação de assumir visíveis.

## 7. Kanban

Colunas:

1. Novo lead
2. Em atendimento
3. Call agendada
4. Em negociação
5. Proposta feita
6. Documentação
7. Pagamento
8. Comprado
9. Perdido

Card:

- nome;
- origem;
- tempo na etapa;
- responsável;
- próxima ação;
- call;
- qualificação resumida;
- alerta;
- ownership.

Regras de UI:

- drag-and-drop não contorna validações;
- resultado da call abre formulário próprio;
- mover para perdido pede motivo;
- comprado pede dados da venda, com mês/ano;
- Pedro só movimenta as três primeiras transições autorizadas;
- filtros e agrupamentos não alteram o pipeline.

## 8. Agenda e call

### Agenda

- dia/semana;
- disponibilidade;
- bloqueios;
- calls sem corretor;
- filtro por profissional;
- zona de tempo visível;
- bloco de 20 minutos + 10 de intervalo.

### Detalhe da call

- lead e horário;
- formato;
- status de atribuição;
- corretor;
- rodada de distribuição;
- ofertas e prazos;
- briefing;
- link de vídeo;
- lembretes;
- histórico;
- ação manual de atribuir/reagendar.

Antes do aceite, o corretor recebe no WhatsApp apenas data e horário. Depois do aceite, detalhes aparecem no dashboard, não no WhatsApp.

### Hoje do corretor

1. próxima call com contagem regressiva;
2. formato e link;
3. briefing;
4. chat/telefone liberado 30 minutos antes;
5. próximas calls;
6. resultados pendentes;
7. ações vencidas/hoje;
8. disponibilidade.

Depois do horário, CTA: **Informar resultado da call**.

### Resultado

- iniciar negociação;
- perdido + motivo;
- no-show;
- sem resultado informado.

Iniciar negociação e sem resultado geram visibilidade/alerta ao gestor.

## 9. Campanhas

### Lista

- status;
- número usado;
- persona/modo;
- total;
- enviados;
- respostas;
- opt-outs;
- escalonamentos;
- erro;
- próxima onda.

### Assistente de criação

1. objetivo e nome;
2. importar CSV;
3. mapear colunas;
4. revisar erros/duplicidades;
5. confirmar consentimento;
6. selecionar número oficial ou não oficial ativo;
7. escolher persona e modo;
8. configurar ritmo/onda;
9. revisar mensagens dinâmicas;
10. revisão final por amostra;
11. habilitar IA naquela campanha;
12. confirmar início.

### Detalhe

- progresso;
- funil;
- fila;
- respostas;
- amostra revisada;
- erros;
- contatos suprimidos;
- pausar/retomar;
- liberar próxima onda;
- exportar.

Reativação está no MVP e é a primeira operação prevista, mas não ganha complexidade incompatível com o volume esporádico de até cerca de 500 leads.

## 10. Leads

### Lista

- filtros;
- seleção;
- exportação;
- tags;
- atribuição de gestor;
- inclusão/exclusão de campanha;
- pausa/liberação permitida.

Ações em massa proibidas não aparecem ou ficam explicadas: venda, pagamento, perder em massa, apagar contatos, enviar mensagem livre.

### Detalhe

- contato;
- oportunidades;
- telefones;
- participantes;
- origem;
- qualificação;
- conversa;
- call;
- pipeline;
- próximos passos;
- consentimento/supressão;
- histórico e fusão.

## 11. Empreendimentos

### Lista

- capa;
- nome;
- região;
- faixa de preço;
- faixa de entrada;
- status;
- validade;
- completude.

### Edição

Seções enxutas:

- identificação e resumo;
- localização;
- faixas financeiras;
- planta/pronto e disponibilidade;
- rentabilidade de locação;
- valorização;
- gestão de short stay;
- fonte, data e validade;
- capa, até imagens e PDF;
- FAQs específicas.

Cada campo tem ajuda com exemplo, diferença entre “fonte” e “validade” e indicação do que Pedro pode dizer. A tela deixa claro que o cadastro é um resumo para pré-atendimento, não o portal completo do corretor.

## 12. Pedro

### Personas

- versão ativa;
- rascunhos;
- clonar;
- criar nova identidade;
- entrevista guiada estilo grill-me;
- importar 10–30 conversas;
- sugestões de estilo;
- diff;
- testes;
- publicar/ativar conforme permissão.

Uma pergunta por vez, recomendação explícita, detecção de contradição e progresso por tópicos.

### Qualificação

Lista reordenável como a referência aprovada:

- título;
- contexto;
- tipo;
- essencial/complementar;
- obrigatória;
- aplicabilidade;
- validade.

Ação **Atualizar contexto da IA** compila e testa uma versão, em vez de fazer Pedro reler configuração mutável em toda mensagem.

### FAQs e regras

- globais e por empreendimento;
- busca;
- fonte/validade;
- campos dinâmicos;
- conflitos;
- rascunho/publicado;
- simular resposta.

### Aprendizados

- fila de sugestões;
- mensagem original;
- observação humana;
- regra sugerida;
- escopo;
- conflito;
- casos de regressão;
- aprovar/rejeitar/editar.

### Simulador e testes

- conversa isolada;
- estado/qualificação;
- resposta;
- ações propostas;
- regras/fontes usadas;
- modelo;
- latência/custo;
- corrigir e transformar em caso.

### Modelos

- catálogo por perfil com estados `documented`, `contract_passed`,
  `synthetic_passed`, `shadow_or_assisted`, `production_approved`,
  `quarantined` e `deprecated`;
- adicionar identificador para simulador, sem efeito e sem opção direta de
  produção;
- produção lista somente perfis homologados para o mesmo contrato;
- sombra e assistido exibem candidatos com seus gates pendentes;
- modelo primário aprovado e fallback secundário opcional também aprovado;
- capacidades, contexto, parâmetros, custo revisado em, p50/p95, última suíte e
  limitações;
- comparação de resposta, extração, ação, ferramenta, latência e custo;
- alias móvel bloqueado em produção;
- aviso e plano de troca quando um modelo for descontinuado;
- orçamento;
- confirmação exclusiva do dono para produção;
- histórico, rollback e auditoria de toda alteração.

### Experimentos

- variantes e proporção;
- elegibilidade;
- distribuição;
- métricas;
- resultado preliminar;
- erros críticos;
- pausar;
- encerrar/promover somente pelo dono.

## 13. Relatórios

Abas:

- funil e coortes;
- origem/Meta;
- campanhas;
- capacidade;
- autonomia;
- qualidade;
- calls e corretores;
- custos.

Toda métrica tem definição acessível. Conversão posterior não é misturada com desempenho de qualificação.

## 14. Configurações

### Imobiliária

Nome, CRECI, contato e dados institucionais que Pedro pode fornecer quando perguntado.

### Equipe e papéis

Convites, link geral, pendentes, aprovação, função, WhatsApp, disponibilidade, preferenciais e permissões.

### WhatsApp

Conexões Uazapi/Meta, número, saúde, inbound/campanha, teste e auditoria. Segredo inserido em formulário seguro e nunca reexibido.

### Meta

Conta, formulários, mapeamento, consentimento e status de webhook.

### Agenda

Timezone, regras, duração/intervalo, lembretes e distribuição.

### IA e orçamento

- chave de API;
- modelos permitidos;
- validação server-side com probe sintético, sem reexibir ou logar a chave;
- limites;
- botão **Habilitar IA em produção**;
- modos padrão;
- kill switch;
- custo.

### Auditoria

Filtros por usuário, sistema, IA, lead, campanha, versão e data.

## 15. Sistema visual

### Direção

- fundo branco-quente;
- texto quase preto;
- bordas e superfícies bege;
- laranja para ação relevante, alerta e estado;
- aparência premium e discreta;
- sem gradientes chamativos;
- sem excesso de cards;
- sem estética genérica de “produto de IA”.

### Densidade

- Central, Inbox e Kanban: compactos, escaneáveis;
- configuração e edição de persona: mais respiro;
- tabelas com cabeçalho fixo e filtros persistentes;
- detalhes progressivos, sem esconder estado crítico.

### Componentes de estado

- badge de ownership;
- badge de modo da IA;
- badge de saúde;
- relógio/SLA;
- trilha de versão;
- diff;
- confirmação com impacto;
- banner de ambiente local ou piloto;
- toast apenas como complemento; eventos importantes persistem.

## 16. Acessibilidade e responsividade

- navegação completa por teclado;
- foco visível;
- contraste AA;
- nome acessível em ícones;
- cor nunca é o único indicador;
- live regions para aceite de call e alerta crítico;
- modal com foco contido e retorno correto;
- tabelas viram listas estruturadas no mobile;
- áreas de toque adequadas;
- redução de movimento respeitada.

## 17. Estados que toda tela deve prever

- carregando;
- vazio;
- erro recuperável;
- sem permissão;
- conexão offline;
- dado desatualizado;
- ação concorrente vencida;
- recurso excluído/arquivado;
- processamento assíncrono;
- sucesso parcial.

## 18. Primeiras telas para protótipo

1. Central;
2. Inbox com contexto;
3. criação/revisão de campanha;
4. Agenda + distribuição;
5. Hoje do corretor;
6. Kanban;
7. Qualificação;
8. Empreendimento;
9. Simulador;
10. configuração de IA/produção.

Essas dez superfícies cobrem as decisões de maior risco antes de construir o restante.
