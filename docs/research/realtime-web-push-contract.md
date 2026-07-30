# Contrato de Realtime e Web Push do PWA

Status: decisão técnica para o protótipo do ticket #5, sem implementação
completa, credenciais, dados reais ou promessa de entrega.

Data da pesquisa: 2026-07-30.

## 1. Decisão executiva

O GrillStudio deve tratar **banco, Realtime e Web Push como três camadas com
responsabilidades diferentes**:

1. Postgres guarda o estado canônico, inclusive alertas, destinatários,
   tentativas, leitura e resolução;
2. Supabase Realtime invalida ou atualiza rapidamente telas que estão
   conectadas;
3. Web Push chama a atenção fora da página por meio do push service do
   navegador, de um Service Worker e de uma notificação do sistema.

Realtime não é um substituto de push: ele depende de WebSocket e de um cliente
conectado. Supabase documenta que suspensão no celular e throttling em
background podem parar os heartbeats e desconectar silenciosamente a
aplicação. Um Web Worker reduz o problema, mas não impede que o sistema
operacional suspenda ou descarte a página. Fontes:
[background e heartbeat do Realtime][supabase-background],
[heartbeats][supabase-heartbeat] e
[Page Lifecycle do Chrome][chrome-page-lifecycle].

Push não é um substituto do banco nem um mecanismo confiável de sincronização:
um HTTP `201` do push service informa apenas que a mensagem foi aceita, não
entregue; o serviço pode reter por menos tempo que o TTL solicitado, encerrar
retries antes do TTL ou expirar a subscription. A Apple também afirma
expressamente que notificações remotas não têm entrega garantida. Fontes:
[RFC 8030, envio e TTL][rfc-web-push],
[User Notifications da Apple][apple-user-notifications] e
[tempo de vida no FCM][fcm-lifespan].

Portanto:

- tela ativa usa Realtime e consulta o banco quando houver lacuna;
- ao entrar em `hidden`, ao reconectar, ao recuperar uma página congelada ou
  ao abrir o PWA, a aplicação busca novamente o estado canônico;
- alertas normais, inclusive `Acompanhar`, persistem na plataforma e também
  geram push;
- `Precisa de ação` e `Crítico agora` seguem a mesma base durável e também
  geram push;
- WhatsApp para dono/gestor fica restrito aos riscos imediatos de call já
  aprovados, sem link; push negado ou perdido não amplia essa lista;
- nenhum alerta crítico pode existir somente como toast, evento Realtime ou
  notificação do sistema.

Para mudanças de banco, o alvo de produção é **Broadcast privado disparado no
banco**, com payload mínimo de invalidação. Supabase recomenda Broadcast para
escalabilidade e segurança; Postgres Changes é a alternativa mais simples para
teste e baixo volume. O replay de Broadcast não entra como garantia: está em
Public Alpha, cobre somente Broadcast from Database em canal privado, no
máximo 25 mensagens por chamada e retenção de pelo menos 72 horas. Fontes:
[subscribing to database changes][supabase-subscribe-changes],
[Broadcast e replay][supabase-broadcast] e
[estado Public Alpha][supabase-replay-stage].

## 2. Fatos de plataforma e implicações

### 2.1 Supabase Realtime

Realtime entrega Broadcast, Presence e Postgres Changes por WebSocket para
clientes conectados. Broadcast from Database grava em `realtime.messages`,
segue o WAL e transmite JSON aos sockets; a tabela é particionada e não é o
registro canônico do produto. Fontes:
[visão geral][supabase-realtime],
[arquitetura][supabase-architecture] e
[Broadcast][supabase-broadcast].

Contrato GrillStudio:

- usar canais privados e RLS por operação/destinatário;
- publicar `notification_id`, `event_id`, tipo, ID do agregado, versão e
  `occurred_at`, não a entidade inteira;
- não colocar conteúdo sensível, telefone, credencial ou endpoint de push no
  evento;
- não criar nem alterar objetos no schema `realtime`; desde Realtime 2.112.7,
  Supabase bloqueia essas mutações e permite somente administrar as policies
  RLS necessárias em `realtime.messages`;
- usar `SUBSCRIBED`, `CHANNEL_ERROR`, `TIMED_OUT` e heartbeat como telemetria,
  não como confirmação de que a tela processou cada evento;
- atualizar o JWT no canal; sem token novo, o cliente é desconectado quando o
  JWT expira;
- em erro, reconectar com backoff e então consultar notificações não lidas e
  entidades alteradas desde o último cursor confirmado.

