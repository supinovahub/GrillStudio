# GrillStudio

GrillStudio é o contexto de atendimento e operação comercial de leads imobiliários, desde a entrada pelo WhatsApp até a compra ou perda da oportunidade.

## Organização e equipe

**Imobiliária**:
A organização cliente que reúne pessoas, dados e uma ou mais operações comerciais isoladas.
_Evitar_: Conta, tenant, cliente

**Operação**:
A unidade de trabalho da imobiliária que compartilha números, capacidade, campanhas, agenda, leads e regras de atendimento.
_Evitar_: Workspace, equipe

**Membro**:
Uma pessoa com acesso aprovado à imobiliária e papel definido em pelo menos uma operação.
_Evitar_: Usuário da empresa, funcionário

**Dono**:
O membro com autoridade final sobre identidade, produção da IA, modelos e configurações sensíveis.
_Evitar_: Administrador, superusuário

**Gestor**:
O membro responsável pela operação, pelos escalonamentos e pela supervisão do Pedro e dos corretores.
_Evitar_: Supervisor, atendente humano

**Corretor**:
O membro que recebe calls, conduz negociação e registra o resultado comercial.
_Evitar_: Vendedor, SDR

## Pessoas e atendimento

**Contato**:
A pessoa identificada por seus dados próprios, independentemente de quantas intenções de compra tenha ao longo do tempo.
_Evitar_: Lead, cliente

**Oportunidade**:
Uma intenção de compra específica de um contato, acompanhada do início ao desfecho no pipeline.
_Evitar_: Contato, negócio

**Lead**:
A representação operacional de uma oportunidade ainda em andamento, usada principalmente na interface e na conversa cotidiana.
_Evitar_: Contato, quando a identidade da pessoa for o assunto

**Participante**:
Uma pessoa adicional envolvida na mesma oportunidade, como um co-comprador.
_Evitar_: Segundo lead

**Conversa**:
O atendimento mantido em um número de WhatsApp para uma oportunidade e uma identidade de atendimento.
_Evitar_: Chat, sessão

**Ownership**:
A responsabilidade atual por conduzir uma conversa, pertencente ao Pedro ou a um humano.
_Evitar_: Atribuição, quando o assunto não for a call

**Conversa ativa**:
Uma conversa que ocupa capacidade porque existe trabalho imediato do Pedro ou uma abordagem proativa recente.
_Evitar_: Lead ativo, oportunidade aberta

**Conversa dormindo**:
Uma conversa que deixou de ocupar capacidade após cinco minutos sem resposta do lead, mas permanece apta a retornar.
_Evitar_: Encerrada, perdida, inativa

**Devolução pendente**:
Uma conversa que um humano quer devolver ao Pedro, mas que continua sob responsabilidade humana até existir capacidade.
_Evitar_: Na fila, sem dono

**Escalonamento silencioso**:
A transferência da responsabilidade ao gestor sem informar ao lead que houve uma escalada.
_Evitar_: Transferência de atendimento, handoff

**Opt-out**:
O pedido do contato para não receber novas mensagens, que bloqueia abordagens automáticas até decisão humana explícita.
_Evitar_: Lead perdido, bloqueio

## Pedro e conhecimento

**Pedro**:
A identidade de atendimento que conversa, qualifica, faz follow-up e conduz o lead até o agendamento.
_Evitar_: Bot, assistente, modelo

**Persona**:
O conjunto aprovado de identidade, biografia e estilo usado por Pedro ou por outra identidade de atendimento.
_Evitar_: Prompt, agente

**Versão comportamental**:
Uma versão imutável da persona, do estilo, do roteiro e das perguntas atribuída à conversa.
_Evitar_: Contexto atual

**Versão factual**:
Uma versão imutável das regras críticas, FAQs, preços, disponibilidade e demais fatos válidos para a próxima resposta.
_Evitar_: Memória, base da IA

**Contexto publicado**:
O conjunto aprovado de versões comportamentais e factuais disponível para novos atendimentos.
_Evitar_: Prompt salvo, treinamento

