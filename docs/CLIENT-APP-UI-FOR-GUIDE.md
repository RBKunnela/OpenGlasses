# iMetaClaw / Maia on Glasses — Exact App-Side Facts for Client Install Guide (A)

**Critical reality (official Meta Wearables Device Access Toolkit as of mid-2026):**

Meta strictly limits third-party access. Glasses are a Bluetooth peripheral. All intelligence lives on the phone or your remote agent (Maia). The phone app is the **mandatory middleman**. You cannot run code on the glasses, bypass the official Meta AI companion app for pairing, disable the LED, replace native "Hey Meta", or deeply control firmware.

The sanctioned path (what this app does):
- Use official MWDAT SDK (MWDATCore + MWDATCamera + MWDATDisplay).
- Stream camera frames + mic to your agent in real time (must process on phone or forward immediately).
- Receive commands from agent and execute via SDK (capture, play audio on open-ear speakers, push HUD overlays on Display models).
- Requires the official Meta AI / Meta View app installed for pairing + Developer Mode.

This app (iMetaClaw) implements exactly the recommended "phone bridge + external agent orchestrator" pattern. Your Telegram/Maia agent controls everything the hardware exposes, without fighting Meta's sandbox.

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
8. Maia can also drive the glasses using `node.invoke` (control plane) — now covering **all major SDK-accessible I/O**:
   - capture_photo → returns imageBase64 (for vision/describe)
   - start_video / stop_video, record_audio / stop_audio
   - start_translation / stop_translation (on-device, speaks back)
   - transcribe_start (reuniao or consulta) / transcribe_stop (ambient captions)
   - show_text / push_display / show_notification / clear_display → pushes text, title+body, icon overlays or notifications directly to the in-lens HUD (on supported Display models)
   - speak / play_audio (explicit voice output from agent)
   - status / get_glasses_status (now includes display capability, active modes, streaming, iPhone battery)
   - generic "pare" / "stop" (stops recordings + clears HUD)

   The app acts as the official SDK bridge. Maia (remote) fully orchestrates vision input, audio I/O, recordings, translation, live transcription, and HUD output on the lens. Continuous mic/text and on-demand frames stream to Maia; commands come back via the bidirectional WS + node.invoke. This is the recommended architecture per Meta SDK docs and community (phone middleman + external agent).

## Alignment to updated server contract (NODE-INVOKE-CONTRACT-FOR-GROK + capabilities)

The app now implements:
- `device.capabilities` query (reports dynamic list: always vision/audio/recording/status + display_* only if hardware `device.supportsDisplay()` via official SDK).
- `display_show` / `display_clear` / `display_caption_*` (maps to GlassesDisplayService + ambient for live captions on lens).
- `device.event` push (fire-and-forget on same WS for connection, can extend for battery/gesture/wear).

This matches the multi-tenant, hardware-agnostic contract with degradation.

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
- Tirar foto / visão (pronto — devolve imageBase64 limpo, sem 1x1)
- Ouvir (STT local bom em pt-BR + stream contínuo)
- Falar (resposta em voz)
- Gravar áudio + nota, transcrever reunião/consulta + salvar, tradução ao vivo de qualquer idioma (nossa stack via mic + Maia — cobre muito mais que o nativo da Meta)
- Gravar vídeo ⚠️ (funciona: usa o stream cru da câmera dos óculos + áudio muxado em MP4. Sem limite de tempo imposto pelo app. Duração real = quanto o stream Bluetooth da Meta aguenta + bateria/termal dos óculos. LED fica aceso durante a gravação. Não é o gravador oficial da Meta View com upload automático etc. Testar na prática com os óculos alvo.)

🔴 Parede do Meta (não dá pra app de terceiro – não vamos prometer):
- "Hey Meta" / Meta AI nativa (por isso "Oi Maia")
- Música, chamadas, navegação, legendas/tradução nativas, modelo Display (tela/pulseira neural)