Supabase documenta reconexão exponencial do cliente JavaScript e erros de
canal, além de limites que podem desconectar clientes. Um ACK de Broadcast
confirma que **o servidor Realtime recebeu o envio**, não que todos os
assinantes o aplicaram. Fontes:
[protocolo e reconexão][supabase-protocol],
[subscribe][supabase-js-subscribe],
[autorização][supabase-authorization],
[lockdown do schema Realtime][supabase-realtime-lockdown],
[limites][supabase-limits] e
[ACK de Broadcast][supabase-broadcast].

Mesmo com replay habilitado, o retorno limitado pode não cobrir uma janela de
desconexão com muitos eventos. Ao conectar sem replay, o slot temporário não
reproduz histórico. Por isso, replay pode otimizar recuperação recente, mas a
reconciliação obrigatória continua sendo uma query ao estado durável. Fonte:
[Broadcast sem cliente conectado][supabase-no-listener].

### 2.2 Web Push

Web Push é a combinação de:

1. `PushManager.subscribe()` no cliente;
2. uma `PushSubscription` com endpoint e chaves enviada ao backend;
3. um POST Web Push assinado pelo servidor para o push service escolhido pelo
   navegador;
4. um evento `push` entregue ao Service Worker;
5. `showNotification()` para criar uma notificação persistente do sistema;
6. `notificationclick` para focar ou abrir o PWA.

As Push API, Notifications API e Service Workers são APIs distintas. Push
transporta um sinal assíncrono mesmo sem a página carregada; Notifications
mostra a UI do sistema; o Service Worker é o executor curto entre as duas.
Fontes: [Push API][w3c-push],
[Notifications API][whatwg-notifications] e
[visão geral do Web Push][google-web-push-overview].

Contrato GrillStudio:

- usar Web Push padronizado com VAPID, sem depender de um SDK de aplicativo
  nativo;
- guardar endpoint, `p256dh`, `auth`, chave VAPID usada, membro, dispositivo
  lógico, datas e estado somente no servidor;
- tratar o endpoint como segredo operacional: não registrar URL nem chaves em
  logs, analytics, issue ou payload Realtime;
- usar payload pequeno e genérico, com `notification_id`, tipo, versão,
  destino relativo permitido e prazo; buscar o conteúdo atual após abrir;
- não expor nome, telefone, detalhes de qualificação, valores ou link de call
  na tela bloqueada;
- enviar push de todo alerta persistente (`Acompanhar`, `Precisa de ação` e
  `Crítico agora`) mesmo se uma presença Realtime parecer ativa, pois há uma
  corrida entre presença, suspensão e emissão do alerta;
- deduplicar a cópia na plataforma pelo ID; `tag`/`Topic` apenas agrupam ou
  substituem notificações visuais que sejam realmente supersedidas.

A mensagem Web Push é criptografada, mas o push service ainda observa metadados
como horário, frequência e tamanho. O RFC também alerta que logs de endpoints
revelam relações entre subscriptions. Fontes:
[segurança da Push API][w3c-push] e
[riscos de logging no RFC 8030][rfc-web-push].

## 3. Foreground, background e encerrado

| Estado observado | Realtime | Web Push | Recuperação obrigatória |
|---|---|---|---|
| PWA visível e ativo | Canal conectado é o caminho de baixa latência. | O Service Worker ainda pode receber push; quando o servidor envia, deve produzir notificação visível. | Query inicial e consulta se houver erro, salto de versão ou cursor desconhecido. |
| PWA minimizado ou aba oculta | Pode funcionar por algum tempo, mas timers, heartbeat e WebSocket podem ser suspensos. Não é uma garantia. | O push service pode acordar o Service Worker e mostrar a notificação. | Ao voltar a `visible`, reconectar e consultar o banco antes de declarar a tela atualizada. |
| Página congelada ou descartada | Tarefas e WebSocket da página não executam; no descarte não existe callback. | O Service Worker é separado da página e pode ser iniciado por `push`, sujeito ao SO e à permissão. | Em `pageshow`, nova carga ou restauração, buscar snapshot e não confiar no estado em memória. |
| PWA/aba encerrado | Não há JavaScript de página nem WebSocket. | É o canal web previsto para chamar atenção sem página carregada, mas continua best-effort. | Ao abrir pelo ícone ou pela notificação, buscar o registro canônico e registrar somente a abertura; leitura exige a interação explícita definida na seção 9.2. |

O Chrome recomenda fechar WebSockets quando a página entra em `frozen` e
informa que páginas ocultas podem ser descartadas sem evento. A especificação
de Service Workers permite ao navegador terminar o worker quando não há evento
ou quando ele excede limites; não existe processo JavaScript residente.
Fontes: [Page Lifecycle][chrome-page-lifecycle] e
[lifetime do Service Worker][w3c-service-workers].

### 3.1 iOS e iPadOS

