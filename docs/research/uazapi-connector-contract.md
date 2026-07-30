# Contrato de pesquisa do conector Uazapi

Status: decisão de integração para o MVP, sem implementação e sem validação em
instância autenticada.

Data da pesquisa: 2026-07-30.

## 1. Resultado executivo

O GrillStudio deve tratar a Uazapi como um provedor externo sem idempotência
documentada e com payload de webhook evolutivo:

- a API documentada é a `uazapiGO` `2.1.1`, exposta sem versão no caminho em
  `https://{subdomain}.uazapi.com`;
- operações administrativas usam o header `admintoken`; todas as demais usam
  o header `token` da instância;
- uma instância pode ser criada por `POST /instance/create`, conectada por QR
  Code ou código de pareamento em `POST /instance/connect` e acompanhada por
  `GET /instance/status`;
- o envio mínimo usa `POST /send/text` e `POST /send/media`;
- `messages`, `messages_update` e `connection` são os eventos necessários ao
  MVP;
- `Message.messageid`, e não `Message.id`, é a melhor chave documentada para o
  ID original da mensagem no provedor;
- os estados de mensagem documentados como exemplos são `Queued`, `Canceled`,
  `Failed`, `Sent`, `Delivered` e `Read`;
- a especificação não documenta header de idempotência e diz expressamente que
  `track_id` aceita duplicatas. Portanto, retry de envio com resultado incerto
  não pode ser automático.

Esses fatos vêm da [especificação OpenAPI oficial][oas], respectivamente em
`info`, `servers`, `components.securitySchemes`, nas operações citadas e em
`components.schemas.Message`.

Há três lacunas que impedem habilitar inbound autêntico e envio autônomo em
produção sem uma confirmação adicional:

1. não existe mecanismo documentado de assinatura ou autenticação das chamadas
   de webhook;
2. não existem schemas concretos dos payloads de `messages`,
   `messages_update` e `connection`, nem um provider event ID garantido;
3. não são documentados os limites quantitativos de requisição ou de tamanho de
   mídia, nem a semântica de retry/ack do webhook.