Descoberta técnica boa:
Tradução e transcrição de ambiente **não precisam de node.invoke para o fluxo de dados**. O app só precisa streamar o texto do mic (e frames válidos) continuamente para a Maia. O node.invoke serve para a Maia comandar ações (start/stop, foto, status, pare). Isso deixa o contrato bem mais simples pro lado do servidor.

### Block for (A) Cliente – passos exatos nas telas do app (substitui os [Grok/Pedro])

**(A) Cliente** — o que a pessoa faz no iPhone:

1. Instala o app iMetaClaw (via TestFlight ou .ipa fornecido pelo operador).  
   O build já vem com tudo embutido (handler completo de `node.invoke`, gravação de vídeo/áudio, tradução ao vivo, legendas de ambiente e a ponte WebSocket persistente).

2. Abre o app pela primeira vez ou vai em **Ajustes → Gateways** (ou na seção de Gateways que aparece no onboarding).

3. Cria ou edita o gateway:
   - **Name**: "Minha Maia" (livre)
   - Escolha o Provider: OpenClaw (para Maia)
   - **Token**: cole exatamente o `OPENCLAW_TOKEN` de `/opt/maia/.env`
   - **Connection Mode**: Tunnel (ou Auto)
   - **Tunnel Host** (quando Tunnel): o domínio/URL que o Caddy expõe (o que aponta para o Maia Command Center na porta :3600). Exemplo placeholder costuma ser o default da Maia.
   - (Se LAN) LAN Host + Port
   - Salve

4. Aguarde o status:
   - Círculo verde + **"Maia pronta — HTTP + WebSocket OK"**
   - Laranja: **"HTTP OK — WebSocket pendente (aprovar device no VPS)"**
   - Vermelho: **"Gateway offline para o iPhone"**
   - Cinza: **"Gateway não configurado"**
   - Abaixo aparece `lastConnectionDetail` (mensagem de erro copiável) e preview de Health/WebSocket.
   - Botão "Testar conexão completa (HTTP + WebSocket)" e "Test Connection" na edição.

5. Pareie os óculos Ray-Ban Meta normalmente (Bluetooth + permissões de câmera/microfone quando pedidas).  
   O app captura direto do stream da câmera e microfone dos óculos (MWDAT SDK).

6. Use:
   - Fale **"Oi Maia"** ou qualquer frase. 
   - Transcrição local (boa com sotaque pt-BR) + imagem da câmera (quando válida) é enviada continuamente para a Maia via `sessions.send`.
   - Resposta vem em voz.

7. Comandos que a Maia pode disparar via `node.invoke` (controle):
   - Tirar foto / visão
   - Gravar/parar vídeo
   - Gravar/parar áudio (anota isso)
   - Modo tradução / parar tradução (fala a tradução em voz)
   - Modo reunião / transcreve consulta / parar transcrição
   - Status (bateria do iPhone + estados ativos)
   - "pare" / "para" genérico (para tudo que estiver rodando)

8. O socket fica aberto em background graças à sessão de áudio do wake word. Funciona com o telefone no bolso.

**Dicas e ressalvas importantes (escreva isso no guia):**
- Em builds para cliente (simpleMode / iMetaClaw) a UI é bem mais limpa: esconde modelos locais, estratégias complexas, força vpsOnly para Maia.
- No rodapé da edição em simpleMode aparece orientação: "Maia = KVM2 ... Token = gateway.auth.token da Maia. Não use Hermes."
- Gravar vídeo: funciona (MP4 com áudio muxado do stream cru). Sem limite de tempo no código do app. Duração prática depende do quanto o stream Bluetooth dos óculos aguenta + bateria/termal dos óculos. O LED fica aceso. Não é o mesmo que gravar direto no Meta View.
- Bateria: o comando status devolve % do iPhone. Bateria dos óculos → Meta View app.
- Se não ficar verde: quase sempre token, Caddy proxy (:3600), ou device não aprovado no VPS (`openclaw devices list` ou equivalente).

O cliente só precisa de: o app + a URL do tunnel + o token. O resto (handler, streaming, node.invoke) já vem junto.

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