Web Push é suportado a partir do iOS/iPadOS 16.4 **somente para web apps
adicionados à Tela de Início**. O pedido de permissão deve ocorrer após ação
direta do usuário. Depois da concessão, notificações aparecem na Tela
Bloqueada, Central de Notificações e Apple Watch pareado, e são afetadas pelas
configurações de Focus. Não é necessário Apple Developer Program. Fonte:
[Web Push em iOS/iPadOS][webkit-ios-push].

Matriz definida:

- não instalado na Tela de Início: sem push no iPhone/iPad; somente plataforma
  enquanto a página executa;
- instalado, visível: Realtime para UI e push visível para classes que exigem
  push;
- instalado, minimizado: Realtime é oportunístico; APNs/Web Push + Service
  Worker é o caminho de notificação;
- instalado, encerrado: tratar push como suportado, mas best-effort; a
  confirmação real ocorre apenas quando a pessoa abre o app e o estado é
  ressincronizado;
- Focus, notificações do app desativadas, rede, energia, limpeza de dados do
  site ou remoção do app podem atrasar ou impedir a atenção.

A Apple exige notificação visível imediatamente após o evento `push`; push
invisível pode causar revogação da permissão. O Service Worker não deve fazer
uma leitura de rede como pré-condição para mostrar a notificação. A extensão
Declarative Web Push reduz esse risco em versões Apple recentes, mas ainda não
é base interoperável e fica fora do MVP; o payload pode adotar formato
compatível depois de um teste separado. Fontes:
[requisitos Web Push da Apple][apple-web-push] e
[Declarative Web Push][webkit-declarative-push].

### 3.2 Android

No Chrome para Android, o sistema pode acordar o navegador e este acorda o
Service Worker quando chega um push, mesmo sem página aberta. Instalar o PWA
não é requisito da Push API em um site HTTPS com Service Worker, permissão e
subscription, mas será requisito operacional do piloto GrillStudio para
reduzir variações de abertura, identidade visual e suporte. Outros navegadores
Android entram apenas por feature detection. Fontes:
[Push sem browser aberto no Android][chrome-push-faq],
[subscribe][mdn-push-subscribe] e
[feature detection][google-push-subscribe].

Matriz definida:

- visível: Realtime atualiza a tela; push continua visível para as classes
  configuradas;
- minimizado: não confiar no WebSocket da página; push acorda o Service Worker;
- aba/navegador encerrado: Chrome/Android prevê acordar navegador e worker,
  salvo bloqueio de sistema, force-stop, permissão revogada ou indisponibilidade;
- ao tocar, focar uma janela do mesmo escopo se existir ou abrir o destino
  permitido, e sempre consultar o banco.

## 4. Instalação, permissão e recusa

Pré-requisitos comuns:

- origem HTTPS, exceto localhost em desenvolvimento;
- manifest e ícones válidos para instalação;
- Service Worker registrado, instalado e ativo;
- `PushManager` e `Notification` detectados;
- `userVisibleOnly: true`;
- chave pública VAPID no `subscribe()` e chave privada somente no servidor;
- solicitação em botão/contexto que explique valor e tipos de alerta.

`Notification.requestPermission()` retorna `granted`, `denied` ou `default`;
`default` deve ser tratado como negado. A aplicação não pode revogar ou
reconceder a permissão por código; a pessoa controla isso nas configurações do
navegador/SO. Fontes:
[requestPermission][mdn-request-permission],
[Permissions API][mdn-permissions] e
[PushManager.subscribe][mdn-push-subscribe].

Fluxo GrillStudio:

1. mostrar um pre-prompt próprio após login, explicando que `Acompanhar`,
   `Precisa de ação` e `Crítico agora` geram notificações de sistema, com
   conteúdo mínimo na tela bloqueada;
2. no iOS, detectar modo Tela de Início e, se ausente, orientar instalação
   antes de oferecer o botão;
3. pedir a permissão apenas no clique;
4. após `granted`, criar subscription e persistir no backend autenticado;
5. após `denied`, `default`, recurso ausente ou erro, registrar estado local e
   exibir configuração incompleta, sem loops de prompt;
6. em cada abertura, comparar `Notification.permission`,
   `getSubscription()` e o registro do servidor;
7. se a pessoa revogou, marcar a subscription inativa e manter plataforma +
   fallback crítico aprovado;
8. oferecer instrução para reabilitar nas configurações, nunca fingir que o
   código pode desfazer `denied`.

Negar push não bloqueia o uso geral nem autoriza WhatsApp adicional. Deve
aparecer como prontidão degradada na plataforma. Para o piloto, dono/gestor de
plantão e corretores que recebem ofertas/calls precisam concluir o gate de
instalação e teste; exceção exige cobertura operacional explícita.

