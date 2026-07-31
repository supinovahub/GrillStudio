# T02 — Convites, aprovação e autorização de Membros

## Fronteiras de autorização

- `memberships.role` mantém o papel primário usado pelo shell; papéis
  cumulativos ficam normalizados em `membership_roles`.
- permissões administrativas de Gestor ficam em `membership_permissions`.
  Dono possui a autoridade definida pela especificação; Gestor só recebe cada
  permissão por concessão explícita.
- `manage_members` permite ao Gestor convidar, aprovar e desativar somente
  Corretores. As RPCs recusam criação ou aprovação de Gestor, alteração de
  permissões administrativas e qualquer ação sobre o Dono.
- cadastros de convite entram em `memberships.status = 'pending'`, sem papel
  concedido. Confirmação de e-mail e aprovação são portões distintos.
- o navegador não recebe privilégios de escrita nas tabelas. Mutações passam
  por RPCs estreitas, auditadas e com `search_path` fixado.

## Convites

Convites individuais registram e-mail e papéis predefinidos, mas nunca ativam
acesso. O link geral cria Membro pendente sem papel. Pausar o link impede novas
reservas; regenerar marca o token anterior como `replaced` antes de emitir o
novo endereço.

Na Preview Branch, o cadastro Auth respeita
`PREVIEW_AUTH_EMAIL_ALLOWLIST`. O e-mail é o único egresso possível dessa
superfície e continua restrito a identidades sintéticas/allowlisted. A reserva
do convite aplica limite por hash de origem, e o hash e o token não entram em
logs de aplicação.

## Desativação

A ação de servidor confirma novamente a senha do Dono ou Gestor antes de usar a
RPC disponível apenas ao `service_role` efêmero da Preview Branch. A transação:

1. revoga a membership e a elegibilidade para Ofertas de call;
2. encerra Ofertas pendentes;
3. devolve Calls futuras à distribuição e revoga a Atribuição de call;
4. deixa Oportunidades de negociação em diante sem responsável;
5. remove permissões administrativas;
6. apaga as sessões Auth e seus refresh tokens por cascata;
7. grava contagens, ator, rastreio e confirmação recente na auditoria.

Antes da senha, a interface mostra Calls futuras, Calls em menos de uma hora e
Oportunidades que ficarão sem responsável. Nenhum registro recebe substituto
aleatório.

## Validação

O black-box usa somente a Preview Branch do PR e identidades `@example.com`.
Ele cobre o fluxo público, a fronteira Auth/Data API, papéis cumulativos,
limites do Gestor, RLS negativa, revogação de sessões, impacto de desativação,
elegibilidade de Oferta de call e auditoria. As tabelas estreitas de
Oportunidade e Call criadas nesta fatia existem apenas para sustentar o
contrato de desativação; as fatias T04 e T21 as estendem.