**Aprendizado sugerido**:
Uma melhoria proposta a partir de observação humana ou de um padrão de escalonamento, ainda sem efeito até revisão e publicação.
_Evitar_: Aprendizado automático

**Modo sombra**:
O modo em que Pedro observa, extrai e propõe ações sem enviar mensagens.
_Evitar_: Desativado

**Modo assistido**:
O modo em que Pedro prepara respostas que dependem de aprovação humana antes do envio.
_Evitar_: Manual

**Modo produção**:
O modo em que Pedro pode responder autonomamente dentro das regras e do escopo explicitamente habilitado.
_Evitar_: Automático

## Qualificação e empreendimentos

**Critério de qualificação**:
Uma informação que deve ser descoberta ou confirmada para compreender o perfil e preparar a call.
_Evitar_: Pergunta, campo

**Valor de qualificação**:
O valor conhecido para um critério, acompanhado de origem, validade e eventual conflito.
_Evitar_: Resposta

**Qualificação completa**:
O estado em que todos os critérios obrigatórios e aplicáveis foram resolvidos.
_Evitar_: Lead qualificado

**Empreendimento**:
Um imóvel ou projeto resumidamente cadastrado para respostas curtas e curadoria antes da call.
_Evitar_: Produto, unidade

**Curadoria**:
A seleção opcional de um ou dois empreendimentos compatíveis com preço total e entrada do lead.
_Evitar_: Recomendação, oferta

**Material**:
Uma imagem ou PDF aprovado de um empreendimento que pode ser enviado ao lead.
_Evitar_: Anexo genérico

## Campanhas e follow-up

**Campanha de reativação**:
Uma abordagem controlada de contatos importados que ficaram sem resposta no atendimento anterior.
_Evitar_: Disparo, blast

**Onda**:
Um subconjunto aprovado de contatos liberado em conjunto dentro de uma campanha.
_Evitar_: Lote, batch

**Follow-up**:
Uma tentativa futura planejada para retomar uma oportunidade que ainda pode avançar.
_Evitar_: Cobrança, campanha

**Abordagem proativa**:
Uma mensagem iniciada pela operação, por campanha, reativação ou follow-up, sem nova mensagem imediata do lead.
_Evitar_: Inbound

**Inbound**:
Uma nova entrada ou resposta iniciada pelo lead.
_Evitar_: Retomada automática

**Alta demanda**:
O estado em que ações proativas ficam pausadas para preservar capacidade para inbound e conversas em andamento.
_Evitar_: Pedro desativado

## Calls e pipeline

**Call hold**:
A reserva provisória de data e horário escolhidos com o lead enquanto a operação busca um responsável.
_Evitar_: Call confirmada, agendamento

**Call**:
A conversa de vídeo ou telefone entre lead e corretor, com horário, formato e responsável definidos.
_Evitar_: Reunião, visita

**Oferta de call**:
O convite interno para um corretor ou gestor aceitar uma call em determinado horário.
_Evitar_: Agendamento, proposta

**Grupo preferencial**:
O conjunto de corretores e gestores que recebe primeiro todas as calls compatíveis com sua agenda.
_Evitar_: Fila VIP, corretor exclusivo

**Atribuição de call**:
O vínculo vencedor entre uma call e o primeiro profissional elegível que a aceitou ou foi escolhido pelo gestor.
_Evitar_: Ownership

**Briefing**:
O resumo operacional liberado ao profissional atribuído depois do aceite da call.
_Evitar_: Histórico completo, mensagem interna

**Etapa**:
A posição atual da oportunidade no pipeline comercial.
_Evitar_: Status, coluna

**Resultado da call**:
A decisão humana registrada depois do horário da call: iniciar negociação, perder, no-show ou deixar sem resultado.
_Evitar_: Etapa da call

**Próxima ação**:
Uma ação humana futura, com responsável e prazo, necessária para avançar uma oportunidade após a call.
_Evitar_: Follow-up do Pedro

**Venda**:
O desfecho confirmado em que a oportunidade chega à etapa Comprado, com valor e mês/ano registrados.
_Evitar_: Lead qualificado, negociação ganha