## 5. Service Worker e ciclo da notificação

O Service Worker passa por registro, `install`, possível `waiting` e
`activate`. Worker novo não recebe `push` antes de estar ativo; atualização
pode permanecer em `waiting` enquanto uma versão anterior controla clientes.
Ativação forçada com `skipWaiting()` pode misturar página antiga e worker novo,
portanto atualização do contrato de payload precisa ser retrocompatível.
Fontes: [ciclo do Service Worker][google-sw-lifecycle] e
[Service Workers][w3c-service-workers].

Handler mínimo:

```text
push
  validar envelope versionado e destino relativo
  escolher texto genérico conhecido
  event.waitUntil(
    showNotification(tag, notification_id, target_url)
    + tentativa opcional de receipt
  )

notificationclick
  fechar notificação
  event.waitUntil(focar cliente no escopo ou abrir target_url)

aplicação visível
  buscar alerta/entidade no banco
  registrar open/read somente conforme interação definida
```

Regras:

- nada importante fica apenas em variável global do worker;
- `event.waitUntil()` cobre `showNotification()` e trabalhos auxiliares
  curtos; não transforma o worker em processo residente;
- falha ao buscar receipt não impede `showNotification()`;
- receipt falho pode ser guardado localmente e reconciliado na próxima
  abertura, sem depender de Background Sync;
- `notificationclick` é abertura, não leitura;
- `notificationclose` é telemetria best-effort, não recusa, leitura ou
  resolução;
- URL externa, esquema não HTTPS ou destino fora do escopo é rejeitado;
- o worker não recebe service role, segredo VAPID privado nem sessão de
  backend embutida.

Notificações persistentes e seus eventos `notificationclick` e
`notificationclose` são definidos na Notifications API. A especificação
permite terminar o worker fora do período de execução de eventos. Fontes:
[Notifications API][whatwg-notifications] e
[lifetime do Service Worker][w3c-service-workers].

## 6. Expiração, invalidação e renovação de subscriptions

Uma subscription pode ter `expirationTime` ou retornar `null`. Mesmo sem data
exposta, user agent ou push service pode renová-la, perdê-la, revogá-la ou
expirá-la. A especificação prevê `pushsubscriptionchange`, mas o suporte ainda
não é uniforme entre navegadores. Fontes:
[refresh da Push API][w3c-push],
[expirationTime][mdn-subscription-expiration] e
[compatibilidade de pushsubscriptionchange][mdn-subscription-change].

Contrato do servidor:

```text
push_subscription
  id
  membership_id
  installation_id aleatório
  endpoint cifrado ou em coluna privada
  p256dh/auth cifrados
  vapid_key_version
  user_agent_family
  permission_state
  subscribed_at
  last_confirmed_at
  expires_at opcional
  invalidated_at/reason opcionais
```

Rotina:

- no login, abertura e retorno a `visible`, chamar `getSubscription()` e
  reconciliar endpoint/chaves com o backend;
- também tratar `pushsubscriptionchange`, mas nunca depender somente dele;
- quando mudar, inserir/ativar a nova antes de retirar a antiga;
- atualizar `last_confirmed_at` apenas após sincronização autenticada;
- HTTP `404` ou `410` de endpoint válido torna a subscription inativa e não é
  retentado;
- `429` respeita `Retry-After`; timeout e `5xx` usam backoff com jitter até o
  prazo útil do alerta;
- logout remove a associação ao membro e tenta `unsubscribe()`, sem tornar a
  operação dependente do sucesso do cliente;
- revogação de acesso do membro invalida todas as subscriptions no servidor;
- rotação de VAPID exige coexistência versionada e nova inscrição consentida,
  pois as opções da subscription não mudam no lugar.

O RFC permite ao push service expirar uma subscription a qualquer momento e
define `404` para envio a subscription expirada. O endpoint Apple documenta
`410` quando o token expirou. Fontes:
[expiração no RFC 8030][rfc-web-push] e
[respostas Web Push da Apple][apple-web-push].

## 7. Matriz por evento

`R` = Realtime quando conectado; `P` = Web Push; `I` = registro persistente
in-app; `W` = WhatsApp já permitido pelo produto.

Esta matriz aplica a instrução de produto mais recente e substitui a linha
antiga da seção 28.3 da Especificação que limitava `Acompanhar` à plataforma:
alerta normal também é `I + R + P`. Métricas, cards e estados informativos que
não constituem alerta continuam podendo usar somente Realtime + query.

