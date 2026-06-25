# iMetaClaw / Maia on Glasses — Exact App-Side Facts for Client Install Guide (A)

This is the authoritative "what the end user actually does and sees" for the iPhone app part.
Only the iOS app (Grok/Pedro side) knows these screens and flows.

## One App, One Experience (simpleMode / iMetaClaw branding)

- The build is branded iMetaClaw.
- In `Config.simpleMode` (or `isOpenClawExclusive` / phoneAIStrategy = .vpsOnly) many local AI options, model pickers, and LLM settings are hidden or disabled.
- The app becomes a thin reliable terminal: mic + camera from Ray-Ban Meta → stream to Maia on your VPS → Maia voice + actions back.

## How the Cliente (A) connects (exact steps in the UI)

1. Install the app (TestFlight or ad-hoc .ipa from the operator).
2. On launch or go to **Settings → Gateways** (or the first-run gateway card).
3. Add / edit a gateway:
   - Name: e.g. "Minha Maia"
   - Tunnel URL (or LAN URL if on same network): the public address that Caddy exposes for the Maia Command Center (usually https://your-vps or the tunnel).
   - Token: exactly the value of `OPENCLAW_TOKEN` from `/opt/maia/.env` on the VPS.
   - Mode: Tunnel (or Auto).
   - Save.
4. The status pill / connection banner in VoiceTab or main screen must show **green + "connected" + wsReady**.
   - If orange/red: the iPhone could not reach the WS. Common fixes are in the error text (wrong token, Caddy not proxying :3600, firewall).
5. Pair the Ray-Ban Meta glasses normally (Bluetooth). The app uses the MWDAT camera + audio stream directly.
6. Wake word in practice: user says **"Oi Maia"** (or just speaks). Local transcription (Sherpa or on-device) + the text + optional latest valid glasses frame (as imageBase64) is sent to Maia via the persistent `sessions.send`.
7. Maia replies in voice (ElevenLabs or configured TTS flows back).
8. Maia can also drive the glasses using `node.invoke` (control plane):
   - capture_photo → returns imageBase64
   - start_video / stop_video
   - record_audio / stop_audio
   - start_translation / stop_translation (live on-device translate + speak)
   - transcribe_start (reuniao or consulta) / transcribe_stop (ambient captions)
   - status (battery, active modes, streaming)
   - generic "pare" / "stop" stops whatever is running

## Important behavioral notes for the guide (do not promise more)

- "Gravar vídeo": works in the app layer on top of the raw glasses camera frame stream + mic. Produces normal MP4. No hard time limit in the recorder. Real-world duration depends on the underlying Meta glasses Bluetooth session staying alive + battery/heat. The glasses LED will be on. This is **not** the same as native Meta View video recording (different cloud behavior, possibly different power profile). Mark as "funciona, teste na prática".
- Translation and transcription started via node.invoke run locally on the phone (good quality, any language for our path). The spoken results (translation) are played via TTS. Caption history is collected for "get_transcript".
- The mic audio/text is continuously available to Maia as long as the WS is up and the user is speaking (or ambient is active). No extra node.invoke needed for the data flow itself.
- To stay alive in pocket: the app uses background audio session (via WakeWordService). Best results when the app is not force-killed.
- Battery: status command reports iPhone %. Glasses battery is not exposed through the current 3rd-party camera stream — user still uses Meta View app for that.

## Status indicators the user sees

- Top connection banner or VoiceTab pill: green = wsReady && .connected → ready for "Oi Maia" and for Maia to call node.invoke.
- When recording (audio or video) started by Maia or locally: UI shows isRecording + duration.
- Translation active: the LiveTranslationService state can be surfaced if UI is extended.

## What the operator must give the client

- The single signed/TestFlight iMetaClaw app (already contains the full glasses handler, video/audio recorders, live translation, ambient captions, and persistent OpenClaw bridge).
- The exact Tunnel (or LAN) URL that points to the Caddy fronting the Maia Command Center (usually the one on :3600).
- The value of `OPENCLAW_TOKEN` from `/opt/maia/.env`.
- Instructions: "After installing, go to Settings → Gateways, put the URL + token, save, wait for the green 'Maia pronta — HTTP + WebSocket OK' pill. Pair your Ray-Ban Meta. Then just say 'Oi Maia'."

---

## Ready-to-paste blocks for the VPS living draft

### Block for Catálogo (replace the video part and add the technical note)

✅ Dá pra fazer (o que importa pra Maia):
- Tirar foto / visão (pronto, devolve imageBase64)
- Ouvir (STT local + stream contínuo pro Maia)
- Falar (TTS de volta)
- Gravar áudio + nota, transcrever reunião/consulta + salvar, tradução ao vivo de qualquer idioma (via mic + Maia; qualidade e idiomas melhores que o nativo da Meta)
- Gravar vídeo ⚠️ (funciona sobre o stream cru da câmera dos óculos + áudio muxado. Sem limite artificial de tempo no app. Duração real depende da sessão Bluetooth da Meta + bateria/termal. LED dos óculos fica aceso. Não é idêntico ao gravador nativo da Meta View. Testar na prática.)

🔴 Parede do Meta (não dá pra app de terceiro – não vamos prometer):
- "Hey Meta" / Meta AI nativa (por isso usamos "Oi Maia")
- Música, chamadas, navegação nativa, legendas/tradução do Meta, modelo Display (tela/pulseira neural)

Descoberta técnica boa:
Tradução ao vivo e transcrição de ambiente **não precisam de node.invoke para o fluxo de dados**. O app só precisa manter o stream do microfone/texto enviando continuamente para a Maia via o canal de voz/sessão. O node.invoke é usado apenas para controle (iniciar/parar os modos). Isso simplifica bastante o lado do servidor.

### Block for (A) Cliente – passos exatos nas telas do app (substitui os [Grok/Pedro])

**(A) Cliente** — o que a pessoa faz no iPhone:

1. Instala o app iMetaClaw (via TestFlight ou .ipa fornecido pelo operador).  
   O build já vem com tudo embutido (handler de node.invoke, gravação de vídeo/áudio, tradução, legendas ambiente e ponte persistente com a Maia).

2. Abre o app pela primeira vez ou vai em **Ajustes → Gateways**.

3. Adiciona ou edita o gateway:
   - Nome: "Minha Maia" (ou o que quiser)
   - Tunnel URL (ou LAN URL): o endereço que o Caddy expõe para o Maia Command Center (o mesmo que você usa no contrato atual, tipicamente apontando para :3600)
   - Token: exatamente o valor de `OPENCLAW_TOKEN` que está em `/opt/maia/.env` no VPS
   - Modo de conexão: Tunnel (ou Auto)
   - Salva

4. Aguarda o indicador de status ficar verde:
   - Pílula / banner mostra círculo verde + texto **"Maia pronta — HTTP + WebSocket OK"**
   - Se aparecer laranja: "HTTP OK — WebSocket pendente (aprovar device no VPS)"
   - Vermelho: "Gateway offline para o iPhone"
   - Detalhes do último erro aparecem logo abaixo (copiáveis).

5. Pareia os Ray-Ban Meta normalmente pelo Bluetooth do iPhone.  
   O app usa o stream de câmera e microfone dos óculos diretamente (MWDAT).

6. Fala com a Maia:
   - Diz **"Oi Maia"** (ou simplesmente fala). 
   - O app transcreve localmente (boa qualidade em pt-BR) e envia o texto + (se válido) o último frame da câmera para a Maia via o socket persistente.
   - A Maia responde em voz.

7. A Maia pode comandar os óculos (via node.invoke):
   - "tira uma foto" / "o que você vê?" → capture_photo (retorna imageBase64)
   - "grava um vídeo" / "para o vídeo"
   - "grava um áudio" / "anota isso" / "para de gravar"
   - "modo tradução" / "para a tradução"
   - "modo reunião" / "transcreve isso" / "transcreve consulta" / "encerra a reunião"
   - "quanto de bateria?" / "status"
   - Qualquer "pare" ou "para" genérico para desligar o que estiver ativo

8. O app mantém o socket aberto em segundo plano usando a sessão de áudio (para wake word e gravações continuarem vivas quando o telefone está no bolso).

**Observações importantes para o cliente (não prometa mais que isso):**
- Gravar vídeo funciona, mas duração real depende do stream dos óculos + bateria. LED fica ligado.
- Tradução e transcrição de ambiente rodam localmente no telefone (qualquer idioma no nosso caminho).
- Bateria reportada no status é do iPhone. Bateria dos óculos continua sendo vista no app oficial da Meta.
- Se o pílula não ficar verde: problema quase sempre é token errado, Caddy não apontando para :3600, ou device ainda não aprovado no VPS.

### Nota sobre a extensão/script do Pedro

A parte cliente (o que roda no iPhone) já está 100% dentro do binário do app (OpenClawBridge + serviços de câmera/áudio/vídeo/tradução).

O script/extensão que o Pedro está construindo é do lado do servidor (o handler de node.invoke dentro da Maia + o "glasses channel").

Recomendação: quando o script estiver pronto, documente-o em uma seção separada (ex: "Ativando o canal dos óculos na sua Maia") e referencie-o no guia. Idealmente o operador roda um comando simples no VPS para habilitar o canal. Depois podemos discutir se vale embutir algum helper leve no build do app.

---

Fim dos blocos prontos. Cole onde estavam os [Grok/Pedro] e remova os marcadores.

- The single app (embedded everything).
- The tunnel address (the one Caddy fronts to the Maia :3600 endpoint).
- The exact `OPENCLAW_TOKEN` value.
- (Later) the glasses-bridge script or "how to enable glasses channel on your Maia" once Pedro delivers it.

## Files / screens only the app team knows (for the draft)

- GatewaySettingsView.swift + AddGatewaySheet (the exact fields above)
- VoiceTab.swift (connection banner, "Agente" tab in simpleMode)
- OpenGlassesApp.swift + LLMService (the routing logic that forces vpsOnly)
- OpenClawBridge.swift (the persistent WS + full node.invoke handler + imageBase64 + sessions.send)
- CameraService + AudioRecordingService + VideoRecordingService + LiveTranslationService + AmbientCaptionService (the services Maia can start/stop)

This is the "partes que só o Grok/Pedro sabem".

When the server-side extension lands, the operator just tells the client "your app already has everything — just make sure the Gateway token is set and the pill is green".

## Quick test the client can do (after token)

- Say "Oi Maia, o que você vê?" → photo + describe
- "Oi Maia, grava um áudio" ... speak ... "pare"
- "Oi Maia, modo tradução" → speak foreign → hears translation
- "Oi Maia, transcreve a reunião" ... later "pare"
- "Oi Maia, quanto de bateria?" → gets status with battery

All of the above are implemented and return proper res to Maia when the socket is stable.

---

Update this file as the app evolves. The living draft on the VPS should reference these facts instead of guessing the screens.