Essas lacunas não serão preenchidas por inferência. A seção
[15. Bloqueios e mínimo necessário](#15-bloqueios-e-mínimo-necessário) define
exatamente o que falta.

## 2. Escopo e fontes

Esta pesquisa cobre somente o contrato Uazapi necessário à camada de conectores
do GrillStudio. Não cria instância, não conecta número, não envia mensagem e
não altera webhook.

### 2.1 Fonte primária do provedor

Foi usada somente a documentação oficial:

- [portal oficial de documentação][docs];
- [OpenAPI oficial, formato JSON][oas].

O snapshot consultado declara OpenAPI `3.1.0`, produto `uazapiGO`, versão
`2.1.1`, 132 caminhos e 11 schemas. Em 2026-07-30 o recurso retornava
`Last-Modified: Mon, 27 Jul 2026 02:05:56 GMT`, `ETag:
"575bfb1ad859020c862499c1401d4a33"` e SHA-256
`ba13d184dba2b0bdba2d92f640d82fe3dd6d5001e45095fdf482493925f9096b`.
Esses valores são evidência de pesquisa, não promessa de imutabilidade da URL.

### 2.2 Decisões internas vinculantes

Este contrato aplica:

- [ADR 0003](../adr/0003-processamento-assincrono-duravel.md):
  entrega pelo menos uma vez, inbox/outbox e consumidores idempotentes;
- [ADR 0004](../adr/0004-conectores-de-whatsapp-e-conversa-fixa.md):
  conversa fixa ao número e à identidade de origem;
- [Arquitetura Técnica v1](../product/Arquitetura-Tecnica-v1.md), seções 3.4,
  4.1, 4.2 e 9: adaptador comum, persistência antes do envio, receipts e spike
  da Uazapi;
- [Eventos, Filas e Automações v1](../product/Eventos-Filas-e-Automacoes-v1.md),
  seções 5, 9, 10 e 11: ingresso durável, classificação de retry,
  idempotência e reconciliação;
- [Modelo de Dados e Segurança v1](../product/Modelo-de-Dados-e-Seguranca-v1.md),
  seções 6, 11, 14 e 15: IDs externos, payload bruto privado, anexos privados
  e constraints;
- [Especificação do Produto v1](../product/Especificacao-do-Produto-v1.md),
  seção 36.4: URL + token para instância existente, URL + `admintoken` para
  criação, segredos mascarados e conversa presa ao número.

Quando este documento diz **fato Uazapi**, ele descreve somente o que a fonte
primária afirma. Quando diz **decisão GrillStudio**, ele fixa o comportamento
normalizado do nosso lado, inclusive onde a Uazapi não oferece garantia.

## 3. Superfície, URL e versionamento

### 3.1 Fatos Uazapi

| Item | Contrato documentado | Evidência oficial |
|---|---|---|
| Base URL | `https://{subdomain}.uazapi.com`; a variável publicada enumera `free` e `api` e usa `free` como default | [OpenAPI][oas], `servers[0]` |
| Versão do produto | `2.1.1` | [OpenAPI][oas], `info.version` |
| Versão no caminho | Nenhum dos 132 caminhos publicados contém prefixo `/v1` ou `/v2` | [OpenAPI][oas], `paths` |
| Versão da descrição | OpenAPI `3.1.0` | [OpenAPI][oas], `openapi` |
| Changelog/compatibilidade | Não há changelog, data de depreciação ou política de compatibilidade no documento | [OpenAPI][oas], chaves raiz |

### 3.2 Decisão GrillStudio

Cada `whatsapp_connection` Uazapi guarda, no servidor:

```text
provider = uazapi
base_url = URL HTTPS validada, sem credenciais, query ou fragment
instance_id = string opaca retornada pelo provedor
instance_token_secret_ref = referência ao cofre
admin_token_secret_ref = referência ao cofre, somente se a conexão puder criar instâncias
observed_api_version = 2.1.1
observed_openapi_sha256 = ba13d...9096b
```

`base_url` é configuração por conexão porque o produto aceita uma URL fornecida
pelo dono. O adaptador remove apenas a barra final; não acrescenta versão nem
troca host automaticamente.

Antes de adotar uma nova versão ou um novo hash do OpenAPI, fixtures do contrato
devem ser revalidadas. Campos adicionais em respostas e webhooks são aceitos e
preservados no payload bruto; remoção, renome ou mudança de tipo bloqueiam a
promoção.

## 4. Autenticação e segredos

### 4.1 Fatos Uazapi

| Escopo | Credencial | Transporte | Operações relevantes | Evidência oficial |
|---|---|---|---|---|
| Instância | token único da instância | header `token` | status, conexão, webhook, envio, consulta e ciclo de vida | [OpenAPI][oas], `components.securitySchemes.token`, segurança global e operações |
| Administração | token administrativo | header `admintoken` | criar/listar instâncias, webhook global, campos administrativos e rotação administrativa | [OpenAPI][oas], `components.securitySchemes.admintoken` e operações com tag `Admininstração` |

`POST /instance/create` retorna o token da nova instância. `GET /instance/all`
também documenta o campo `token` de cada instância. O schema `Instance` ainda
contém `token` e `openai_apikey`; portanto, respostas de instância podem conter
segredos e não são próprias para logging. Evidência: [OpenAPI][oas],
`paths./instance/create.post`, `paths./instance/all.get` e
`components.schemas.Instance`.

`POST /admin/token/rotate` documenta rotação do `admintoken`, com cooldown de
24 horas. Não há operação publicada para rotacionar somente o token de uma
instância. Evidência: [OpenAPI][oas],
`paths./admin/token/rotate.post` e lista de `paths`.

### 4.2 Decisão GrillStudio

- Tokens existem apenas no backend e no cofre; nunca entram em
  `NEXT_PUBLIC_*`, banco exposto, browser, issue, fixture, screenshot ou log.
- O valor recebido na criação é capturado uma vez, gravado no cofre e
  descartado da memória de request assim que possível.
- Redação é por nome de header e também por formato/campo de resposta:
  `token`, `admintoken`, `admin_token` e `openai_apikey`.
- A interface mostra somente sufixo mascarado e data da última validação.
- `admintoken` só é carregado na operação explícita de criar instância. Fluxos
  diários usam exclusivamente o token daquela instância.
- `GET /instance/all` não é health check e não deve ser chamado no fluxo
  normal, pois amplia o alcance e pode devolver todos os tokens.
- Falta de rotação do token da instância é uma capacidade
  `instance_token_rotation = unsupported`; comprometimento exige instrução
  oficial do provedor ou substituição controlada da instância.

## 5. Criação, conexão e QR Code

### 5.1 Mapa de operações

| Ação | Método e caminho | Auth | Entrada mínima | Saída/efeito documentado | Evidência oficial |
|---|---|---|---|---|---|
| Criar | `POST /instance/create` | `admintoken` | `{name}`; `adminField01/02` opcionais | cria desconectada e retorna `instance`, `connected`, `loggedIn`, `name`, `token`; HTTP 200 | [OpenAPI][oas], `paths./instance/create.post` |
| Conectar por QR | `POST /instance/connect` | `token` | body ausente ou sem `phone` | muda para `connecting`; QR expira em 2 min | [OpenAPI][oas], `paths./instance/connect.post` |
| Conectar por código | `POST /instance/connect` | `token` | `{phone}` com 10–15 dígitos | gera código de pareamento; expira em 5 min | [OpenAPI][oas], `paths./instance/connect.post` |
| Consultar | `GET /instance/status` | `token` | — | `instance` + `{connected, loggedIn, jid}`; inclui QR/código enquanto conectando | [OpenAPI][oas], `paths./instance/status.get` e `components.schemas.Instance` |
| Validar existente | `GET /instance/status` | `token` | — | prova que URL/token alcançam uma instância e revela o estado | [OpenAPI][oas], `paths./instance/status.get` |

O schema `Instance` documenta `qrcode` como string base64 e `paircode` como
string. Evidência: [OpenAPI][oas], `components.schemas.Instance`.

Os estados publicados são:

| Raw Uazapi | Significado documentado | Estado normalizado |
|---|---|---|
| `disconnected` | desconectada do WhatsApp | `disconnected` |
| `connecting` | conexão/autenticação em andamento | `connecting` |
| `connected` | conectada e autenticada | `connected` somente se `loggedIn=true` |
| `hibernated` | sessão pausada, credenciais preservadas | `paused` |
| outro/ausente | não documentado | `unknown` |

Evidência dos quatro valores: [OpenAPI][oas], `info.description` e
`components.schemas.Instance.properties.status`.

### 5.2 Decisão GrillStudio

Fluxo de instância existente:

1. validar e guardar a URL;
2. guardar o token diretamente no cofre;
3. chamar `GET /instance/status`;
4. guardar `instance.id`, perfil e estado, com a resposta redigida;
5. se desconectada, oferecer o fluxo explícito de conexão.

Fluxo de criação:

1. criar uma operação local idempotente e usar seu `connection_id` opaco em
   `adminField01`, sem nome da imobiliária, telefone ou outro dado pessoal;
2. carregar o `admintoken` somente no servidor;
3. chamar `POST /instance/create`;
4. persistir imediatamente o token retornado no cofre;
5. associar o `instance.id` à operação antes de mostrar QR/código;
6. nunca devolver a resposta bruta ao browser;
7. seguir para `POST /instance/connect`.

Se a criação terminar em timeout ou 5xx depois de a requisição ter sido
enviada, não repetir `POST /instance/create` às cegas. O backend pode usar
`GET /instance/all` uma única vez, no fluxo administrativo redigido, para
procurar exatamente um `adminField01` igual ao `connection_id`. Um resultado
adota a instância; zero ou mais de um exigem revisão humana. Essa correlação
evita que a ausência de idempotência documentada crie várias instâncias.

`qrcode` e `paircode` são segredos transitórios de autenticação. Podem ser
entregues ao browser autenticado do dono, mas não são persistidos no banco,
cache compartilhado, analytics, screenshot ou log. A tela consulta o status até
`connected`, até o timeout documentado ou até cancelamento do dono.

O adaptador considera a conexão saudável somente quando o estado é
`connected`, `status.connected=true` e `status.loggedIn=true`. Combinações
contraditórias viram `degraded` e geram reconciliação, sem envio.

## 6. Webhooks, eventos e autenticidade

### 6.1 Configuração documentada

`GET /webhook` lista webhooks locais. `POST /webhook` cria/atualiza o webhook
simples ou administra vários por `action`/`id`. Ambos usam o token da instância.
Evidência: [OpenAPI][oas], `paths./webhook`.

Eventos configuráveis publicados:

```text
connection
history
messages
messages_update
newsletter_messages
call
contacts
presence
groups
labels
chats
chat_labels
blocks
sender
```

Evidência: [OpenAPI][oas],
`paths./webhook.post.requestBody...properties.events.items.enum`.

Filtros publicados:

```text
wasSentByApi
wasNotSentByApi
fromMeYes
fromMeNo
isGroupYes
isGroupNo
```

A própria documentação recomenda `wasSentByApi` para evitar loops. Também
oferece `addUrlEvents` e `addUrlTypesMessages`, ambos false por default.
Evidência: [OpenAPI][oas], `paths./webhook.post.description` e schema da
requisição.

`GET /webhook/errors` retorna em memória os últimos 20 erros locais, com
`created`, URL, evento, tipo de mensagem, status HTTP final, tentativas, erro e
payload. O histórico desaparece em restart. Evidência: [OpenAPI][oas],
`paths./webhook/errors.get`.

### 6.2 Inconsistências oficiais do payload

A fonte oficial não fixa um envelope utilizável:

- `components.schemas.WebhookEvent` exige `{event, instance, data}`, mas seu
  enum usa nomes singulares como `message` e `status`;
- a configuração usa nomes plurais como `messages` e `messages_update`;
- o exemplo de erro de entrega mostra payload com chaves `EventType` e `token`,
  sem `event`, `instance` ou `data`;
- `WebhookEvent.data` é `additionalProperties: true` e manda consultar
  exemplos específicos que não existem no OpenAPI publicado.

Evidência: [OpenAPI][oas], `components.schemas.WebhookEvent`,
`paths./webhook.post` e
`paths./webhook/errors.get.responses.200.content.application/json.example`.

Não há no OpenAPI header de assinatura, segredo de callback, HMAC, certificado,
lista de IPs nem challenge de verificação. A busca de todos os campos e
descrições relacionados a webhook encontra autenticação para **configurar** o
webhook, mas não para provar a origem de um POST recebido. Evidência:
[OpenAPI][oas], `components.securitySchemes` e operações `/webhook*`.

O campo `token` visto em um exemplo de payload não pode ser adotado como
assinatura: ele não está no schema de evento, é estático e qualquer emissor que
conheça o corpo esperado poderia copiá-lo.

### 6.3 Decisão GrillStudio

Configuração local por instância:

```json
{
  "enabled": true,
  "url": "https://<host-controlado>/api/webhooks/uazapi/<connection>/<nonce>",
  "events": ["messages", "messages_update", "connection"],
  "excludeMessages": ["wasSentByApi", "isGroupYes"],
  "addUrlEvents": false,
  "addUrlTypesMessages": false
}
```

Esse JSON é contrato desejado, não evidência de uma chamada realizada.

- Usa-se um único webhook local, não o webhook global administrativo.
- SSE fica fora do contrato: `GET /sse` exige o token da instância na query
  string, uma superfície propensa a vazamento em histórico, proxy e logs.
  Evidência do transporte do token: [OpenAPI][oas],
  `paths./sse.get.parameters`.
- `history` não é consumido no MVP: o produto não reconstrói automaticamente
  histórico antigo.
- Mensagens enviadas pela API são persistidas a partir do outbox/resposta de
  envio; o filtro `wasSentByApi` evita que retornem como novo inbound.
- Mensagem manual enviada pelo aparelho não é filtrada apenas por `fromMe`; ela
  precisa ser observável para impedir resposta automática concorrente.
- Grupos ficam fora do escopo do MVP.
- O nonce da URL é aleatório, armazenado como hash e rotacionável. Ele reduz
  tráfego casual, mas **não prova origem Uazapi**.

Até a lacuna de autenticidade ser resolvida, `verifyWebhook` devolve
`authenticity = unverified_provider` e a conexão não pode habilitar modo
produção. Modos sombra/assistido ainda exigem rate limit, limite de corpo,
Content-Type JSON, nonce válido e schema mínimo antes de persistir.

O ingress guarda headers permitidos e corpo bruto em área privada, redigindo
qualquer `token`. Só responde 2xx depois de gravar o inbox durável. A política
de retry do provedor continua desconhecida e é um portão de teste.

## 7. Identificadores

### 7.1 Fatos Uazapi

| Campo | Significado publicado | Observação de contrato | Evidência oficial |
|---|---|---|---|
| `Instance.id` | ID único da instância | schema diz `uuid`, exemplos usam valores iniciados por `r`; não validar formato | [OpenAPI][oas], `components.schemas.Instance` |
| `Message.id` | ID interno da mensagem | schema diz `uuid`, descrição diz `r` + caracteres e exemplos variam; não usar como ID WhatsApp | [OpenAPI][oas], `components.schemas.Message` e `/message/find` |
| `Message.messageid` | ID original da mensagem no provedor | chave preferida para dedupe/correlação de mensagem | [OpenAPI][oas], `components.schemas.Message` |
| `Message.chatid` | ID da conversa relacionada | formato não é restringido no schema | [OpenAPI][oas], `components.schemas.Message` |
| `Message.sender` | ID do remetente | string opaca | [OpenAPI][oas], `components.schemas.Message` |
| `Message.sender_pn` | JID PN resolvido, se disponível | pode estar ausente | [OpenAPI][oas], `components.schemas.Message` |
| `Message.sender_lid` | LID original, se disponível | não converter em telefone por heurística | [OpenAPI][oas], `components.schemas.Message` |
| `Chat.id` | ID interno do chat | não confundir com JID | [OpenAPI][oas], `components.schemas.Chat` |
| `Chat.wa_chatid` | ID completo do chat no WhatsApp | provider conversation ID | [OpenAPI][oas], `components.schemas.Chat` |
| `Chat.wa_chatlid` | LID do chat, quando disponível | alias do provedor | [OpenAPI][oas], `components.schemas.Chat` |
| `track_id` | ID livre de rastreamento | duplicatas são aceitas | [OpenAPI][oas], tag `Enviar Mensagem` |

Destinos aceitos em envio incluem número internacional, JID individual
`@s.whatsapp.net` ou `@lid`, grupo `@g.us` e newsletter `@newsletter`.
Evidência: [OpenAPI][oas], request de `/send/text` e `/send/media`.

### 7.2 Decisão GrillStudio

- Todos os IDs do provedor são strings opacas, case-sensitive e sem parsing
  estrutural além da classificação conservadora do sufixo.
- A chave da conexão é o UUID interno do GrillStudio; `instance.id` é atributo
  externo e nunca substitui `connection_id`.
- A chave natural de mensagem é
  `(connection_id, provider_message_id=Message.messageid)`.
- A chave de conversa do provedor é `Message.chatid` ou `Chat.wa_chatid`; a
  conversa interna é `(connection_id, provider_chat_id)`.
- `sender_pn`, `sender_lid` e aliases observados ficam em uma tabela de aliases.
  Nenhum LID é transformado em telefone sem dado explícito do provedor.
- `Message.id` pode ser armazenado como `provider_internal_message_id` para
  operações auxiliares, nunca como chave de dedupe intersistema.
- Se um inbound não trouxer `messageid`, ele é persistido como
  `unsupported_missing_provider_id`; não dispara turno autônomo.

## 8. Mensagens de entrada e saída

### 8.1 Entrada

O schema `Message` documenta os campos:

```text
id, messageid, chatid, sender, senderName, isGroup, fromMe,
messageType, source, messageTimestamp, status, text, quoted,
edited, reaction, vote, convertOptions, owner, error, content,
wasSentByApi, sendFunction, sendPayload, fileURL, track_source,
track_id, sender_pn, sender_lid
```

`content` e `sendPayload` podem ser objeto aberto ou string. `messageType` não
tem enum. Evidência: [OpenAPI][oas], `components.schemas.Message`.

Como o OpenAPI não liga explicitamente esse schema ao corpo real do evento
`messages`, o normalizador:

1. preserva o payload bruto;
2. aceita aliases/casing somente por fixtures aprovadas;
3. exige, para mensagem processável, `messageid`, chat, direção, timestamp e
   conteúdo/tipo reconhecível;
4. classifica payload novo como `unsupported` sem descartá-lo;
5. nunca tenta responder a grupo, newsletter, status ou mensagem de origem
   ambígua.

Envelope normalizado mínimo:

```text
InboundMessage {
  connection_id
  provider = "uazapi"
  provider_message_id
  provider_internal_message_id?
  provider_chat_id
  sender_id
  sender_pn?
  sender_lid?
  from_me
  is_group
  occurred_at
  kind = text | image | document | audio | video | reaction | edit | delete | unknown
  text?
  reply_to_provider_message_id?
  attachment_ref?
  raw_payload_ref
}
```

Esse é o contrato GrillStudio, não uma alegação sobre o envelope bruto da
Uazapi.

### 8.2 Saída

| Tipo MVP | Endpoint | Obrigatórios | Opcionais usados | Evidência oficial |
|---|---|---|---|---|
| Texto | `POST /send/text` | `number`, `text` | `replyid`, `track_source`, `track_id`, `async` | [OpenAPI][oas], `paths./send/text.post` |
| Imagem/PDF | `POST /send/media` | `number`, `type`, `file` | `text`, `docName`, `mimetype`, `replyid`, `track_source`, `track_id`, `async` | [OpenAPI][oas], `paths./send/media.post` |

Embora `/send/media` publique `image`, `video`, `videoplay`, `document`,
`audio`, `myaudio`, `ptt`, `ptv` e `sticker`, o envio autônomo do MVP fica
limitado a `image` e `document`, que correspondem aos materiais aprovados do
produto. A lista completa é fato Uazapi em [OpenAPI][oas],
`paths./send/media.post.requestBody...properties.type.enum`; o recorte é decisão
GrillStudio.

Decisões de envio:

- sempre `async=false`: o GrillStudio já possui outbox/fila durável e não deve
  empilhar uma segunda fila opaca;
- não usar `/sender/*`: campanhas e ondas pertencem à fila, à idempotência, aos
  portões de capacidade e à auditoria do GrillStudio, não ao mecanismo de envio
  em massa do provedor. Evidência da superfície do provedor: [OpenAPI][oas],
  caminhos `/sender/*`;
- sempre `delay=0` ou campo omitido: atraso humano pertence a
  `scheduled_jobs`, não ao request externo;
- `track_source="grillstudio"` e `track_id=<messages.id>` para reconciliação,
  nunca como garantia de unicidade;
- destinatário deriva da conversa fixa à conexão; não há fallback para outro
  número;
- o comando é persistido antes da chamada e revalida opt-out, ownership,
  horário, capacidade e saúde imediatamente antes;
- resposta 200 é redigida, preservada e lida como um `Message`; o
  `messageid` retornado é gravado como ID externo.

Com `async=true`, a própria documentação avisa que 200 significa apenas entrada
na fila e que o envio pode falhar depois. Evidência: [OpenAPI][oas], descrição
da tag `Enviar Mensagem` e `GET /message/async`.

## 9. Mídia

### 9.1 Fatos Uazapi

- `/send/media` aceita URL ou base64 em `file`.
- Tipos publicados: imagem, vídeo, variações de áudio/vídeo, documento e
  sticker.
- Imagem recomenda JPG; vídeo documenta somente MP4; áudio comum documenta MP3
  ou OGG; documentos incluem PDF/DOCX/XLSX como exemplos.
- O endpoint pode responder 413 para arquivo grande e 415 para formato não
  suportado, mas não publica bytes máximos por tipo.
- `/message/download` recebe um `id` e pode devolver `fileURL`, `mimetype`,
  `base64Data` e transcrição conforme flags.
- A descrição de `/message/download` chama `id` de “ID da mensagem”, sem dizer
  se é `Message.id` ou `Message.messageid`.
- Por default, `/message/download` converte áudio para MP3 e devolve URL
  pública. A Uazapi declara retenção dessa mídia em seu storage por dois dias;
  depois remove o arquivo e o link deixa de funcionar, embora novo download
  possa buscar novamente no CDN.
- Se `openai_apikey` for enviado a `/message/download`, a descrição afirma que
  a chave é atualizada e salva na instância para chamadas seguintes.

Evidência: [OpenAPI][oas], `paths./send/media.post` e
`paths./message/download.post`.

A descrição de conexão diz que mensagens dos últimos sete dias ficam no banco
da Uazapi e são removidas depois. Essa retenção de mensagens por sete dias é
distinta da retenção de mídia baixada por dois dias. Evidência: [OpenAPI][oas],
`paths./instance/connect.post.description` e
`paths./message/download.post.description`.

### 9.2 Decisão GrillStudio

Saída:

- `file` usa URL HTTPS assinada, curta e de host de Storage permitido; URLs
  arbitrárias fornecidas por lead ou usuário não são repassadas;
- MIME, extensão, hash e tamanho são validados antes do envio;
- o material continua no bucket privado canônico; resposta `fileUrl` da Uazapi
  é metadado transitório, não URL canônica;
- base64 não é usado no envio normal para evitar payload/log/memória excessivos.

Entrada:

- nunca depender de `fileURL` como armazenamento;
- baixar em worker isolado, com limite de tempo/tamanho, validação de MIME,
  hash e proteção contra SSRF;
- copiar para bucket privado e descartar URL/base64 transitórios;
- não solicitar transcrição da Uazapi nem enviar `openai_apikey`;
- enquanto a ambiguidade de `id` e os limites não forem testados, mídia inbound
  pode ser persistida como pendente/unsupported, mas não alimenta IA autônoma.

## 10. Receipts e estados

### 10.1 Fatos Uazapi

O evento configurável para atualizações é `messages_update`. O schema
`Message.status` fornece exemplos comuns, não um enum fechado:

```text
Queued
Canceled
Failed
Sent
Delivered
Read
```

Evidência: [OpenAPI][oas], `paths./webhook.post` e
`components.schemas.Message.properties.status`.

Não estão documentados:

- corpo real de `messages_update`;
- campo/tipo do timestamp da atualização;
- progressão monotônica;
- receipt separado por destinatário;
- evento único por atualização;
- tratamento de status desconhecido;
- se `excludeMessages=["wasSentByApi"]` afeta `messages_update`.

### 10.2 Decisão GrillStudio

| Raw, sem diferença de caixa | Status `messages` | Regra |
|---|---|---|
| `queued` | `queued` | ainda sem confirmação de envio |
| `sent` | `sent` | provider aceitou/enviou |
| `delivered` | `delivered` | avança a partir de queued/sent |
| `read` | `read` | estado positivo mais forte |
| `failed` | `failed` | terminal se ainda não delivered/read |
| `canceled` | `failed` | guardar razão raw `provider_canceled` |
| outro | sem transição | guardar receipt raw e marcar `unsupported_status` |

Cada atualização gera evento append-only com raw status e payload. O status
materializado nunca regride de `read`/`delivered` para `sent`; falha posterior a
delivery/read vira anomalia, não regressão.

Chave de efeito do receipt:

```text
receipt:{connection_id}:{provider_message_id}:{normalized_status}
```

Se houver timestamp confiável em fixture futura, ele é metadado, não necessário
para tornar a transição idempotente. Repetições da mesma transição não produzem
novo efeito.

## 11. Reconexão, logout, reset e exclusão

| Ação | Endpoint | Semântica documentada | HTTP relevantes | Evidência oficial |
|---|---|---|---|---|
| Desconectar/logout | `POST /instance/disconnect` | encerra sessão, limpa credenciais e exige novo QR | 200/401/404/500 | [OpenAPI][oas], operação correspondente |
| Recuperar runtime | `POST /instance/reset` | tenta recuperar sessão sem apagar o registro | 200/400/401/403/409/500 | [OpenAPI][oas], operação correspondente |
| Consultar | `GET /instance/status` | estado, flags, JID e última desconexão | 200/401/404/500 | [OpenAPI][oas], operação correspondente |
| Excluir | `DELETE /instance` | desconecta e remove a instância do banco da Uazapi | 200/401/404/500 | [OpenAPI][oas], operação correspondente |

`reset` retorna 200 tanto para reset iniciado quanto para “já em andamento” ou
cooldown; os campos `resetting`, `instanceId` e `queuedRecoveryAttempted`
distinguem os casos. 403 indica bloqueio pela política de reconexão e 409,
sessão não recuperável. Evidência: [OpenAPI][oas],
`paths./instance/reset.post`.

Embora `hibernated` seja estado publicado, não existe endpoint de hibernação nos
caminhos oficiais. Reconexão automática de uma instância individual também não
é prometida como contrato. Evidência: [OpenAPI][oas], enum de `Instance.status`
e lista de `paths`.

Decisão:

1. `connection` ou health check degradado abre circuito e pausa novos envios;
2. reconciliar com `GET /instance/status`;
3. se sessão existente estiver presa, permitir reset controlado e observar o
   status;
4. 403/409 ou `disconnected` exigem intervenção do dono e novo pareamento;
5. nunca trocar automaticamente a conversa para outra conexão;
6. disconnect e delete são ações explícitas, auditadas e exclusivas do dono;
7. delete nunca é tentativa de recuperação.

## 12. Erros e política de retry

### 12.1 HTTP documentado

| Operação | Códigos publicados |
|---|---|
| criar instância | 200, 401, 404, 500 |
| conectar | 200, 401, 404, 429, 500, 503 |
| status/desconectar | 200, 401, 404, 500 |
| reset | 200, 400, 401, 403, 409, 500 |
| excluir | 200, 401, 404, 500 |
| configurar webhook | 200, 400, 401, 500 |
| enviar texto | 200, 400, 401, 429, 500 |
| enviar mídia | 200, 400, 401, 413, 415, 500 |
| buscar mensagem | 200, 400, 401, 404, 500 |
| baixar mídia | 200, 400, 401, 404, 500 |

Evidência: [OpenAPI][oas], `responses` das operações citadas.

Não há envelope comum de erro. Em especial, envio de texto documenta um erro
500 que pode representar recusa do WhatsApp com
`error_source="whatsapp_server"`, `provider_code=463` e diagnóstico em
`GET /instance/wa_messages_limits`. Evidência: [OpenAPI][oas],
`paths./send/text.post.responses.500` e
`paths./instance/wa_messages_limits.get`.

`POST /instance/connect` documenta `Retry-After` em segundos para 503. O 429 de
envio de texto não documenta janela, quota ou headers. Evidência:
[OpenAPI][oas], respostas de `/instance/connect` e `/send/text`.

### 12.2 Classificação GrillStudio

| Categoria | Exemplos | Ação |
|---|---|---|
| `auth` | 401; 403 administrativo | abrir circuito, redigir erro, pedir correção ao dono; sem retry |
| `invalid` | 400, 404 de destino/instância, 413, 415 | falhar comando; sem retry automático |
| `conflict` | 409 de reset | reconciliar estado; não repetir comando antigo |
| `rate_limited` | 429 | respeitar `Retry-After` se existir; sem header, backoff com jitter e circuito |
| `temporarily_unavailable` | 503 de connect, timeout antes de enviar bytes | retry limitado; `Retry-After` prevalece |
| `provider_error` | 5xx | reconciliar antes de qualquer retry com efeito |
| `whatsapp_restriction` | 500 + `error_source=whatsapp_server`/463 | não retry; consultar diagnóstico e pausar proativas |
| `unknown_outcome` | timeout/reset da conexão depois de request enviado | **não reenviar automaticamente**; reconciliar/alertar |

O corpo raw de erro fica privado e redigido. O domínio recebe código estável,
HTTP, `retryable`, `outcome_known`, `provider_code?`, `retry_after?` e
`raw_ref`, não mensagens soltas como regra de negócio.

## 13. Rate limits e limites funcionais

### 13.1 O que é fato

- Há máximo de instâncias conectadas por servidor, sem quantidade publicada;
  ao atingir o limite, conexão responde 429.
- Servidores free/demo podem ter restrições adicionais de tempo de vida.
- `/send/text` e alguns outros endpoints publicam 429, sem quantidade, janela ou
  headers.
- `/instance/wa_messages_limits` diagnostica limites do próprio WhatsApp para
  iniciar novas conversas. Isso é diferente do rate limit HTTP da Uazapi.
- A fila `async=true` possui delay configurável, mas isso não constitui quota
  nem garantia anti-ban.

Evidência: [OpenAPI][oas], `info.description`, `/instance/connect`,
`/send/text`, `/instance/wa_messages_limits`, `/message/async` e
`/instance/updateDelaySettings`.

### 13.2 Decisão

- Limite da Uazapi é `unknown`; não prometer throughput.
- O GrillStudio aplica seus próprios limites por conexão, campanha e conversa,
  além das regras 10/25/30 do produto.
- Qualquer 429 reduz concorrência e abre backoff compartilhado da conexão.
- `can_send_new_messages=false` pausa campanhas, reativações e follow-ups;
  inbound e mensagens de continuidade são avaliados separadamente pela política
  do produto.
- Valores operacionais finais de concorrência e RPS só podem ser promovidos
  após resposta oficial ou teste sintético autorizado.

## 14. Idempotência e reconciliação

### 14.1 Fato Uazapi

Não existe `Idempotency-Key` ou campo equivalente no OpenAPI. `track_id` é
apenas correlação e aceita valores duplicados. A resposta 200 com `async=true`
também não prova envio final. Evidência: [OpenAPI][oas],
`components.securitySchemes`, requests de envio e descrição da tag
`Enviar Mensagem`.

`POST /message/find` aceita busca por `id`, `chatid`, `track_source` e
`track_id`. O texto geral da tag sugere buscar `status=failed`, mas o schema da
operação não contém parâmetro `status`; o contrato confiável fica restrito aos
quatro filtros efetivamente publicados no request schema. Evidência:
[OpenAPI][oas], `paths./message/find.post` e tag `Enviar Mensagem`.

### 14.2 Contrato de efeito único do GrillStudio

Inbound:

```text
inbound-message:{connection_id}:{provider_message_id}
receipt:{connection_id}:{provider_message_id}:{normalized_status}
connection-event:{connection_id}:{sha256(canonical_payload)}
```

Outbound:

```text
send:{internal_message_id}
```

Fluxo de envio:

1. criar `messages` + outbox na mesma transação;
2. adquirir a chave `send:{message_id}`;
3. revalidar política;
4. chamar uma única vez com `track_id=<message_id>`;
5. em sucesso, guardar `messageid` da Uazapi;
6. em falha inequivocamente anterior ao envio, permitir retry limitado;
7. em resultado incerto, consultar `/message/find` por
   `track_source/track_id`, esperar reconciliação e alertar;
8. se ainda for impossível decidir, não reenviar sem revisão humana.

Encontrar mensagem por `track_id` prova correlação, não unicidade. Se mais de um
resultado existir, registrar incidente de duplicidade e consolidar pelos
`messageid` distintos; nunca esconder o segundo envio.

## 15. Bloqueios e mínimo necessário

Esses itens não têm resposta confiável na fonte oficial consultada.

| Bloqueio exato | Risco | Mínimo necessário para fechar | Aceite objetivo |
|---|---|---|---|
| Autenticidade de webhook não documentada | webhook forjado pode criar contato, mensagem ou resposta | confirmação primária da Uazapi do mecanismo suportado (header, algoritmo, segredo/rotação e canonicalização); se não existir, decisão explícita de risco + controle compensatório aprovado | fixture assinada válida aceita; assinatura ausente/inválida/replay rejeitados |
| Payloads `messages`, `messages_update`, `connection` e `history` abertos/inconsistentes | parser quebra ou interpreta ID/status errado | schemas oficiais versionados ou uma instância **de teste** com número sintético/autorizado para capturar fixtures redigidas desses quatro eventos | fixtures cobrem texto, mídia, receipt, desconexão/reconexão e duplicata |
| Provider event ID ausente | dedupe de webhook genérico pode colidir | campo oficial estável por evento ou confirmação de que a chave natural por mensagem/status é o único mecanismo disponível | storm de 10 entregas produz um efeito |
| Ack/retry de webhook não documentado | perda quando nosso banco falha, ou storm desconhecida | documentação oficial de timeout, códigos aceitos, número de tentativas e backoff; alternativamente teste controlado retornando 2xx/4xx/5xx | comportamento medido e registrado sem dado real |
| `messages_update` + `excludeMessages` sem semântica | receipts podem ser filtrados junto do outbound | confirmação oficial ou fixture de envio sintético com `wasSentByApi` excluído | `Sent/Delivered/Read/Failed` continuam chegando |
| `Message.id` versus `messageid` em `/message/download` | download usa ID errado | confirmação oficial ou fixture de mídia sintética | download funciona com ID explicitamente escolhido |
| Limites numéricos de mídia não publicados | memória, custo ou rejeição tardia | tabela oficial por tipo ou teste sintético com arquivos mínimos/limítrofes, sem conteúdo real | máximos e MIME aceitos registrados; retenção publicada de dois dias preservada |
| Rate limit quantitativo ausente | throughput inseguro e retries coordenados mal dimensionados | limites oficiais do plano/instância de teste e headers de 429 | janela, quota e retry definidos |
| Idempotência do provedor ausente | duplicata após timeout | confirmação oficial de chave idempotente futura; até lá, manter proibição de resend incerto | teste de timeout não duplica ou cai em revisão |
| Reconexão automática individual não prometida | suposição de recuperação deixa conexão parada | política oficial ou cenário de teste de perda/restart/reset | transições e intervenção necessárias documentadas |

O mínimo de acesso, caso documentação não seja fornecida, é **uma única
instância sandbox da Uazapi capaz de emitir eventos entre identidades
sintéticas do próprio ambiente, sem lead, número ou credencial real**. São
suficientes uma URL e credenciais efêmeras do sandbox; somente se o sandbox
testar criação ele precisa oferecer um `admintoken` também efêmero. Nenhuma
credencial deve ser colocada em issue, arquivo, comando versionado ou chat; deve
ser injetada pelo cofre do executor. Se a Uazapi não oferecer sandbox sem
números reais, o mínimo aceitável volta a ser a documentação/schema oficial,
sem teste autenticado.

Não é necessário acesso a produção, contatos reais, números reais da operação,
campanhas, histórico ou credenciais atuais para resolver esses bloqueios.

## 16. Matriz de cobertura

| Área pedida | Fato oficial mapeado | Decisão normalizada | Situação |
|---|---:|---:|---|
| Base URL/versionamento | sim | sim | fechado com detecção de drift |
| `admintoken`/`token` e headers | sim | sim | fechado; rotação de token de instância desconhecida |
| Criação de instância | sim | sim | fechado documentalmente |
| Conexão existente | sim | sim | fechado documentalmente |
| QR Code/código de pareamento | sim | sim | fechado documentalmente |
| Estados da instância | sim | sim | fechado documentalmente |
| Configuração/lista de eventos webhook | sim | sim | fechado |
| Autenticidade do webhook | não | compensação apenas | bloqueio de produção |
| Payloads webhook | parcial e inconsistente | parser tolerante | fixtures obrigatórias |
| IDs | parcial, com contradições de formato | opacos + chave natural | fechado conservadoramente |
| Mensagem inbound | schema genérico | envelope mínimo | fixture obrigatória |
| Texto outbound | sim | sim | fechado documentalmente |
| Mídia outbound | tipos sim; limites não | recorte imagem/PDF | limites pendentes |
| Mídia inbound/download | retenção sim; ID/limites parciais | storage privado | ID/tamanhos pendentes |
| Receipts | evento/status parcial | máquina monotônica | fixture obrigatória |
| Reconexão/reset/logout/delete | parcial | sim | auto-reconexão pendente |
| Erros HTTP | por endpoint | categorias estáveis | fechado, envelope não uniforme |
| Rate limits | existência, sem números | backoff/circuito | valores pendentes |
| Idempotência | ausência/duplicata de `track_id` | inbox/outbox + no resend incerto | fechado do nosso lado; sem garantia do provedor |
| Evidência reproduzível | sim | — | público, sem segredo |

## 17. Evidências reproduzíveis e seguras

Todos os comandos abaixo são GET/HEAD públicos, não usam credenciais e não
tocam instância:

```bash
# Metadados HTTP do snapshot oficial
curl -fsSI https://docs.uazapi.com/openapi-bundled.json

# Versões, servidor e autenticação
curl -fsSL https://docs.uazapi.com/openapi-bundled.json |
  jq '{openapi, info, servers, securitySchemes: .components.securitySchemes}'

# Hash do documento consultado
curl -fsSL https://docs.uazapi.com/openapi-bundled.json |
  shasum -a 256

# Inventário de operações, tags e summaries
curl -fsSL https://docs.uazapi.com/openapi-bundled.json |
  jq -r '.paths | to_entries[] as $p |
    $p.value | to_entries[] |
    select(.key | IN("get","post","put","patch","delete")) |
    [$p.key, .key, (.value.operationId // ""),
     (.value.tags // [] | join(",")), (.value.summary // "")] | @tsv'

# Schemas centrais sem exemplos de credenciais reais
curl -fsSL https://docs.uazapi.com/openapi-bundled.json |
  jq '{Instance: .components.schemas.Instance,
       Message: .components.schemas.Message,
       Chat: .components.schemas.Chat,
       Webhook: .components.schemas.Webhook,
       WebhookEvent: .components.schemas.WebhookEvent}'

# Operações do contrato MVP
curl -fsSL https://docs.uazapi.com/openapi-bundled.json |
  jq '{create: .paths["/instance/create"].post,
       connect: .paths["/instance/connect"].post,
       status: .paths["/instance/status"].get,
       webhook: .paths["/webhook"],
       send_text: .paths["/send/text"].post,
       send_media: .paths["/send/media"].post,
       find: .paths["/message/find"].post,
       download: .paths["/message/download"].post,
       reset: .paths["/instance/reset"].post}'
```

Não executar exemplos autenticados da documentação contra `free`, `api` ou
qualquer URL fornecida por cliente durante pesquisa. O próximo passo permitido
é obter as respostas primárias da seção 15 ou aprovar formalmente a sandbox
sintética mínima descrita ali.

[docs]: https://docs.uazapi.com/
[oas]: https://docs.uazapi.com/openapi-bundled.json