| Evento/superfície | Canais | Comportamento e fallback |
|---|---|---|
| Mensagens, anexos e receipts na conversa aberta | `R` | Aplicar por ID/versão. Ao reconectar ou abrir, buscar mensagens desde o cursor. Receipt não gera push. |
| Nova mensagem que exige resposta humana ou escalonamento | `I + R + P` | O alerta persistido é a cópia canônica. Push usa texto genérico e abre a conversa; ausência de push não remove o item da Central. |
| Digitação, presença e seleção transitória | `R` | Pode ser perdida sem efeito de negócio. Não persistir como alerta nem enviar push. |
| Kanban, ownership, próxima ação e card | `R` | Realtime invalida card/coluna. Drag/drop e transição confirmam no banco; recarregamento recompõe a coluna. |
| Contadores, capacidade, resumo e badge | `R`; badge de push apenas como dica | Contagem canônica vem do banco. Badge nunca decide admissão, oferta ou SLA e é recalculado ao abrir. |
| `Acompanhar`/alerta normal | `I + R + P` | Persiste na Central e também gera push. Continua recuperável até a condição de saída; toast/push não é a cópia canônica. |
| `Precisa de ação` | `I + R + P` | Persistir antes do fan-out. Push por subscription ativa; negado/revogado mantém banner e contador in-app. |
| `Crítico agora` | `I + R + P` | Mesma regra, com urgência/TTL compatíveis com a validade. Escalonar por alerta não lido/não resolvido no banco, não por ausência de receipt do navegador. |
| Oferta/lembrete de call ao corretor | `I + R + P` e fluxo `W` operacional já aprovado para corretor | Push/WhatsApp carregam apenas o mínimo permitido. Aceite abre a plataforma ou fluxo aprovado e a transação atômica no banco decide o vencedor. |
| Call próxima/horário sem corretor, devolução sem substituto, corretor ausente ou link pendente próximo | `I + R + P + W` para dono/gestor habilitado | WhatsApp é o fallback crítico aprovado, com nome/horário/motivo e instrução para entrar, sem link. O caso persiste até assumir/resolver. |
| Conector degradado, fila/dead letter, erro crítico do Pedro, campanha pausada, pagamento sensível | `I + R + P` quando registrado como alerta | Não ampliar WhatsApp; somente risco imediato de call usa esse canal para dono/gestor. |
| Orçamento de IA | `I + R + P` somente para dono | Permissão financeira de consulta não adiciona destinatário de push. |
| Alerta já recebido por push, Realtime ou reload | manter `I + R + P`, idempotentes por canal | Não criar outra notificação lógica nem reaplicar efeito. Cada entrega contratada conserva sua chave de fan-out; uma chegada anterior por outro canal não suprime push ou Realtime. |

A matriz aplica as decisões existentes de
[Especificação do Produto, alertas](../product/Especificacao-do-Produto-v1.md),
[Mapa de Telas, Central](../product/Mapa-de-Telas-v1.md),
[Eventos, Filas e Automações](../product/Eventos-Filas-e-Automacoes-v1.md) e
[ADR 0001](../adr/0001-banco-como-estado-canonico.md).

## 8. Deduplicação e convergência

Cada alteração durável relevante produz um `event_id`; cada alerta por
destinatário recebe `notification_id`. A chave de fan-out é:

```text
notification:{notification_id}:{channel}:{subscription_id-or-membership_id}
```

O mesmo `notification_id` via Realtime, push, query ou clique representa a
mesma cópia lógica. Regras:

- unique constraint impede criar duas notificações in-app para o mesmo evento,
  destinatário e tipo;
- a outbox cria no máximo uma entrega por chave de fan-out; presença Realtime,
  página visível ou reload não cancelam a entrega Web Push exigida pela classe;
- cada tentativa de push é idempotente no GrillStudio; retry não cria outro
  alerta;
- o cliente mantém cache limitado de IDs vistos, mas a proteção real é a
  identidade persistida;
- eventos de agregado carregam `aggregate_version`; versão menor ou igual à
  aplicada não retrocede a UI;
- salto de versão, reconnect, mudança `hidden → visible`, foco após push ou
  erro do canal força re-fetch;
- lista de alertas usa cursor estável do servidor, não somente timestamp do
  relógio do aparelho;
- `Notification.tag` pode substituir a representação visual do mesmo alerta;
  o header Web Push `Topic` só é usado quando o novo estado torna o anterior
  inútil, nunca para ocultar dois críticos independentes;
- push não carrega o estado mutável final; o clique navega para o ID e o app
  lê a versão atual.

O RFC permite substituir mensagens pendentes do mesmo `Topic`; isso é
otimização de fila do push service, não exactly-once no produto. Fonte:
[RFC 8030][rfc-web-push].

## 9. Observabilidade, retries e leitura

### 9.1 Realtime

Medir, por versão do app e plataforma:

