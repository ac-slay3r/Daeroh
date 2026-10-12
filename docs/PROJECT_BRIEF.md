# Project Brief — Hermes Mobile Client

## Problema

Hermes Agent es un agente AI self-hosted (NousResearch) con capacidades de memoria, cron, skills y MCP. Su interfaz oficial no está optimizada para uso móvil desde Android/GrapheneOS. Las alternativas actuales para controlarlo desde el móvil son:

- **Telegram bot**: requiere cuenta Telegram, dependencia de terceros
- **PWA/navegador**: sin soporte offline, sin integración OS Android
- **SSH + Termux**: flujo de trabajo de desarrollador, no usuario
- **SillyTavern/OpenWebUI**: pensados para desktop, UX no móvil

Ninguna de estas opciones es una interfaz cómoda, privada y de primera clase para Android.

## Solución

Un cliente Android nativo (Flutter) que se conecta remotamente al Gateway de Hermes Agent:

- **Remoto**: Hermes corre en servidor/VM/homelab, no en el teléfono
- **Privado**: sin backend ni telemetría de XPeta Lab; servicios externos
  opcionales divulgados en la política de privacidad
- **Tailscale-first**: conexión segura sin exponer puertos públicos
- **GrapheneOS-ready**: permisos mínimos, sin Google Play Services requerido

## Público objetivo

- Self-hosters con Hermes Agent en homelab o VPS
- Usuarios de GrapheneOS que priorizan privacidad
- Usuarios de Tailscale para redes privadas
- Desarrolladores que quieren un cliente Hermes móvil hackeable
- Usuarios del ecosistema NousResearch/Hermes

## Base de trabajo

Fork de: https://github.com/rusty4444/hermes-android  
Hermes Agent upstream: https://github.com/NousResearch/hermes-agent

## Lo que NO es este proyecto

- ❌ Una app de IA genérica tipo ChatGPT
- ❌ Un clon de interfaz de ningún proveedor cloud
- ❌ Un runtime de Hermes en el móvil (no ejecuta modelos localmente)
- ❌ Una app para usuarios de servicios cloud de pago
- ❌ Un proyecto con telemetría, tracking o analytics

## Stack técnico

- **Frontend**: Flutter (Dart)
- **Backend**: Hermes Agent Gateway (self-hosted)
- **Conectividad**: Tailscale / LAN / HTTPS
- **Seguridad**: Android Keystore, flutter_secure_storage
- **Android mínimo**: Android 10 (API 29), GrapheneOS compatible

## Métricas de éxito de la fase inicial

- [ ] App compila sin errores
- [ ] Conecta a Hermes Gateway self-hosted
- [ ] Chat funcional con streaming
- [ ] API key almacenada de forma segura
- [ ] Sin permisos Android innecesarios
- [ ] Sin telemetría operada por XPeta Lab; métricas de SDK declaradas
