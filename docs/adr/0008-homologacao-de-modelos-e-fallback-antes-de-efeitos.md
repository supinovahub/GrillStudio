---
status: accepted
---

# Homologar perfis de modelo e limitar fallback à fronteira sem efeitos

O GrillStudio aprova um perfil imutável composto por modelo, parâmetros,
instruções, schemas e ferramentas, não um identificador de modelo isolado.
Modelos novos começam no simulador e só entram na allowlist de produção depois
de compatibilidade estrita, regressão sintética, avaliação humana em sombra ou
assistido e gates de qualidade, segurança, latência e custo.

`gpt-5.6-sol` permanece o candidato primário previsto, `gpt-5.6-terra` é o
candidato inicial a fallback e desafiante de custo/latência, e
`gpt-5.6-luna` começa restrito a tarefas auxiliares. Capacidade documentada não
equivale a homologação; nenhum perfil está aprovado até os testes live.

Fallback automático só pode ocorrer entre perfis aprovados para o mesmo
contrato, em falha transitória classificada e enquanto a fase persistida ainda
for `prepared` ou `request_started`. `model_buffered` é o cutoff: depois da
resposta completa não há troca automática de modelo. Falha estrutural,
semântica, de segurança, autenticação, recusa, efeito incerto ou resposta
parcial pausa ou reconcilia a conversa. Depois de um efeito, a retomada
continua do resultado persistido e nunca repete o turno inteiro.

Essa decisão aumenta o trabalho de avaliação e versionamento, mas impede
duplicidade de efeitos, drift silencioso por alias e troca de modelo que
mascare falhas de contrato. O contrato completo, matriz e gates estão em
[`Contrato de homologação e fallback de modelos OpenAI`](../research/openai-model-homologation-contract.md).