- conexão, `SUBSCRIBED`, `CHANNEL_ERROR`, `TIMED_OUT`, reconnect e duração
  desconectada;
- heartbeat `ok`, `timeout` e `disconnected`;
- último `event_id`/versão recebido e último cursor reconciliado;
- lag entre `occurred_at`, publicação, recebimento e convergência da query;
- limite, erro de autorização e JWT expirado;
- quantidade de gaps que exigiram snapshot.

Supabase fornece relatórios de conexões, eventos Broadcast/Postgres Changes,
tempo de execução, lag e erros, além de logger do cliente. Fontes:
[Realtime Reports][supabase-reports] e
[logger do Realtime][supabase-logger].

### 9.2 Push

Estados distintos:

```text
requested
  -> accepted_by_push_service
  -> sw_received opcional
  -> notification_shown opcional
  -> clicked
  -> platform_opened
  -> read
  -> resolved

requested
  -> retry_scheduled | invalid_subscription | expired | failed
```

- `accepted_by_push_service` vem do HTTP do endpoint e não significa entrega;
- `sw_received`/`notification_shown` exigem receipt próprio, que pode falhar
  offline e por isso são opcionais;
- `clicked` vem do Service Worker;
- `platform_opened` vem da tela autenticada após buscar o alerta;
- `read` ocorre somente quando a pessoa autenticada aciona `Marcar como lido`
  (ou `Marcar todos como lidos`) na Central com o alerta renderizado; abrir a
  rota, receber Realtime, clicar no push ou deixar um banner visível não marca
  leitura automaticamente;
- uma ação de domínio concluída pode gravar `read_at` e `resolved_at` na mesma
  transação, mas mantém os dois eventos e timestamps distintos;
- `resolved` é mudança de domínio e nunca é inferida de clique, close ou push;
- armazenar status HTTP, classe de erro, tentativas, latência e ID interno,
  nunca endpoint, chaves ou payload sensível em log.

O protocolo prevê receipts do push service, mas um `201` comum não confirma
entrega e fornecedores não oferecem uma garantia uniforme dessa interface ao
aplicativo web. Logo, receipt próprio continua sendo telemetria, não condição
de correção. Fonte: [RFC 8030][rfc-web-push].

Política de retry:

- `404/410`: invalidar subscription, sem retry;
- `400/403`: erro não retentável até corrigir payload/VAPID/autorização;
- `429`: respeitar `Retry-After`;
- timeout/`5xx`: backoff exponencial com jitter e limite pelo prazo útil;
- resposta de sucesso: não reenviar apenas porque não houve `read`;
- cada reenvio usa a mesma identidade lógica e registra nova tentativa;
- alerta crítico não lido é escalado pelas regras duráveis do produto,
  independentemente do push.

TTL deve refletir a validade do evento: ao expirar, o Service Worker ou a
aplicação consulta o estado e suprime notificação obsoleta. O push service pode
encurtar TTL e deixar de tentar antes dele. Fonte:
[TTL e retries no RFC 8030][rfc-web-push].

## 10. Garantias que o produto não pode prometer

Não prometer:

- entrega instantânea ou garantida de Web Push;
- notificação visível apesar de Focus, configuração do SO, economia de energia,
  rede, force-stop ou permissão revogada;
- execução contínua de página, Web Worker ou Service Worker em background;
- WebSocket ativo com PWA minimizado;
- replay completo de Realtime;
- ordem global entre Realtime, push, query e múltiplos dispositivos;
- exactly-once de evento ou de notificação;
- que HTTP de sucesso do push significa exibido, visto ou lido;
- que `notificationclose` significa rejeição;
- que `pushsubscriptionchange` será entregue em todos os navegadores;
- que `expirationTime === null` torna uma subscription permanente;
- que push funciona no iOS sem Tela de Início;
- que badge ou Presence representam estado canônico.

Pode prometer, depois dos gates:

- o alerta durável reaparece ao abrir/recarregar a plataforma;
- a tela converge para o banco após reconnect/reload;
- Realtime e push são idempotentes no nível lógico do produto;
- permissão, tentativas, invalidações, abertura, leitura e resolução ficam
  auditáveis;
- crítico de call usa também o fallback WhatsApp aprovado para dono/gestor,
  sem link;
- nenhuma falha de push executa ou duplica uma ação de domínio.

## 11. Critérios objetivos do protótipo

### 11.1 Protótipo lógico executado

O protótipo descartável
[`prototype/realtime-push-delivery`](https://github.com/supinovahub/GrillStudio/tree/e30daaa39b1ba2ee4ec051421c27b9c2cb17eb66/prototypes/realtime-push-delivery)
modelou a convergência de `notification_id` sem Supabase, push service,
credencial, número ou dado real. Ele foi executado com:

```sh
node prototypes/realtime-push-delivery/prototype.mjs --scenario all
```

Resultado em 2026-07-30: **6/6 cenários passaram** no runtime Node.js v24.14.0
empacotado no workspace:

1. Realtime e push duplicados em foreground produziram um alerta lógico e uma
   tag de notificação do sistema;
2. clique após background recuperou o alerta do estado canônico;
3. permissão negada preservou a cópia na plataforma;
4. crítico de call enfileirou o fallback WhatsApp aprovado sem link;
5. subscription inválida preservou a cópia na plataforma;
6. clique registrou abertura sem inferir leitura.

Status da evidência: **lógica aprovada; transporte móvel não homologado**. O
protótipo aprova a convergência do modelo e a separação entre abertura e
leitura para esta decisão arquitetural, mas não comprova transporte nem
entrega de navegador/SO. Portanto, o ticket pode fechar a escolha técnica,
mas não autoriza piloto ou promessa de suporte móvel antes do probe físico.

### 11.2 Probe físico obrigatório antes do piloto

A validação de transporte exige execução reproduzível em origem HTTPS estável,
com contas e dados sintéticos:

1. iPhone/iPad físico compatível, PWA instalado; Android físico em Chrome
   atual, PWA instalado; navegadores/versões registrados no relatório;
2. casos foreground, minimizado e encerrado em ambos; no iOS, caso negativo
   sem Tela de Início;
3. permissão `default`, concedida, negada e revogada;
4. rede online, offline antes do envio, retorno antes do TTL e retorno após o
   TTL;
5. página congelada/descartada no Chrome, reconnect de Realtime e salto
   deliberado de versão;
6. subscription removida e respostas sintéticas `404`, `410`, `429` e `5xx`;
7. mesmo `notification_id` entregue por Realtime, push repetido, reload e
   clique, produzindo um único alerta lógico;
8. Service Worker antigo, worker novo em `waiting` e ativação posterior,
   mantendo compatibilidade do envelope;
9. push aceito sem clique não marca leitura; clique marca abertura; somente o
   botão `Marcar como lido`/`Marcar todos como lidos` com o alerta renderizado
   marca leitura; somente ação de domínio resolve;
10. alerta normal continua na plataforma + push; caso crítico aprovado de call
    continua na plataforma + push + WhatsApp sem link; push negado não gera
    WhatsApp para outras classes;
11. Kanban, conversa, contadores e alertas convergem ao estado do banco depois
    de cada lacuna, ainda que nenhuma notificação do sistema apareça;
12. logs permitem correlacionar evento, tentativa, plataforma, status e
    latência sem endpoint, chave, credencial, conteúdo pessoal ou dado real.

O probe físico é aprovado somente se:

- todos os casos funcionais acima passarem;
- cada falha de entrega deixar o alerta recuperável na plataforma;
- não houver ação duplicada nem estado regressivo;
- o relatório separar `accepted`, `shown`, `clicked`, `read` e `resolved`;
- taxa e latência observadas forem publicadas como resultado do teste, não como
  SLA do navegador;
- o piloto documentar dispositivos suportados, pessoa de plantão, procedimento
  para push desativado e execução ensaiada do fallback crítico;
- métricas, quotas e alertas do único projeto Supabase pago forem configurados
  antes de usuários reais, mantendo desenvolvimento e CI em Preview Branches
  efêmeras e sem dados.

## 12. Gates de produção

- revisão de RLS dos canais privados e das tabelas de subscriptions/alertas;
- fila/outbox durável para fan-out, retries e dead letter;
- VAPID privado no cofre, rotação versionada e endpoint/chaves cifrados;
- Service Worker versionado, CSP/HTTPS, teste de update e rollback;
- allowlist de destinos de `notificationclick`;
- política de TTL/urgência por tipo e conteúdo seguro para tela bloqueada;
- feature detection e matriz mínima publicada para iOS/Android;
- dashboard de Realtime, push, subscription inválida, alertas não lidos e
  críticos não resolvidos;
- reconciliação em login, `visible`, reconnect e clique;
- teste físico periódico após atualização relevante de iOS, Android, Safari,
  Chrome, `supabase-js` ou Service Worker;
- aceite explícito de que push é best-effort e nunca a única cópia;
- WhatsApp para dono/gestor limitado aos casos críticos de call aprovados, sem
  link.

## 13. Fontes primárias consultadas

Consulta em 2026-07-30:

- Supabase:
  [Realtime][supabase-realtime],
  [arquitetura][supabase-architecture],
  [mudanças de banco][supabase-subscribe-changes],
  [Broadcast/replay][supabase-broadcast],
  [protocolo/reconexão][supabase-protocol],
  [autorização][supabase-authorization],
  [lockdown do schema Realtime][supabase-realtime-lockdown],
  [limites][supabase-limits],
  [background][supabase-background],
  [heartbeat][supabase-heartbeat] e
  [reports][supabase-reports];
- padrões:
  [Push API][w3c-push],
  [Notifications API][whatwg-notifications],
  [Service Workers][w3c-service-workers] e
  [RFC 8030][rfc-web-push];
- Apple/WebKit:
  [Web Push no iOS/iPadOS][webkit-ios-push],
  [envio Web Push][apple-web-push],
  [Meet Web Push][webkit-meet-push] e
  [User Notifications][apple-user-notifications];
- Google/Chrome:
  [Page Lifecycle][chrome-page-lifecycle],
  [Push FAQ para Android][chrome-push-faq],
  [visão geral Web Push][google-web-push-overview] e
  [FCM lifespan][fcm-lifespan];
- MDN para comportamento prático e compatibilidade:
  [subscribe][mdn-push-subscribe],
  [requestPermission][mdn-request-permission],
  [expirationTime][mdn-subscription-expiration] e
  [pushsubscriptionchange][mdn-subscription-change].

[supabase-realtime]: https://supabase.com/docs/guides/realtime
[supabase-architecture]: https://supabase.com/docs/guides/realtime/architecture
[supabase-subscribe-changes]: https://supabase.com/docs/guides/realtime/subscribing-to-database-changes
[supabase-broadcast]: https://supabase.com/docs/guides/realtime/broadcast
[supabase-replay-stage]: https://supabase.com/features/realtime-broadcast-replay
[supabase-protocol]: https://supabase.com/docs/guides/realtime/protocol
[supabase-js-subscribe]: https://supabase.com/docs/reference/javascript/subscribe
[supabase-authorization]: https://supabase.com/docs/guides/realtime/authorization
[supabase-realtime-lockdown]: https://supabase.com/changelog/realtime-schema-locked-down-against-modification
[supabase-limits]: https://supabase.com/docs/guides/realtime/limits
[supabase-background]: https://supabase.com/docs/guides/troubleshooting/realtime-handling-silent-disconnections-in-backgrounded-applications-592794
[supabase-heartbeat]: https://supabase.com/docs/guides/troubleshooting/realtime-heartbeat-messages
[supabase-no-listener]: https://supabase.com/docs/guides/troubleshooting/realtime-warn-sending-broadcast-message
[supabase-reports]: https://supabase.com/docs/guides/realtime/reports
[supabase-logger]: https://supabase.com/docs/guides/troubleshooting/realtime-debugging-with-logger
[w3c-push]: https://www.w3.org/TR/push-api/
[whatwg-notifications]: https://notifications.spec.whatwg.org/
[w3c-service-workers]: https://www.w3.org/TR/service-workers/
[rfc-web-push]: https://www.rfc-editor.org/rfc/rfc8030
[webkit-ios-push]: https://webkit.org/blog/13878/web-push-for-web-apps-on-ios-and-ipados/
[apple-web-push]: https://developer.apple.com/documentation/usernotifications/sending-web-push-notifications-in-web-apps-and-browsers
[webkit-meet-push]: https://webkit.org/blog/12945/meet-web-push/
[webkit-declarative-push]: https://webkit.org/blog/16535/meet-declarative-web-push/
[apple-user-notifications]: https://developer.apple.com/documentation/usernotifications/
[chrome-page-lifecycle]: https://developer.chrome.com/docs/web-platform/page-lifecycle-api
[chrome-push-faq]: https://web.dev/articles/push-notifications-faq
[google-web-push-overview]: https://web.dev/articles/push-notifications-overview
[google-push-subscribe]: https://web.dev/articles/push-notifications-subscribing-a-user
[google-sw-lifecycle]: https://web.dev/articles/service-worker-lifecycle
[fcm-lifespan]: https://firebase.google.com/docs/cloud-messaging/customize-messages/setting-message-lifespan
[mdn-push-subscribe]: https://developer.mozilla.org/en-US/docs/Web/API/PushManager/subscribe
[mdn-request-permission]: https://developer.mozilla.org/en-US/docs/Web/API/Notification/requestPermission_static
[mdn-permissions]: https://developer.mozilla.org/en-US/docs/Web/API/Permissions_API
[mdn-subscription-expiration]: https://developer.mozilla.org/en-US/docs/Web/API/PushSubscription/expirationTime
[mdn-subscription-change]: https://developer.mozilla.org/en-US/docs/Web/API/ServiceWorkerGlobalScope/pushsubscriptionchange_event
